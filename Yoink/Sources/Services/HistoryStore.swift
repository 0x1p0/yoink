import Foundation
import SwiftUI
import UserNotifications

// MARK: - Download History

struct HistoryEntry: Codable, Identifiable {
    let id          : UUID
    let title       : String
    let thumbnail   : String
    let url         : String
    let outputPath  : String   // file URL string
    let date        : Date
    let format      : String   // format label
    let fileSize    : Int64    // bytes, 0 if unknown
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private init() { load() }

    @Published var entries: [HistoryEntry] = []
    private let key = "downloadHistory_v1"

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries = Array(entries.prefix(500)) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func removeByID(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() { entries = []; save() }

    /// Returns any existing history entry for this URL or video ID
    func existingEntry(for url: String) -> HistoryEntry? {
        let vid = Self.videoID(from: url)
        return entries.first {
            $0.url == url || (!vid.isEmpty && Self.videoID(from: $0.url) == vid)
        }
    }

    static func videoID(from url: String) -> String {
        guard let comps = URLComponents(string: url) else { return "" }
        // YouTube: ?v=xxx
        if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        // youtu.be/xxx
        if let host = comps.host, host.contains("youtu.be") { return comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        // Vimeo: /1234567
        if let host = comps.host, host.contains("vimeo") { return comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return ""
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }
}

