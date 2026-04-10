import Foundation
import SwiftUI

// MARK: - Watch Later Item

struct WatchLaterItem: Codable, Identifiable, Hashable {
    let id          : UUID
    var url         : String
    var title       : String     // filled after metadata fetch (single video) or playlist name
    var thumbnail   : String
    var addedAt     : Date
    var formatRaw   : String     // DownloadFormat.rawValue
    var notes       : String     // optional user note
    var tags        : [String]   // FIX #2: user-defined tags e.g. ["work", "music"]
    var isPlaylist  : Bool       // true when URL is a playlist/channel
    var cachedPlaylistItems: [CachedPlaylistItem] = []  // pre-fetched playlist entries

    init(url: String, title: String = "", thumbnail: String = "", format: DownloadFormat = .best, notes: String = "", tags: [String] = [], isPlaylist: Bool = false) {
        self.id         = UUID()
        self.url        = url
        self.title      = title
        self.thumbnail  = thumbnail
        self.addedAt    = Date()
        self.formatRaw  = format.rawValue
        self.notes      = notes
        self.tags       = tags
        self.isPlaylist = isPlaylist
    }

    var format: DownloadFormat { DownloadFormat(rawValue: formatRaw) ?? .best }
    var displayTitle: String {
        if !title.isEmpty { return title }
        // For playlists with no title yet, show a trimmed URL
        if isPlaylist, let host = URLComponents(string: url)?.host { return host }
        return url
    }

    // Hashable / Equatable - ignore cached items for diffing
    static func == (lhs: WatchLaterItem, rhs: WatchLaterItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CachedPlaylistItem: Codable, Identifiable, Hashable {
    let id       : UUID
    let index    : Int
    let videoID  : String
    let title    : String
    let duration : String
    let thumbnail: String

    init(index: Int, videoID: String, title: String, duration: String, thumbnail: String) {
        self.id        = UUID()
        self.index     = index
        self.videoID   = videoID
        self.title     = title
        self.duration  = duration
        self.thumbnail = thumbnail
    }

    /// Convert back to a live PlaylistItem for download/schedule
    func toPlaylistItem() -> PlaylistItem {
        let p = PlaylistItem(index: index, videoID: videoID, title: title, duration: duration)
        p.thumbnail = thumbnail
        return p
    }
}

// MARK: - Watch Later Store

@MainActor
final class WatchLaterStore: ObservableObject {
    static let shared = WatchLaterStore()
    private init() { load() }

    @Published var items: [WatchLaterItem] = []
    private let key = "watchLater_v1"

    // MARK: CRUD

    func add(url: String, title: String = "", thumbnail: String = "", format: DownloadFormat = .best, isPlaylist: Bool = false) {
        guard !items.contains(where: { $0.url == url }) else { return }
        let item = WatchLaterItem(url: url, title: title, thumbnail: thumbnail, format: format, isPlaylist: isPlaylist)
        items.insert(item, at: 0)
        save()
        Haptics.success()
        if isPlaylist {
            fetchPlaylistCache(for: item.id, url: url)
        } else if title.isEmpty || thumbnail.isEmpty {
            fetchMeta(for: item.id, url: url)
        }
    }

    /// Background fetch: grabs playlist title and all item metadata, stores on the WatchLaterItem
    private func fetchPlaylistCache(for id: UUID, url: String) {
        Task.detached(priority: .utility) {
            // Fetch all items (this also gives us the playlist title from item[0])
            let result = await DownloadService.shared.fetchPlaylist(url: url)
            guard case .success(let playlistItems) = result, !playlistItems.isEmpty else { return }

            let cached = playlistItems.map {
                CachedPlaylistItem(index: $0.index, videoID: $0.videoID,
                                   title: $0.title, duration: $0.duration, thumbnail: $0.thumbnail)
            }

            var playlistTitle = ""
            if let ytPath = await DependencyService.shared.resolvePath(for: "yt-dlp") {
                playlistTitle = await Self.fetchPlaylistTitle(url: url, ytdlpPath: ytPath)
            }

            let finalTitle = playlistTitle   // snapshot var → let before crossing actor boundary
            await MainActor.run {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[idx].cachedPlaylistItems = cached
                if !finalTitle.isEmpty {
                    self.items[idx].title = finalTitle
                } else if let first = cached.first {
                    // Fallback: use domain as title (better than raw URL)
                    let _ = first  // already handled by displayTitle computed prop
                }
                self.save()
            }
        }
    }

    /// Fetch the playlist/channel title using yt-dlp --flat-playlist --dump-single-json
    private static func fetchPlaylistTitle(url: String, ytdlpPath: String) async -> String {
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.arguments = ["--flat-playlist", "--dump-single-json", "--no-warnings", url]
            let pipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = pipe; proc.standardError = errPipe
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box(); let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData; guard !chunk.isEmpty else { return }
                lock.lock(); box.data.append(chunk); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
            proc.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                box.data.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let data = box.data; lock.unlock()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let t = json["title"] as? String, !t.isEmpty
                else { cont.resume(returning: ""); return }
                cont.resume(returning: t)
            }
            do { try proc.run() } catch { cont.resume(returning: "") }
        }
    }

    /// Update cached playlist items for an existing entry (called after re-fetch if needed)
    func updateCache(id: UUID, items newItems: [CachedPlaylistItem], title: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].cachedPlaylistItems = newItems
        if let t = title, !t.isEmpty { items[idx].title = t }
        save()
    }

    private func fetchMeta(for id: UUID, url: String) {
        Task.detached(priority: .utility) {
            let result = await DownloadService.shared.fetchMeta(url: url, authArgs: [])
            guard case .success(let meta) = result, !meta.title.isEmpty else { return }
            await MainActor.run {
                self.update(id: id, title: meta.title, thumbnail: meta.thumbnail)
            }
        }
    }

    func remove(_ item: WatchLaterItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeAll() { items = []; save() }

    func update(id: UUID, title: String? = nil, thumbnail: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let t = title     { items[idx].title     = t }
        if let t = thumbnail { items[idx].thumbnail = t }
        save()
    }

    // FIX #2: Tag management
    func updateTags(id: UUID, tags: [String]) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].tags = tags
        save()
    }

    /// All unique tags across all items, sorted alphabetically
    var allTags: [String] {
        Array(Set(items.flatMap { $0.tags })).sorted()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func contains(url: String) -> Bool {
        items.contains { $0.url == url }
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WatchLaterItem].self, from: data)
        else { return }
        items = decoded
    }
}
