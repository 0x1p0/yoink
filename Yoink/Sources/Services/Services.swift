import Foundation
import SwiftUI
import UserNotifications

// MARK: - Dep Status

enum DepStatus: Equatable {
    case unknown, checking
    case ok(version: String)
    case updating(from: String)   // silent background update in progress
    case missing                  // should never happen (bundled), shown if copy failed
    case failed(String)

    var isReady: Bool {
        switch self { case .ok, .updating: return true; default: return false }
    }
    var version: String? {
        switch self {
        case .ok(let v):       return v
        case .updating(let v): return v
        default:               return nil
        }
    }
    var dotColor: Color {
        switch self {
        case .unknown:           return Color(.systemGray)
        case .checking:          return .orange
        case .updating:          return .orange
        case .ok:                return .green
        case .missing, .failed:  return .red
        }
    }
    var statusLabel: String {
        switch self {
        case .unknown:          return "Not checked"
        case .checking:         return "Checking…"
        case .ok(let v):        return v
        case .updating(let v):  return "\(v) - updating…"
        case .missing:          return "Missing - restart app"
        case .failed(let e):    return e
        }
    }
}

// MARK: - Dependency Service (bundled binaries, no Homebrew)

@MainActor
final class DependencyService: ObservableObject {
    static let shared = DependencyService()
    private init() {}

    @Published var ytdlp   : DepStatus = .unknown
    @Published var ffmpeg  : DepStatus = .unknown
    @Published var ffprobe : DepStatus = .unknown
    @Published var updateLog: [String] = []

    @AppStorage("lastEngineUpdateCheck") private var lastUpdateCheck: Double = 0

    // MARK: - Paths

    /// ~/Library/Application Support/Yoink/bin/
    nonisolated static var appSupportBin: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Yoink/bin", isDirectory: true)
    }

    nonisolated static func runtimePath(for binary: String) -> String {
        appSupportBin.appendingPathComponent(binary).path
    }

    var allReady: Bool { ytdlp.isReady && ffmpeg.isReady }

    // MARK: - Boot

    func checkAll() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.ensureBinariesCopied()
            async let a: () = self.checkYtdlp()
            async let b: () = self.checkFfmpeg()
            async let c: () = self.checkFfprobe()
            _ = await (a, b, c)

            // Daily update check
            let now = Date().timeIntervalSince1970
            let lastCheck = await self.lastUpdateCheck
            if now - lastCheck > 86_400 {
                await MainActor.run { self.lastUpdateCheck = now }
                async let upYtdlp:  () = self.silentUpdateYtdlp()
                async let upProbe:  () = self.silentUpdateFfprobe()
                async let upFfmpeg: () = self.silentUpdateFfmpeg()
                _ = await (upYtdlp, upProbe, upFfmpeg)
            }
        }
    }

    // MARK: - First-launch binary copy

    nonisolated private func ensureBinariesCopied() {
        let fm = FileManager.default
        let binDir = Self.appSupportBin
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Copy bundled binaries
        for binary in ["yt-dlp", "ffmpeg", "ffprobe"] {
            let dest = binDir.appendingPathComponent(binary)
            if fm.fileExists(atPath: dest.path) { continue }
            guard let src = Bundle.main.url(forResource: binary, withExtension: nil,
                                             subdirectory: "bin") else {
                log("⚠️ Bundled \(binary) not found in Resources/bin/")
                continue
            }
            do {
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                log("✓ Copied \(binary) → \(dest.path)")
            } catch {
                log("✗ Failed to copy \(binary): \(error.localizedDescription)")
            }
        }

        // Copy bundled Python (faster startup, self-contained)
        let pythonDest = binDir.appendingPathComponent("python")
        if !fm.fileExists(atPath: pythonDest.path) {
            if let pythonSrc = Bundle.main.url(forResource: "python", withExtension: nil,
                                                subdirectory: "bin") {
                do {
                    try fm.copyItem(at: pythonSrc, to: pythonDest)
                    log("✓ Copied python → \(pythonDest.path)")
                } catch {
                    log("✗ Failed to copy python: \(error.localizedDescription)")
                }
            } else {
                log("⚠️ python not bundled - run download_binaries.sh to fix this")
            }
        }
    }

    // MARK: - Version checks

    nonisolated func checkYtdlp() async {
        await MainActor.run { ytdlp = .checking }
        let path = Self.runtimePath(for: "yt-dlp")
        guard let v = await run(path, args: ["--version"]) else {
            await MainActor.run { ytdlp = .missing }; return
        }
        await MainActor.run { ytdlp = .ok(version: v.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    nonisolated func checkFfmpeg() async {
        await MainActor.run { ffmpeg = .checking }
        let path = Self.runtimePath(for: "ffmpeg")
        guard let out = await run(path, args: ["-version"]) else {
            await MainActor.run { ffmpeg = .missing }; return
        }
        let parts = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let version = parts.indices.contains(2) ? String(parts[2].prefix(12)) : "installed"
        await MainActor.run { ffmpeg = .ok(version: version) }
    }

    nonisolated func checkFfprobe() async {
        await MainActor.run { ffprobe = .checking }
        let path = Self.runtimePath(for: "ffprobe")
        guard let out = await run(path, args: ["-version"]) else {
            await MainActor.run { ffprobe = .missing }; return
        }
        let parts = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let version = parts.indices.contains(2) ? String(parts[2].prefix(24)) : "installed"
        await MainActor.run { ffprobe = .ok(version: version) }
    }

    // MARK: - Force update (on-demand, bypasses 24h gate)

    func forceUpdateFfmpeg() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.silentUpdateFfmpeg()
            await self.checkFfmpeg()
        }
    }

    func forceUpdateFfprobe() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.silentUpdateFfprobe()
            await self.checkFfprobe()
        }
    }

    // MARK: - Silent yt-dlp update

    nonisolated private func silentUpdateYtdlp() async {
        guard let latest = await fetchLatestYtdlpTag() else { return }
        let current = await MainActor.run { ytdlp.version ?? "" }
        guard isNewer(latest, than: current) else { return }

        let prev = current
        await MainActor.run { ytdlp = .updating(from: prev) }
        log("⬆︎ yt-dlp \(prev) → \(latest)")

        let venvPip = Self.appSupportBin.appendingPathComponent("python/bin/pip3")
        let pip = Process()
        pip.executableURL = venvPip
        pip.arguments = ["install", "--quiet", "--upgrade", "yt-dlp"]
        pip.standardOutput = Pipe(); pip.standardError = Pipe()
        if (try? pip.run()) != nil {
            pip.waitUntilExit()
            if pip.terminationStatus == 0 {
                log("✓ yt-dlp updated to \(latest)")
                await MainActor.run { ytdlp = .ok(version: latest) }
            } else {
                log("✗ pip upgrade failed")
                await MainActor.run { ytdlp = .ok(version: prev) }
            }
        } else {
            log("✗ Could not launch pip")
            await MainActor.run { ytdlp = .ok(version: prev) }
        }
    }

  
    // MARK: - Silent ffprobe update (evermeet.cx)

    nonisolated private func silentUpdateFfprobe() async {
        let binDir = Self.appSupportBin
        let dest   = binDir.appendingPathComponent("ffprobe")
        let fm     = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            if let src = Bundle.main.url(forResource: "ffprobe", withExtension: nil, subdirectory: "bin") {
                try? fm.copyItem(at: src, to: dest)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                log("ffprobe: installed from bundle")
            }
            return
        }
        let verOut = await run(dest.path, args: ["-version"]) ?? ""
        let vp = (verOut.components(separatedBy: "\n").first ?? "").components(separatedBy: " ")
        let cur = vp.indices.contains(2) ? vp[2] : ""
        let infoS = "https://evermeet.cx/ffmpeg/info/ffprobe/snapshot"
        guard let iu = URL(string: infoS),
              let (id, _) = try? await URLSession.shared.data(from: iu),
              let ij = try? JSONSerialization.jsonObject(with: id) as? [String: Any],
              let latest = ij["version"] as? String,
              isNewer(latest, than: cur) else { return }
        log("ffprobe: \(cur) -> \(latest)")
        let dlS = "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
        guard let du = URL(string: dlS) else { return }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: du)
            let exDir = binDir.appendingPathComponent("fp_tmp", isDirectory: true)
            try? fm.removeItem(at: exDir)
            try fm.createDirectory(at: exDir, withIntermediateDirectories: true)
            let uz = Process()
            uz.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            uz.arguments = ["-o", tmp.path, "-d", exDir.path]
            uz.standardOutput = Pipe(); uz.standardError = Pipe()
            try uz.run(); uz.waitUntilExit()
            let all = (try? fm.contentsOfDirectory(at: exDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            if let bin = all.first(where: { $0.lastPathComponent == "ffprobe" }) ?? all.first {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: bin, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                log("ffprobe: updated to \(latest)")
            }
            try? fm.removeItem(at: exDir); try? fm.removeItem(at: tmp)
        } catch { log("ffprobe update failed: \(error.localizedDescription)") }
    }


    // MARK: - Silent ffmpeg update (evermeet.cx)

    nonisolated private func silentUpdateFfmpeg() async {
        let binDir = Self.appSupportBin
        let dest   = binDir.appendingPathComponent("ffmpeg")
        let fm     = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            if let src = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin") {
                try? fm.copyItem(at: src, to: dest)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                log("ffmpeg: installed from bundle")
            }
            return
        }
        let verOut = await run(dest.path, args: ["-version"]) ?? ""
        let vp = (verOut.components(separatedBy: "\n").first ?? "").components(separatedBy: " ")
        let cur = vp.indices.contains(2) ? vp[2] : ""
        let infoS = "https://evermeet.cx/ffmpeg/info/ffmpeg/release"
        guard let iu = URL(string: infoS),
              let (id, _) = try? await URLSession.shared.data(from: iu),
              let ij = try? JSONSerialization.jsonObject(with: id) as? [String: Any],
              let latest = ij["version"] as? String,
              isNewer(latest, than: cur) else { return }
        log("ffmpeg: \(cur) -> \(latest)")
        let dlS = "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
        guard let du = URL(string: dlS) else { return }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: du)
            let exDir = binDir.appendingPathComponent("fm_tmp", isDirectory: true)
            try? fm.removeItem(at: exDir)
            try fm.createDirectory(at: exDir, withIntermediateDirectories: true)
            let uz = Process()
            uz.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            uz.arguments = ["-o", tmp.path, "-d", exDir.path]
            uz.standardOutput = Pipe(); uz.standardError = Pipe()
            try uz.run(); uz.waitUntilExit()
            let all = (try? fm.contentsOfDirectory(at: exDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            if let bin = all.first(where: { $0.lastPathComponent == "ffmpeg" }) ?? all.first {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: bin, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                log("ffmpeg: updated to \(latest)")
            }
            try? fm.removeItem(at: exDir); try? fm.removeItem(at: tmp)
        } catch { log("ffmpeg update failed: \(error.localizedDescription)") }
    }

    nonisolated static func macArch() -> String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { ptr in
            String(bytes: ptr.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "x86_64"
        }.contains("arm") ? "arm64" : "x86_64"
    }
    // MARK: - Path resolution (always use bundled binary in App Support)

    nonisolated func resolvePath(for binary: String) async -> String? {
        let path = Self.runtimePath(for: binary)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Helpers

    nonisolated private func run(_ path: String, args: [String]) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: proc.terminationStatus == 0
                    ? String(data: data, encoding: .utf8) : nil)
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }

    private func fetchLatestYtdlpTag() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag  = json["tag_name"] as? String
        else { return nil }
        return tag
    }

    nonisolated private func isNewer(_ a: String, than b: String) -> Bool {
        Self.isNewer(a, than: b)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    nonisolated private func log(_ line: String, error: Bool = false) {
        print("[BinMgr] \(line)")
        Task { _ = await MainActor.run { self.updateLog.append(line) } }
    }
}

/// Returns the largest media file in the directory.
private let mediaExtensions = Set(["mkv","mp4","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac"])

func primaryMediaFile(in directory: URL) -> URL? {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
    let items = (try? fm.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys,
        options: .skipsHiddenFiles)) ?? []
    let mediaFiles = items.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
    // Primary sort: newest by creation date (most likely to be the file just downloaded).
    // Fallback sort: largest by size (old behaviour) for files with identical timestamps.
    return mediaFiles.max {
        let aVals = try? $0.resourceValues(forKeys: Set(keys))
        let bVals = try? $1.resourceValues(forKeys: Set(keys))
        let aDate = aVals?.creationDate ?? .distantPast
        let bDate = bVals?.creationDate ?? .distantPast
        if aDate != bDate { return aDate < bDate }
        let aSize = aVals?.fileSize ?? 0
        let bSize = bVals?.fileSize ?? 0
        return aSize < bSize
    }
}

func cleanSubtitles(in directory: URL, sponsorSegments: [(startMs: Int, endMs: Int)] = [], keepRanges: [(startMs: Int, endMs: Int)] = []) {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ) else { return }

    // Delete stray .info.json files
    for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".info.json") {
        try? FileManager.default.removeItem(at: file)
    }

    for file in files {
        let ext = file.pathExtension.lowercased()
        guard ext == "srt" || ext == "vtt" else { continue }
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }

        let cleaned = cleanYouTubeSubtitles(raw, removedSegments: sponsorSegments, keepRanges: keepRanges)

        let srtURL = file.deletingPathExtension().appendingPathExtension("srt")
        try? cleaned.write(to: srtURL, atomically: true, encoding: .utf8)

        if ext == "vtt" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Cleans YouTube subtitles: deduplicates rolling-window cues, strips VTT tags, retimes for SponsorBlock cuts.
private func cleanYouTubeSubtitles(_ input: String,
                                    removedSegments: [(startMs: Int, endMs: Int)] = [],
                                    keepRanges: [(startMs: Int, endMs: Int)] = []) -> String {
    struct Cue { var startMs: Int; var endMs: Int; var text: String }

    var cues: [Cue] = []
    var prevLast: String = ""

    for block in input.components(separatedBy: "\n\n") {
        let lines = block.components(separatedBy: "\n")

        // Find the timestamp line (contains -->)
        guard let tsIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

        // Parse start/end - take only the time token (ignore VTT positioning metadata)
        let tsParts = lines[tsIdx].components(separatedBy: " --> ")
        guard tsParts.count == 2 else { continue }
        let startMs = subTimeToMs(tsParts[0].components(separatedBy: " ").first ?? tsParts[0])
        let endMs   = subTimeToMs(tsParts[1].components(separatedBy: " ").first ?? tsParts[1])

        // Skip micro transition cues (≤ 100 ms) - they are just carry-over display frames
        guard endMs - startMs > 100 else { continue }

        // Collect text lines after the timestamp, stripping VTT inline timing/karaoke tags
        var textLines: [String] = []
        for line in lines[(tsIdx + 1)...] {
            let stripped = stripSubtitleTags(line).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty, stripped != "\u{00a0}" else { continue }
            textLines.append(stripped)
        }
        guard !textLines.isEmpty else { continue }

        // De-duplicate rolling-window: YouTube repeats previous cue's last line.
        if !prevLast.isEmpty,
           textLines[0].trimmingCharacters(in: .whitespaces) == prevLast.trimmingCharacters(in: .whitespaces) {
            textLines.removeFirst()
        }
        guard !textLines.isEmpty else { continue }

        prevLast = textLines.last ?? ""
        cues.append(Cue(startMs: startMs, endMs: endMs, text: textLines.joined(separator: "\n")))
    }

    // SponsorBlock retiming: drop/clip cues in removed segments, shift timestamps.

    if !removedSegments.isEmpty {
        var retimed: [Cue] = []

        for cue in cues {
            let cueStart = cue.startMs
            var cueEnd   = cue.endMs
            var skip     = false

            // Compute how many ms have been cut out before this cue's start
            var offset = 0
            for seg in removedSegments {
                if seg.endMs <= cueStart {
                    // Segment is entirely before this cue - count it fully
                    offset += seg.endMs - seg.startMs
                } else if seg.startMs < cueEnd {
                    if seg.startMs <= cueStart {
                        skip = true
                        break
                    } else {
                        cueEnd = seg.startMs
                    }
                }

                if seg.startMs >= cueEnd { break }
            }

            if skip || cueEnd <= cueStart { continue }

            retimed.append(Cue(
                startMs: cueStart - offset,
                endMs:   cueEnd   - offset,
                text:    cue.text))
        }
        cues = retimed
    }

    // Filter to keep-ranges (segment/chapter selection), shift to 0-based.
    if !keepRanges.isEmpty {
        let sorted = keepRanges.sorted { $0.startMs < $1.startMs }
        var kept: [Cue] = []
        for cue in cues {
            for range in sorted {
                // Keep cue if it overlaps the range at all
                if cue.startMs < range.endMs && cue.endMs > range.startMs {
                    // Clip to range boundaries
                    let clippedStart = max(cue.startMs, range.startMs)
                    let clippedEnd   = min(cue.endMs,   range.endMs)
                    if clippedEnd > clippedStart {
                        kept.append(Cue(startMs: clippedStart, endMs: clippedEnd, text: cue.text))
                    }
                    break
                }
            }
        }
        // Shift to 0-based relative to the earliest keep-range.
        let shift = sorted.first?.startMs ?? 0
        cues = kept.map { Cue(startMs: $0.startMs - shift, endMs: $0.endMs - shift, text: $0.text) }
    }

    return cues.enumerated().map { (i, cue) in
        "\(i + 1)\n\(msToSrtTime(cue.startMs)) --> \(msToSrtTime(cue.endMs))\n\(cue.text)"
    }.joined(separator: "\n\n") + "\n"
}

/// Strips VTT inline word-timing tags like <00:00:01.280>, <c>, </c>, and any other HTML tags.
private func stripSubtitleTags(_ text: String) -> String {
    // Remove VTT timestamp tags: <00:00:01.280>
    var out = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "<" {
            if let close = text[i...].firstIndex(of: ">") {
                i = text.index(after: close)
                continue
            }
        }
        out.append(text[i])
        i = text.index(after: i)
    }
    return out
}

/// Converts VTT (MM:SS.mmm or HH:MM:SS.mmm) or SRT (HH:MM:SS,mmm) timestamps to milliseconds.
private func subTimeToMs(_ raw: String) -> Int {
    let s = raw.trimmingCharacters(in: .whitespaces)
               .replacingOccurrences(of: ",", with: ".")  // SRT uses comma
    let parts = s.components(separatedBy: ":")
    let muls  = [3600_000, 60_000, 1_000]
    let offset = 3 - parts.count   // handle MM:SS.mmm (2 parts) vs HH:MM:SS.mmm (3 parts)
    var ms = 0
    for (i, part) in parts.enumerated() {
        let sub = part.components(separatedBy: ".")
        ms += (Int(sub[0]) ?? 0) * muls[max(0, offset + i)]
        if i == parts.count - 1, sub.count > 1 {
            ms += Int((sub[1] + "000").prefix(3)) ?? 0
        }
    }
    return ms
}

private func msToSrtTime(_ ms: Int) -> String {
    String(format: "%02d:%02d:%02d,%03d",
           ms / 3_600_000, (ms % 3_600_000) / 60_000,
           (ms % 60_000) / 1_000, ms % 1_000)
}

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

// MARK: - Post-download action executor

func sendCompletionNotification(outputDir: URL, title: String, exactFilePath: String? = nil, thumbnailURL: String? = nil) {
    let center = UNUserNotificationCenter.current()

    func buildAndSend(attachmentURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = title
        content.sound = .default
        // Store the EXACT file path so notification tap reveals the right file
        // Fall back to folder only if we somehow don't have the exact path
        content.userInfo = ["exactFilePath": exactFilePath ?? "", "outputPath": outputDir.path]
        if let att = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: "thumb", url: att, options: nil) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req) { err in
            if let err { print("[Yoink] Notification error: \(err)") }
        }
    }

    let send: () -> Void = {
        if let thumbStr = thumbnailURL, !thumbStr.isEmpty, let thumbURL = URL(string: thumbStr) {
            Task.detached(priority: .background) {
                let tempDir = FileManager.default.temporaryDirectory
                let ext = (thumbURL.pathExtension.isEmpty ? "jpg" : thumbURL.pathExtension)
                let dest = tempDir.appendingPathComponent("yoink_notif_thumb_\(UUID().uuidString).\(ext)")
                if let (localURL, _) = try? await URLSession.shared.download(from: thumbURL) {
                    try? FileManager.default.moveItem(at: localURL, to: dest)
                    buildAndSend(attachmentURL: dest)
                } else {
                    buildAndSend(attachmentURL: nil)
                }
            }
        } else {
            buildAndSend(attachmentURL: nil)
        }
    }
    center.getNotificationSettings { s in
        switch s.authorizationStatus {
        case .authorized, .provisional:
            send()
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                if ok { send() }
            }
        default:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            }
        }
    }
}

// Fires once when the entire queue drains - used when notifyOnQueueComplete is enabled.
func sendQueueCompleteNotification(title: String, count: Int, outputDir: URL) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { s in
        guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = count == 1
            ? "Your download is ready."
            : "All \(count) downloads are ready in your output folder."
        content.sound = .default
        content.userInfo = ["outputPath": outputDir.path, "exactFilePath": ""]
        let req = UNNotificationRequest(identifier: "yoink.queue.complete.\(UUID().uuidString)",
                                        content: content, trigger: nil)
        center.add(req) { err in if let err { print("[Yoink] Queue notification error: \(err)") } }
    }
}

func executePostDownloadAction(_ action: PostDownloadAction, outputDir: URL, title: String) {
    let mediaExts = Set(["mkv","mp4","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac"])

    let mediaFile: URL? = (try? FileManager.default.contentsOfDirectory(
        at: outputDir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles
    ))?
    .filter { mediaExts.contains($0.pathExtension.lowercased()) }
    .max {
        let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return a < b
    }

    switch action {
    case .nothing:
        break
    case .reveal:
        if let file = mediaFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(outputDir)
        }
    case .openFolder:
        NSWorkspace.shared.open(outputDir)
    case .notify:
        sendCompletionNotification(outputDir: outputDir, title: title)
    case .openFile:
        // FIX #3: open file in default app (VLC, IINA, QuickTime, etc.)
        if let file = mediaFile {
            NSWorkspace.shared.open(file)
        } else {
            NSWorkspace.shared.open(outputDir)
        }
    }
}

@MainActor
final class DownloadQueue: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    @Published var outputDirectory: URL {
        didSet { Self.saveOutputDirectory(outputDirectory) }
    }

    // Weak back-reference set by YoinkApp so AppDelegate can call savePendingQueue
    static weak var shared: DownloadQueue?

    private static let outputDirBookmarkKey = "outputDirectoryBookmark_v2"
    private static let outputDirPathKey     = "outputDirectoryPath_v1"

    private static let pendingURLsKey = "pendingDownloadURLs_v1"

    init() {
        outputDirectory = Self.loadOutputDirectory()
        jobs = [DownloadJob()]
        restorePendingQueue()
    }

    func savePendingQueue() {
        let urls = jobs.compactMap { job -> String? in
            guard job.hasURL, !job.status.isTerminal else { return nil }
            return job.url
        }
        UserDefaults.standard.set(urls, forKey: Self.pendingURLsKey)
    }

    private func restorePendingQueue() {
        guard let urls = UserDefaults.standard.stringArray(forKey: Self.pendingURLsKey),
              !urls.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingURLsKey)
        Self.interruptedURLs = urls
    }

    static var interruptedURLs: [String] = []

    // ── Persistence ──────────────────────────────────────────────────────

    private static func loadOutputDirectory() -> URL {
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Yoink")

        if let data = UserDefaults.standard.data(forKey: outputDirBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { saveOutputDirectory(url) }
                return url
            }
        }
        // Fallback: plain path (non-sandboxed builds)
        if let path = UserDefaults.standard.string(forKey: outputDirPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { return url }
        }
        return fallback
    }

    private static func saveOutputDirectory(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: outputDirBookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: outputDirPathKey)
    }

    func addJob() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { jobs.append(DownloadJob()) }
    }
    func addJob(url: String) {
        let job = DownloadJob(); job.url = url
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { jobs.append(job) }
        Haptics.tap()
    }
    func addJobSilent(_ job: DownloadJob) {
        jobs.append(job)
    }

    func addBatchURLs(_ urls: [String]) {
        var remaining = urls
        for job in jobs where !job.hasURL && job.status == .idle {
            guard !remaining.isEmpty else { break }
            job.url = remaining.removeFirst()
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            for url in remaining { let j = DownloadJob(); j.url = url; jobs.append(j) }
        }
        Haptics.success()
    }

    /// Import URLs from a plain-text file (one URL per line).
    /// Returns the number of URLs successfully imported.
    @discardableResult
    func importURLsFromFile(_ fileURL: URL) -> Int {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        let urls = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") }
        guard !urls.isEmpty else { return 0 }
        addBatchURLs(urls)
        return urls.count
    }
    func remove(_ job: DownloadJob) {
        job.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { jobs.removeAll { $0.id == job.id } }
    }
    func clearCompleted() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { jobs.removeAll { $0.status.isTerminal } }
    }

    func retryFailed() {
        let failed = jobs.filter { if case .failed = $0.status { return true }; return false }
        guard !failed.isEmpty else { return }
        ensureOutputDir()
        for job in failed {
            job.retryCount += 1
            job.reset()
        }
        downloadAll()
        Haptics.start()
    }

    func move(from source: IndexSet, to destination: Int) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            jobs.move(fromOffsets: source, toOffset: destination)
        }
    }
    func downloadAll() {
        ensureOutputDir()
        let limit = SettingsManager.shared.concurrentLimit.rawValue  // 0 = unlimited
        let pending = jobs.filter { $0.hasURL && !$0.status.isActive }
        let activeCount = jobs.filter { $0.status.isActive }.count
        let slotsAvailable = limit == 0 ? pending.count : max(0, limit - activeCount)
        let toStart = limit == 0 ? pending : Array(pending.prefix(slotsAvailable))
        for job in toStart {
            DownloadService.shared.start(job: job, outputDir: outputDirectory)
        }
    }
    func ensureOutputDir() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Download Service

@MainActor
final class DownloadService: ObservableObject {
    static let shared = DownloadService()
    private init() {}

    // MARK: - URL Support Pre-check

    /// Cache of supported yt-dlp extractor host patterns, loaded once on first call.
    private var supportedExtractorPatterns: Set<String> = []
    private var extractorPatternsLoaded = false

    /// Call once at app launch to load extractor patterns in background before first paste.
    func preWarmExtractorPatterns() async {
        guard !extractorPatternsLoaded else { return }
        await loadExtractorPatterns()
    }

    /// Quick check: is this URL likely supported by yt-dlp?
    /// Uses a cached list of extractor URL patterns; falls back to true (optimistic) if cache is empty.
    func isSupportedURL(_ urlString: String) async -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        if !extractorPatternsLoaded { await loadExtractorPatterns() }
        if supportedExtractorPatterns.isEmpty { return true }
        let normalizedHost = host == "youtu.be" ? "youtube" : host
        return supportedExtractorPatterns.contains(where: { normalizedHost.contains($0) })
    }

    private func loadExtractorPatterns() async {
        extractorPatternsLoaded = true
        guard let path = await DependencyService.shared.resolvePath(for: "yt-dlp") else { return }
        let patterns: Set<String> = await Task.detached(priority: .background) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["--list-extractors"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = Pipe()
            guard (try? proc.run()) != nil else { return [] }
            proc.waitUntilExit()
            guard let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
            return Set(
                text.components(separatedBy: .newlines)
                    .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("_") }
                    .map { $0.components(separatedBy: ":").first ?? $0 }
            )
        }.value
        self.supportedExtractorPatterns = patterns
    }

    // MARK: Metadata fetch (title + thumbnail + duration + subs)

    /// Public wrapper - fetches metadata for an arbitrary URL and returns the result.
    func fetchMeta(url: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            return .failure(NSError(domain: "yoink", code: 1, userInfo: [NSLocalizedDescriptionKey: "yt-dlp not found"]))
        }
        return await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
    }

    func fetchMetadata(for job: DownloadJob) {
        guard job.hasURL else { return }

        job.metaFetchTask?.cancel()
        job.metaState = .fetching
        job.meta = nil
        job.thumbnailLoaded = false
        job.endH = ""; job.endM = ""; job.endS = ""

        let url        = job.url
        let hasCookies = job.hasCookies
        let authArgs   = cookieArgs(for: job)

        // ── Twitch fast-path: hit GQL directly instead of yt-dlp --dump-json ──
        let twitch = TwitchService.shared
        if twitch.isTwitchURL(url) {
            job.isTwitchURL = true
            let task = Task.detached(priority: .userInitiated) {
                if let vodId = twitch.parseVODId(from: url) {
                    await self.fetchTwitchVODMeta(job: job, vodId: vodId)
                } else if let slug = twitch.parseClipSlug(from: url) {
                    await self.fetchTwitchClipMeta(job: job, slug: slug)
                } else {
                    // Twitch channel or unknown - fall through to yt-dlp
                    await MainActor.run { job.isTwitchURL = false }
                    await self.fetchMetadataViaYtdlp(job: job, url: url, hasCookies: hasCookies, authArgs: authArgs)
                }
            }
            job.metaFetchTask = task
            return
        }

        // ── Non-Twitch: normal yt-dlp path ────────────────────────────────────
        job.isTwitchURL = false
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.fetchMetadataViaYtdlp(job: job, url: url, hasCookies: hasCookies, authArgs: authArgs)
        }
        job.metaFetchTask = task
    }

    // MARK: Twitch VOD meta (GQL)

    @MainActor
    private func fetchTwitchVODMeta(job: DownloadJob, vodId: String) async {
        let twitch = TwitchService.shared
        do {
            let info = try await twitch.fetchVODInfo(id: vodId)
            job.twitchVODInfo = info

            // Populate the VideoMeta so the rest of the UI works unchanged
            job.meta = VideoMeta(
                title: info.title, thumbnail: info.thumbnailURL,
                duration: info.durationHHMMSS,
                durationH: info.durationH, durationM: info.durationM, durationS: info.durationS,
                hasSubs: false, chapters: [], availableSubLangs: [],
                videoFormats: [], audioFormats: [], nEntries: 1
            )
            job.endH = info.durationH
            job.endM = info.durationM
            job.endS = info.durationS
            job.metaState = .done

            // Load thumbnail
            if !info.thumbnailURL.isEmpty {
                ThumbnailCache.shared.load(info.thumbnailURL)
            }

            // Fetch real quality list from M3U8 (async, non-blocking).
            // Also checks the token for restricted_bitrates - if source is locked,
            // flip the job to .needsAuth before the user tries to download.
            Task.detached(priority: .background) {
                let result = await twitch.fetchVODQualitiesWithAuthCheck(id: vodId)
                await MainActor.run {
                    switch result {
                    case .requiresAuth:
                        // Token says subscriber-only - show auth banner immediately
                        job.metaState = job.hasCookies ? .needsAuthRetry : .needsAuth
                    case .ok(let quals):
                        job.twitchQualities = quals
                        if job.selectedTwitchQuality == nil {
                            job.selectedTwitchQuality = quals.first
                        }
                    }
                }
                // Pre-fetch fragment count for the selected quality to enable accurate progress
                if case .ok(let quals) = result, let q = quals.first {
                    let count = await twitch.fetchFragmentCount(id: vodId, quality: q)
                    await MainActor.run {
                        if let c = count { job.twitchTotalFragments = c }
                    }
                }
            }
        } catch {
            job.metaState = .idle
        }
    }

    // MARK: Twitch Clip meta (GQL)

    @MainActor
    private func fetchTwitchClipMeta(job: DownloadJob, slug: String) async {
        let twitch = TwitchService.shared
        do {
            let info = try await twitch.fetchClipInfo(slug: slug)
            job.twitchClipInfo = info

            job.meta = VideoMeta(
                title: info.title, thumbnail: info.thumbnailURL,
                duration: info.durationSeconds.toHHMMSS,
                durationH: String(format: "%02d", info.durationSeconds / 3600),
                durationM: String(format: "%02d", (info.durationSeconds % 3600) / 60),
                durationS: String(format: "%02d", info.durationSeconds % 60),
                hasSubs: false, chapters: [], availableSubLangs: [],
                videoFormats: [], audioFormats: [], nEntries: 1
            )
            job.endH = String(format: "%02d", info.durationSeconds / 3600)
            job.endM = String(format: "%02d", (info.durationSeconds % 3600) / 60)
            job.endS = String(format: "%02d", info.durationSeconds % 60)
            job.metaState = .done

            if !info.thumbnailURL.isEmpty { ThumbnailCache.shared.load(info.thumbnailURL) }
        } catch {
            job.metaState = .idle
        }
    }

    // MARK: yt-dlp metadata (non-Twitch or Twitch fallback)

    private func fetchMetadataViaYtdlp(job: DownloadJob, url: String, hasCookies: Bool, authArgs: [String]) async {
        guard !Task.isCancelled else { return }
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            await MainActor.run { job.metaState = .idle }
            return
        }
        guard !Task.isCancelled else { return }
        let result = await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
        cleanupMetaCookies(for: job)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            switch result {
            case .success(let meta):
                if meta.nEntries > 1 {
                    job.meta = meta; job.metaState = .done
                    NotificationCenter.default.post(name: .playlistURLDetected, object: job)
                    return
                }
                job.meta = meta
                job.endH = meta.durationH; job.endM = meta.durationM; job.endS = meta.durationS
                job.metaState = .done
            case .failure(let err):
                let msg = err.localizedDescription.lowercased()
                let isAuthError = msg.contains("this video requires")
                               || msg.contains("sign in to confirm")
                               || msg.contains("please sign in")
                               || msg.contains("login required")
                               || msg.contains("members only")
                               || msg.contains("private video")
                               || msg.contains("age-restricted")
                               || msg.contains("age restricted")
                               || msg.contains("cookies")
                               || msg.contains("requires authentication")
                               || msg.contains("not available")
                               || msg.contains("subscriber")
                               || msg.contains("subscription")
                               || msg.contains("must be logged in")
                               || msg.contains("logged into an account")
                               || msg.contains("account that has access")
                               || msg.contains("premium")
                               || msg.contains("patreon")
                               || msg.contains("access to this")
                               || (msg.contains("http error 403") && !msg.contains("http error 4030"))
                if isAuthError {
                    job.metaState = hasCookies ? .needsAuthRetry : .needsAuth
                } else {
                    job.metaState = .idle
                }
            }
        }
    }
    /// Public entry for fetching metadata for a single video (used by playlist lazy-load)
    nonisolated func fetchSingleVideoMeta(url: String, ytdlpPath: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        await runMetadataFetch(url: url, ytdlpPath: ytdlpPath, authArgs: authArgs)
    }

    nonisolated private func runMetadataFetch(url: String, ytdlpPath: String, authArgs: [String]) async -> Result<VideoMeta, Error> {
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            let args = authArgs + [
                "--dump-json", "--no-playlist", "--no-warnings",
                "--no-check-formats",
                "--socket-timeout", "8",
                "--retries", "1", "--fragment-retries", "1",
                url
            ]
            proc.arguments = args

            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe; proc.standardError = errPipe

            final class Box: @unchecked Sendable { var data = Data() }
            final class ErrBox: @unchecked Sendable { var data = Data() }
            let box = Box(); let lock = NSLock()
            let errBox = ErrBox(); let errLock = NSLock()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData; guard !chunk.isEmpty else { return }
                lock.lock(); box.data.append(chunk); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData; guard !chunk.isEmpty else { return }
                errLock.lock(); errBox.data.append(chunk); errLock.unlock()
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                box.data.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                let data = box.data; lock.unlock()
                errLock.lock()
                errBox.data.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let errText = String(data: errBox.data, encoding: .utf8) ?? ""
                errLock.unlock()

                // yt-dlp may output multiple JSON objects (one per part) for sites like soop.
                // Take only the first line - it represents the first/main video entry.
                let firstLine = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
                guard p.terminationStatus == 0, !firstLine.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any]
                else {
                    cont.resume(returning: .failure(NSError(domain: "yoink", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: errText.isEmpty
                            ? "yt-dlp failed or returned no data"
                            : errText])))
                    return
                }

                let title          = json["title"]           as? String ?? "Unknown"
                let thumbnail      = json["thumbnail"]       as? String ?? ""
                let durationString = json["duration_string"] as? String ?? "0:00"
                let durSecs        = json["duration"]        as? Double ?? 0
                let nEntries       = json["n_entries"]       as? Int ?? 1
                let dh = String(format: "%02d", Int(durSecs) / 3600)
                let dm = String(format: "%02d", (Int(durSecs) % 3600) / 60)
                let ds = String(format: "%02d", Int(durSecs) % 60)

                var chapters: [VideoChapter] = []
                if let arr = json["chapters"] as? [[String: Any]] {
                    for ch in arr {
                        guard let t = ch["title"]      as? String,
                              let s = ch["start_time"] as? Double,
                              let e = ch["end_time"]   as? Double else { continue }
                        chapters.append(VideoChapter(title: t, startTime: Int(s), endTime: Int(e)))
                    }
                }

                var videoFormats: [VideoFormatInfo] = []
                var audioFormats: [AudioFormatInfo] = []
                var seen = Set<String>()   // deduplicate by (height, ext, codec family)

                if let fmts = json["formats"] as? [[String: Any]] {

                    for fmt in fmts.reversed() {
                        guard let fid  = fmt["format_id"] as? String else { continue }
                        let ext        = fmt["ext"]    as? String ?? ""
                        let vcodec     = fmt["vcodec"] as? String ?? "none"
                        let acodec     = fmt["acodec"] as? String ?? "none"

                        guard ext != "mhtml" else { continue }
                        let hasVideo = vcodec != "none" && !vcodec.isEmpty
                        let hasAudio = acodec != "none" && !acodec.isEmpty
                        guard hasVideo || hasAudio else { continue }

                        let height   = fmt["height"]   as? Int
                        let fps      = fmt["fps"]      as? Double
                        let abr      = fmt["abr"]      as? Double
                        let tbr      = fmt["tbr"]      as? Double
                        let filesize = (fmt["filesize"] as? Int64) ?? (fmt["filesize_approx"] as? Int64)

                        if hasVideo {
                            let codecFamily: String
                            if vcodec.hasPrefix("avc") { codecFamily = "h264" }
                            else if vcodec.hasPrefix("vp9") || vcodec.hasPrefix("vp0") { codecFamily = "vp9" }
                            else if vcodec.hasPrefix("av0") { codecFamily = "av1" }
                            else { codecFamily = vcodec }

                            let dedupeKey = "\(height ?? 0)-\(codecFamily)-\(ext)"
                            guard !seen.contains(dedupeKey) else { continue }
                            seen.insert(dedupeKey)

                            videoFormats.append(VideoFormatInfo(
                                id: fid, ext: ext, height: height,
                                fps: fps, vcodec: vcodec, filesize: filesize, tbr: tbr))
                        } else if hasAudio && !hasVideo {
                            let dedupeKey = "audio-\(acodec)-\(ext)"
                            guard !seen.contains(dedupeKey) else { continue }
                            seen.insert(dedupeKey)

                            audioFormats.append(AudioFormatInfo(
                                id: fid, ext: ext, acodec: acodec,
                                abr: abr, filesize: filesize))
                        }
                    }
                }
                videoFormats.sort {
                    if ($0.height ?? 0) != ($1.height ?? 0) { return ($0.height ?? 0) > ($1.height ?? 0) }
                    return ($0.tbr ?? 0) > ($1.tbr ?? 0)
                }
                audioFormats.sort { ($0.abr ?? 0) > ($1.abr ?? 0) }

                // ── Subtitles ───────────────────────────────────────────────────

                func langKeys(_ dict: [String: Any]?) -> [String] {
                    guard let d = dict else { return [] }
                    return d.keys.filter { k in
                        k.count >= 2 && k.count <= 10 && k != "live_chat"
                        && k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
                    }.sorted()
                }
                let manualLangs = langKeys(json["subtitles"]          as? [String: Any])
                let autoLangs   = langKeys(json["automatic_captions"] as? [String: Any])
                let origLangs   = autoLangs.filter { $0.hasSuffix("-orig") }

                let subLangs: [String]
                if !manualLangs.isEmpty       { subLangs = manualLangs }
                else if !origLangs.isEmpty    { subLangs = origLangs   }
                else                          { subLangs = autoLangs   }

                cont.resume(returning: .success(VideoMeta(
                    title: title, thumbnail: thumbnail,
                    duration: durationString, durationH: dh, durationM: dm, durationS: ds,
                    hasSubs: !subLangs.isEmpty, chapters: chapters,
                    availableSubLangs: subLangs,
                    videoFormats: videoFormats, audioFormats: audioFormats,
                    nEntries: nEntries)))
            }
            do { try proc.run() } catch { cont.resume(returning: .failure(error)) }
        }
    }

    
            // MARK: - Playlist fetch

    func fetchPlaylist(url: String, authArgs: [String] = []) async -> Result<[PlaylistItem], Error> {
        guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
            return .failure(NSError(domain: "yoink", code: 1, userInfo: [NSLocalizedDescriptionKey: "yt-dlp not found"]))
        }
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)

            proc.arguments = authArgs + [
                "--flat-playlist",
                "--print", "%(playlist_index)s",
                "--print", "%(id)s",
                "--print", "%(title)s",
                "--print", "%(duration)s",
                "--print", "%(thumbnail)s",
                "--print", "---YOINK---",
                "--no-warnings",
                url
            ]
            let outPipe3 = Pipe(); let errPipe3 = Pipe()
            proc.standardOutput = outPipe3; proc.standardError = errPipe3
            final class PlBox: @unchecked Sendable { var data = Data() }
            let plBox = PlBox(); let plLock = NSLock()
            outPipe3.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData; guard !d.isEmpty else { return }
                plLock.lock(); plBox.data.append(d); plLock.unlock()
            }
            errPipe3.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
            proc.terminationHandler = { _ in
                outPipe3.fileHandleForReading.readabilityHandler = nil
                errPipe3.fileHandleForReading.readabilityHandler = nil
                plLock.lock()
                plBox.data.append(outPipe3.fileHandleForReading.readDataToEndOfFile())
                let raw = String(data: plBox.data, encoding: .utf8) ?? ""
                plLock.unlock()
                var items: [PlaylistItem] = []
                let lines = raw.components(separatedBy: "\n")
                var i = 0
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespacesAndNewlines) == "---YOINK---" {
                        i += 1; continue
                    }
                    guard i + 5 < lines.count else { i += 1; continue }
                    let idxStr  = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    let vid     = lines[i+1].trimmingCharacters(in: .whitespacesAndNewlines)
                    let ttl     = lines[i+2].trimmingCharacters(in: .whitespacesAndNewlines)
                    let durStr  = lines[i+3].trimmingCharacters(in: .whitespacesAndNewlines)
                    let thumb   = lines[i+4].trimmingCharacters(in: .whitespacesAndNewlines)
                    let sep     = lines[i+5].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard sep == "---YOINK---" else { i += 1; continue }
                    guard !vid.isEmpty, vid != "NA" else { i += 6; continue }
                    let idx = Int(idxStr) ?? items.count + 1
                    let title = (ttl.isEmpty || ttl == "NA") ? "(No title)" : ttl
                    let durSecs = Int(Double(durStr) ?? 0)
                    let dh = durSecs / 3600; let dm = (durSecs % 3600) / 60; let ds = durSecs % 60
                    let dur: String
                    if durSecs == 0 || durStr == "NA" || durStr.isEmpty {
                        dur = "" // unknown - hide rather than show 0:00
                    } else if dh > 0 {
                        dur = String(format: "%d:%02d:%02d", dh, dm, ds)
                    } else {
                        dur = String(format: "%d:%02d", dm, ds)
                    }
                    let thumbnail = (thumb == "NA" || thumb.isEmpty) ? "" : thumb
                    let item = PlaylistItem(index: idx, videoID: vid, title: title, duration: dur)
                    item.thumbnail = thumbnail
                    items.append(item)
                    i += 6
                }
                if items.isEmpty {
                    cont.resume(returning: .failure(NSError(domain: "yoink", code: 2, userInfo: [NSLocalizedDescriptionKey: "No playlist items found. Check the URL or try again."])))
                } else {
                    cont.resume(returning: .success(items))
                }
            }
            do { try proc.run() } catch { cont.resume(returning: .failure(error)) }
        }
    }

    // MARK: - Advanced mode: start individual playlist item download

    func startPlaylistItem(_ item: PlaylistItem, baseURL: String, outputDir: URL, authArgs: [String] = []) {
        Task {
            guard let path = await DependencyService.shared.resolvePath(for: "yt-dlp"),
                  let ffPath = await DependencyService.shared.resolvePath(for: "ffmpeg") else { return }
            await launchPlaylistItem(item, baseURL: baseURL, outputDir: outputDir,
                                     ytdlpPath: path, ffmpegPath: ffPath, authArgs: authArgs)
        }
    }

    @MainActor
    private func launchPlaylistItem(_ item: PlaylistItem, baseURL: String, outputDir: URL,
                                     ytdlpPath: String, ffmpegPath: String, authArgs: [String]) async {
        var args: [String] = []
        if !item.selectedVideoFormatId.isEmpty && item.selectedVideoFormatId != "audio" {
            let audioId = item.selectedAudioFormatId.isEmpty
                ? (item.audioFormats.first?.id ?? "bestaudio")
                : item.selectedAudioFormatId
            args += ["-f", "\(item.selectedVideoFormatId)+\(audioId)"]
            args += ["--merge-output-format", "mp4"]
        } else if item.selectedVideoFormatId == "audio" {
            let audioId = item.selectedAudioFormatId.isEmpty ? "bestaudio" : item.selectedAudioFormatId
            args += ["-f", audioId]
        } else {
            args += ["-f", item.format.rawValue]
            if !item.format.isAudio { args += ["--merge-output-format", "mp4"] }
        }
        args += ["--ffmpeg-location", ffmpegPath]
        if item.downloadSubs && !item.subLang.isEmpty {
            args += ["--write-subs", "--write-auto-subs", "--sub-lang", item.subLang, "--sub-format", "srt/vtt/best"]
        }
        if item.sponsorBlock {
            args += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            args += ["--write-info-json"]
            args += ["--remux-video", "mp4"]
        }

        let hasStart = !item.startH.isEmpty || !item.startM.isEmpty || !item.startS.isEmpty
        let hasEnd   = item.endH != "00" || item.endM != "00" || item.endS != "00"
        if hasStart || hasEnd {
            let sH = Int(item.startH) ?? 0
            let sM = Int(item.startM) ?? 0
            let sS = Int(item.startS) ?? 0
            let eH = Int(item.endH)   ?? 0
            let eM = Int(item.endM)   ?? 0
            let eS = Int(item.endS)   ?? 0
            let s  = sH * 3600 + sM * 60 + sS
            let e  = eH * 3600 + eM * 60 + eS
            if e > s { args += ["--download-sections", "*\(s)-\(e)", "--force-keyframes-at-cuts"] }
        }

        args += authArgs
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink-frags", isDirectory: true)
        args += ["--paths", "home:\(outputDir.path)", "--paths", "temp:\(tempDir.path)", "--no-keep-fragments"]
        args += ["-o", "%(title)s.%(ext)s", "--newline",
                 "--progress-template", "%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.fragment_index)s|%(progress.fragment_count)s"]

        let videoURL: String
        if baseURL.contains("youtube.com") || baseURL.contains("youtu.be") {
            videoURL = "https://www.youtube.com/watch?v=\(item.videoID)"
        } else {
            videoURL = baseURL  // other platforms use the base URL with --playlist-items
            args += ["--playlist-items", String(item.index)]
        }
        args.append(videoURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlpPath)
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = outPipe

        proc.terminationHandler = { p in
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async {
                item.downloadStatus = ok ? .done : .failed
                if ok {
                    Haptics.success()
                    let doneFile = primaryMediaFile(in: outputDir) ?? outputDir
                    HistoryStore.shared.add(HistoryEntry(
                        id: UUID(),
                        title: item.title,
                        thumbnail: item.thumbnail,
                        url: baseURL,
                        outputPath: doneFile.path,
                        date: Date(),
                        format: item.selectedVideoFormatId.isEmpty
                            ? item.format.displayName
                            : "\(item.selectedVideoFormatId)+\(item.selectedAudioFormatId)",
                        fileSize: {
                            let sz = (try? doneFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                            return Int64(sz)
                        }()))
                    sendCompletionNotification(outputDir: outputDir, title: item.title,
                                               exactFilePath: doneFile.path)
                } else {
                    Haptics.error()
                }
            }
        }
        do    { try proc.run() }
        catch { DispatchQueue.main.async { item.downloadStatus = .failed } }
        item.downloadStatus = .downloading
    }

    // Re-fetch after cookies change
    func refetchMetadata(for job: DownloadJob) {
        guard job.hasURL else { return }
        fetchMetadata(for: job)
    }

    // MARK: Download

    func start(job: DownloadJob, outputDir: URL) {
        guard job.hasURL else { return }
        // Apply per-site format override if the user hasn't picked a specific format for this job
        let sm = SettingsManager.shared
        if job.format == .best && job.selectedVideoFormatId.isEmpty && job.selectedAudioFormatId.isEmpty {
            if let siteOverride = sm.siteFormat(for: job.url) {
                job.format = siteOverride
            }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard let ytdlpPath = await DependencyService.shared.resolvePath(for: "yt-dlp") else {
                await MainActor.run { job.status = .failed("yt-dlp not found") }
                return
            }
            let ffmpegPath = await DependencyService.shared.resolvePath(for: "ffmpeg")
            await self.run(job: job, ytdlpPath: ytdlpPath, ffmpegPath: ffmpegPath, outputDir: outputDir)
        }
    }

    private func run(job: DownloadJob, ytdlpPath: String, ffmpegPath: String?, outputDir: URL) async {
        job.status         = .fetching
        job.log            = []
        job.downloadedBytes = 0
        job.totalBytes      = 0
        Haptics.start()
        let args   = job.buildArguments(outputDir: outputDir, ffmpegPath: ffmpegPath)
        job.appendLog("$ yt-dlp " + args.joined(separator: " "), kind: .command)

        // Subtitle keep-ranges for segment/chapter selection.
        let subtitleKeepRanges: [(startMs: Int, endMs: Int)] = {
            guard job.useSegment && job.downloadSubs else { return [] }
            switch job.segmentMode {
            case .manual:
                let sH = Int(job.startH) ?? 0; let sM = Int(job.startM) ?? 0; let sS = Int(job.startS) ?? 0
                let eH = Int(job.endH)   ?? 0; let eM = Int(job.endM)   ?? 0; let eS = Int(job.endS)   ?? 0
                let startMs = (sH * 3600 + sM * 60 + sS) * 1000
                let endMs   = (eH * 3600 + eM * 60 + eS) * 1000
                guard endMs > startMs else { return [] }
                return [(startMs: startMs, endMs: endMs)]
            case .chapters:
                guard let chapters = job.meta?.chapters else { return [] }
                return chapters
                    .filter { job.selectedChapters.contains($0.id) }
                    .map { (startMs: $0.startTime * 1000, endMs: $0.endTime * 1000) }
            }
        }()

        // Capture SponsorBlock removed segments for subtitle retiming.
        final class SegBox: @unchecked Sendable { var segs: [(startMs: Int, endMs: Int)] = [] }
        let segBox = SegBox(); let segLock = NSLock()

        // Capture the exact output file path from yt-dlp's "[download] Destination:" log line.
        // This is more reliable than scanning the folder - it's the filename yt-dlp chose.
        // We also watch for "[Merger] Merging formats into" for merged (video+audio) outputs.
        final class FileBox: @unchecked Sendable { var path: String = "" }
        let fileBox = FileBox(); let fileLock = NSLock()

        // Snapshot Twitch fragment count once (MainActor property - can't read from Sendable closure)
        final class FragBox: @unchecked Sendable { var count: Int = 0 }
        let fragBox = FragBox()
        fragBox.count = job.twitchTotalFragments

        // Snapshot segment duration (seconds) for ffmpeg progress % computation.
        // When yt-dlp runs ffmpeg directly (--download-sections), we get time= not fragment_index.
        let segStartSecs: Double = {
            let h = Double(job.startH) ?? 0
            let m = Double(job.startM) ?? 0
            let s = Double(job.startS) ?? 0
            return h * 3600 + m * 60 + s
        }()
        let segEndSecs: Double = {
            let h = Double(job.endH) ?? 0
            let m = Double(job.endM) ?? 0
            let s = Double(job.endS) ?? 0
            return h * 3600 + m * 60 + s
        }()
        // If no segment set, fall back to full video duration
        let segDurationSecs: Double = {
            let d = segEndSecs - segStartSecs
            if d > 0 { return d }
            // full duration from meta
            let h = Double(job.meta?.durationH ?? "0") ?? 0
            let m = Double(job.meta?.durationM ?? "0") ?? 0
            let s = Double(job.meta?.durationS ?? "0") ?? 0
            return h * 3600 + m * 60 + s
        }()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Create a unique temp working directory for this download.
            // yt-dlp writes all fragment/temp files relative to its working directory.
            // By isolating each download here, fragments never appear in the output folder.
            // The temp dir is deleted after the process exits.
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("yoink-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ytdlpPath)
            proc.arguments     = args
            proc.currentDirectoryURL = workDir
            let stdout = Pipe(), stderr = Pipe()
            proc.standardOutput = stdout; proc.standardError = stderr
            job.process = proc

            job.downloadedBytes = 0
            job.totalBytes      = 0

            proc.qualityOfService = SettingsManager.shared.processPriority.qualityOfService

            stdout.fileHandleForReading.readabilityHandler = { [weak job] handle in
                guard let job else { return }
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                struct Update {
                    var status: JobStatus?
                    var dlBytes: Int64?
                    var totBytes: Int64?
                    var logLine: (String, LogLine.Kind)?
                    var speedKBps: Double?   // for sparkline
                }
                var update = Update()
                for raw in text.components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    let parts = line.components(separatedBy: "|")
                    if parts.count >= 4 {
                        let pctStr    = parts[0].trimmingCharacters(in: .whitespaces)
                        let speedStr  = parts[1].trimmingCharacters(in: .whitespaces)
                        let etaStr    = parts[2].trimmingCharacters(in: .whitespaces)
                        let statusStr = parts[3].trimmingCharacters(in: .whitespaces)
                        let dlBytes   = parts.indices.contains(4) ? Int64(parts[4].trimmingCharacters(in: .whitespaces)) : nil
                        let totBytes  = parts.indices.contains(5) ? Int64(parts[5].trimmingCharacters(in: .whitespaces)) : nil
                        let estBytes  = parts.indices.contains(6) ? Int64(parts[6].trimmingCharacters(in: .whitespaces)) : nil
                        let fragIdx   = parts.indices.contains(7) ? Int(parts[7].trimmingCharacters(in: .whitespaces)) : nil
                        let fragCount = parts.indices.contains(8) ? Int(parts[8].trimmingCharacters(in: .whitespaces)) : nil
                        if let dl  = dlBytes,  dl  > 0 { update.dlBytes  = dl }
                        if let tot = totBytes, tot > 0 { update.totBytes  = tot }
                        else if let est = estBytes, est > 0 { update.totBytes = est }
                        // Parse speed string for sparkline (e.g. "2.34MiB/s", "512.00KiB/s")
                        if speedStr != "N/A" && !speedStr.isEmpty {
                            let s = speedStr.lowercased()
                            if let v = Double(s.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "/"))).first ?? "") {
                                if s.contains("mib") || s.contains("mb") { update.speedKBps = v * 1024 }
                                else if s.contains("gib") || s.contains("gb") { update.speedKBps = v * 1024 * 1024 }
                                else { update.speedKBps = v }   // already KiB/s
                            }
                        }
                        if statusStr.contains("merg") || statusStr.contains("finish") {
                            let speed = speedStr == "N/A" ? "" : "  \(speedStr)"
                            update.status  = .merging
                            update.logLine = ("Merging…\(speed)", .progress)
                        } else if let pct = Double(pctStr.replacingOccurrences(of: "%", with: "")) {
                            var label = "\(Int(pct))%"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            if etaStr   != "N/A" && !etaStr.isEmpty   { label += "  ETA \(etaStr)" }
                            update.status  = .downloading(min(pct / 100.0, 1.0))
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, let fc = fragCount, fc > 0 {
                            // Known fragment count (e.g. from yt-dlp output)
                            let pct = Double(fi) / Double(fc)
                            var label = "\(Int(pct * 100))%  frag \(fi)/\(fc)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(min(pct, 1.0))
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0,
                                  fragBox.count > 0 {
                            // Twitch VOD: use pre-fetched fragment count from M3U8 for real %
                            let totalFrags = fragBox.count
                            let pct = min(Double(fi) / Double(totalFrags), 1.0)
                            var label = "\(Int(pct * 100))%  frag \(fi)/\(totalFrags)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            if etaStr   != "N/A" && !etaStr.isEmpty   { label += "  ETA \(etaStr)" }
                            update.status  = .downloading(pct)
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0,
                                  let dl = dlBytes, let tot = totBytes ?? estBytes, tot > 0 {
                            // Twitch live/HLS: no total fragment count, but we have byte counts
                            let pct = min(Double(dl) / Double(tot), 1.0)
                            var label = "\(Int(pct * 100))%  frag \(fi)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(pct)
                            update.logLine = (label, .progress)
                        } else if let fi = fragIdx, fi > 0 {
                            // Twitch live: only fragment index known, no total - show frag counter
                            var label = "frag \(fi)"
                            if speedStr != "N/A" && !speedStr.isEmpty { label += "  \(speedStr)" }
                            update.status  = .downloading(0)
                            update.logLine = (label, .progress)
                        } else if !pctStr.isEmpty && pctStr != "N/A" {
                            update.logLine = (pctStr, .progress)
                        }
                    } else {
                        if line.lowercased().contains("[merger]") || line.lowercased().contains("[ffmpeg]") {
                            update.status = .merging
                        }
                        // Capture the final output path from yt-dlp's own log lines.
                        // "[download] Destination: /path/file.mp4"  - intermediate or final file
                        // "[Merger] Merging formats into "/path/file.mp4""  - merged output (most reliable)
                        // "[MoveFiles] Moving file ..." can also appear - use Merger/MoveFiles as authoritative
                        let lower = line.lowercased()
                        if lower.hasPrefix("[merger] merging formats into") || lower.hasPrefix("[movefiles] moving file") {
                            // Extract path from quoted string if present, otherwise after last space
                            var captured = ""
                            if let q1 = line.firstIndex(of: Character("\"")), let q2 = line.lastIndex(of: Character("\"")), q1 != q2 {
                                captured = String(line[line.index(after: q1)..<q2])
                            } else if let space = line.lastIndex(of: " ") {
                                captured = String(line[line.index(after: space)...])
                            }
                            if !captured.isEmpty {
                                fileLock.lock(); fileBox.path = captured; fileLock.unlock()
                            }
                        } else if lower.hasPrefix("[download] destination:") {
                            let dest = line.dropFirst("[download] Destination:".count).trimmingCharacters(in: .whitespaces)
                            // Only store media files, not .part/.ytdl temp files
                            let ext = (dest as NSString).pathExtension.lowercased()
                            let tempExts: Set<String> = ["part", "ytdl", "tmp"]
                            if !dest.isEmpty && !tempExts.contains(ext) {
                                fileLock.lock()
                                // Prefer to keep the last Destination line - it's usually the merged output
                                fileBox.path = dest
                                fileLock.unlock()
                            }
                        }
                        update.logLine = (line, .info)
                    }
                }
                DispatchQueue.main.async {
                    if let dl  = update.dlBytes  { job.downloadedBytes = dl }
                    if let tot = update.totBytes  { job.totalBytes = tot }
                    if let s   = update.status    { job.status = s }
                    if let (msg, kind) = update.logLine { job.appendLog(msg, kind: kind) }
                    if let spd = update.speedKBps {
                        job.speedHistory.append(spd)
                        if job.speedHistory.count > 40 { job.speedHistory.removeFirst() }
                    }
                }
            }

            stderr.fileHandleForReading.readabilityHandler = { [weak job] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                var isMerging = false
                var progressMsg: String? = nil
                var otherMsg: String? = nil
                var otherKind: LogLine.Kind = .info
                for raw in text.components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }

                    if line.hasPrefix("[SponsorBlock]"), line.contains("Skipping") {
                        let parts = line.components(separatedBy: " ")
                        if let dashIdx = parts.firstIndex(of: "-"), dashIdx > 0, dashIdx + 1 < parts.count {
                            let startMs = subTimeToMs(parts[dashIdx - 1])
                            let endMs   = subTimeToMs(parts[dashIdx + 1])
                            if endMs > startMs {
                                segLock.lock()
                                segBox.segs.append((startMs: startMs, endMs: endMs))
                                segLock.unlock()
                            }
                        }
                    }

                    if line.hasPrefix("frame=") {
                        // frame= lines come from ffmpeg during segment cutting or post-processing.
                        // Do NOT set status to .merging here - that's misleading when the video is
                        // still being downloaded/cut. Only set .merging when yt-dlp itself reports
                        // a merge (handled via stdout statusStr check above).
                        if let timeRange  = line.range(of: "time="),
                           let speedRange = line.range(of: "speed=") {
                            let timeStr  = String(line[timeRange.upperBound...].prefix(11)).trimmingCharacters(in: .whitespaces)
                            let speedStr = String(line[speedRange.upperBound...].prefix(8)).trimmingCharacters(in: .whitespaces)

                            // Parse HH:MM:SS.ss → seconds
                            let timeParts = timeStr.components(separatedBy: ":")
                            var currentSecs: Double = 0
                            if timeParts.count == 3 {
                                currentSecs = (Double(timeParts[0]) ?? 0) * 3600
                                           + (Double(timeParts[1]) ?? 0) * 60
                                           + (Double(timeParts[2]) ?? 0)
                            }

                            let pct: Double
                            if segDurationSecs > 0 {
                                pct = min(currentSecs / segDurationSecs, 1.0)
                            } else {
                                pct = 0
                            }

                            let pctStr = segDurationSecs > 0 ? "\(Int(pct * 100))%" : timeStr
                            let label = "Processing… \(pctStr)  \(speedStr)"
                            progressMsg = label

                            // Push a real downloading status so the progress bar fills
                            DispatchQueue.main.async {
                                guard let job else { return }
                                job.status = .downloading(pct)
                                if let idx = job.log.indices.last(where: { job.log[$0].kind == .progress }) {
                                    job.log[idx] = LogLine(text: label, kind: .progress)
                                } else {
                                    job.appendLog(label, kind: .progress)
                                }
                            }
                            progressMsg = nil  // handled above directly, skip deferred update
                        }
                    } else if !line.hasPrefix("[https @") && !line.hasPrefix("[hls @") && !line.hasPrefix("[mp4 @") {
                        let up = line.uppercased()
                        otherKind = up.hasPrefix("WARNING:") ? .warning : up.hasPrefix("ERROR:") ? .error : .info
                        otherMsg = line
                    }
                }
                DispatchQueue.main.async {
                    // isMerging is only true if set explicitly (currently unused path - kept for future use)
                    if isMerging { job?.status = .merging }
                    if let msg = progressMsg {
                        if let idx = job?.log.indices.last(where: { job?.log[$0].kind == .progress }) {
                            job?.log[idx] = LogLine(text: msg, kind: .progress)
                        } else {
                            job?.appendLog(msg, kind: .progress)
                        }
                    } else if let msg = otherMsg {
                        job?.appendLog(msg, kind: otherKind)
                    }
                }
            }

            proc.terminationHandler = { [weak job] p in
                DispatchQueue.main.async {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    guard let job else { return }

                    // Move the finished file(s) from workDir into outputDir,
                    // then delete workDir entirely — all fragments go with it.
                    func moveOutputAndClean(capturedPath: String) -> String {
                        let fm = FileManager.default
                        var finalPath = capturedPath
                        // Move every media file yt-dlp wrote to workDir into outputDir
                        let mediaExts = Set(["mp4","mkv","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac","srt","vtt"])
                        if let items = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil, options: []) {
                            try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
                            for item in items where mediaExts.contains(item.pathExtension.lowercased()) {
                                let dest = outputDir.appendingPathComponent(item.lastPathComponent)
                                try? fm.moveItem(at: item, to: dest)
                                // Track the primary media file path
                                if item.path == capturedPath || finalPath.isEmpty {
                                    finalPath = dest.path
                                } else if !["srt","vtt"].contains(item.pathExtension.lowercased()) {
                                    finalPath = dest.path
                                }
                            }
                        }
                        // Wipe workDir — takes all fragments with it
                        try? fm.removeItem(at: workDir)
                        return finalPath
                    }

                    switch p.terminationStatus {
                    case 0:
                        segLock.lock(); let segs0 = segBox.segs; segLock.unlock()
                        fileLock.lock(); let path0 = fileBox.path; fileLock.unlock()
                        let movedPath0 = moveOutputAndClean(capturedPath: path0)
                        let job0 = job
                        Task { @MainActor in
                            await self.finishDownload(job: job0, capturedPath: movedPath0, outputDir: outputDir,
                                           sponsorSegs: segs0, subtitleKeepRanges: subtitleKeepRanges)
                        }
                        Haptics.success()
                    case 1:
                        let logText = job.log.map(\.text).joined(separator: "\n")
                        let hasRealError = logText.contains("ERROR:") &&
                                          !logText.contains("ERROR: unable to download video subtitles")
                        if hasRealError {
                            job.status = .failed("Download failed - check log for details")
                            job.appendLog("✗ Failed (code 1)", kind: .error)
                            Haptics.error()
                            try? FileManager.default.removeItem(at: workDir)
                        } else {
                            segLock.lock(); let segs1 = segBox.segs; segLock.unlock()
                            fileLock.lock(); let path1 = fileBox.path; fileLock.unlock()
                            let movedPath1 = moveOutputAndClean(capturedPath: path1)
                            let job1 = job
                            Task { @MainActor in
                                await self.finishDownload(job: job1, capturedPath: movedPath1, outputDir: outputDir,
                                               sponsorSegs: segs1, subtitleKeepRanges: subtitleKeepRanges)
                            }
                            Haptics.success()
                        }
                    case 15:   // SIGTERM (user cancel)
                        try? FileManager.default.removeItem(at: workDir)
                    default:
                        job.status = .failed("Exited with code \(p.terminationStatus)")
                        job.appendLog("✗ Failed (code \(p.terminationStatus))", kind: .error)
                        Haptics.error()
                        try? FileManager.default.removeItem(at: workDir)
                    }
                    if let cookieURL = job.cookieTempURL {
                        try? FileManager.default.removeItem(at: cookieURL)
                    }
                    cont.resume()
                }
            }
            do    { try proc.run() }
            catch { DispatchQueue.main.async { job.status = .failed(error.localizedDescription); cont.resume() } }
        }
    }

    // MARK: - Shared download-completion handler

    private func finishDownload(job: DownloadJob?,
                                 capturedPath: String,
                                 outputDir: URL,
                                 sponsorSegs: [(startMs: Int, endMs: Int)],
                                 subtitleKeepRanges: [(startMs: Int, endMs: Int)]) async {
        cleanSubtitles(in: outputDir, sponsorSegments: sponsorSegs.sorted { $0.startMs < $1.startMs },
                       keepRanges: subtitleKeepRanges)
        var rawDoneFile: URL = {
            if !capturedPath.isEmpty && FileManager.default.fileExists(atPath: capturedPath) {
                return URL(fileURLWithPath: capturedPath)
            }
            return primaryMediaFile(in: outputDir) ?? outputDir
        }()

        let sm = SettingsManager.shared
        if sm.autoOrganizeBySite, let jobURL = job?.url,
           let host = URLComponents(string: jobURL)?.host?.lowercased() {
            let siteName = Self.siteFolderName(from: host)
            let siteDir = outputDir.appendingPathComponent(siteName)
            try? FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
            let dest = siteDir.appendingPathComponent(rawDoneFile.lastPathComponent)
            if rawDoneFile != dest, (try? FileManager.default.moveItem(at: rawDoneFile, to: dest)) != nil {
                rawDoneFile = dest
            }
        }

        let doneFile = rawDoneFile
        job?.status = .done(doneFile)
        job?.appendLog("✓ Download complete", kind: .success)

        let convertAction = sm.postConvert
        if convertAction != .none, let ffmpegPath = await DependencyService.shared.resolvePath(for: "ffmpeg") {
            let inputExt  = doneFile.pathExtension
            let outputExt = convertAction.outputExt(inputExt: inputExt)
            let outputFile = doneFile.deletingPathExtension().appendingPathExtension(outputExt)
            if let ffArgs = convertAction.ffmpegArgs(inputExt: inputExt) {
                job?.appendLog("⚙ Converting: \(convertAction.label)…", kind: .info)
                let args = ["-i", doneFile.path] + ffArgs + ["-y", outputFile.path]
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpegPath)
                proc.arguments = args
                proc.standardOutput = Pipe(); proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        try? FileManager.default.removeItem(at: doneFile)
                        job?.status = .done(outputFile)
                        job?.appendLog("✓ Converted to \(outputExt.uppercased())", kind: .success)
                        finishWithFile(outputFile, job: job, sm: sm, outputDir: outputDir)
                    } else {
                        job?.appendLog("⚠ Conversion failed - keeping original", kind: .warning)
                        finishWithFile(doneFile, job: job, sm: sm, outputDir: outputDir)
                    }
                    return
                }
            }
        }

        finishWithFile(doneFile, job: job, sm: sm, outputDir: outputDir)
    }

    /// Removes all yt-dlp/ffmpeg fragment and temp files from outputDir recursively.
    /// Does NOT use .skipsHiddenFiles — yt-dlp names frag files with a leading dot
    /// (e.g. .fhls-1342.mp4.part-Frag1) which would be silently skipped otherwise.
    nonisolated static func cleanFragmentFiles(in outputDir: URL) {
        let accessing = outputDir.startAccessingSecurityScopedResource()
        defer { if accessing { outputDir.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: outputDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []   // no .skipsHiddenFiles — frag files start with a dot
        ) else { return }

        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let name = file.lastPathComponent
            let ext  = file.pathExtension.lowercased()
            if name.contains(".part-Frag")
                || ext == "part"
                || ext == "ytdl"
                || ext == "aria2"
                || ext == "lock"
                || name.contains(".fhls-")
                || name.contains(".temp.")
                || name.contains(".tmp.")
            {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func finishWithFile(_ doneFile: URL, job: DownloadJob?, sm: SettingsManager, outputDir: URL) {
        guard let j = job else { return }
        HistoryStore.shared.add(HistoryEntry(
            id: UUID(),
            title: j.meta?.title ?? j.url,
            thumbnail: j.meta?.thumbnail ?? "",
            url: j.url,
            outputPath: doneFile.path,
            date: Date(),
            format: j.selectedVideoFormatId.isEmpty
                ? j.format.displayName
                : "\(j.selectedVideoFormatId)+\(j.selectedAudioFormatId)",
            fileSize: {
                let sz = (try? doneFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return Int64(sz)
            }()))
        let action = sm.postDownload
        let videoTitle = j.meta?.title ?? j.url
        let exactPath = doneFile.path
        let thumbURL = j.meta?.thumbnail
        let shortcutName = sm.shortcutOnComplete.trimmingCharacters(in: .whitespaces)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Per-file notification - suppressed when queue-complete mode is on
            if !sm.notifyOnQueueComplete {
                sendCompletionNotification(outputDir: outputDir, title: videoTitle, exactFilePath: exactPath, thumbnailURL: thumbURL)
            }
            if action != .notify {
                executePostDownloadAction(action, outputDir: outputDir, title: videoTitle)
            }
            if !shortcutName.isEmpty {
                Self.runShortcut(named: shortcutName, filePath: exactPath, title: videoTitle)
            }
            // Queue-complete notification: fire once when all jobs have finished
            if sm.notifyOnQueueComplete, let queue = DownloadQueue.shared {
                let allDone = queue.jobs.allSatisfy { $0.status.isTerminal }
                let doneCount = queue.jobs.filter { $0.status.isDone }.count
                if allDone && doneCount > 0 {
                    let title = doneCount == 1
                        ? "Download complete"
                        : "\(doneCount) downloads complete"
                    sendQueueCompleteNotification(title: title, count: doneCount, outputDir: outputDir)
                }
            }
        }
    }

    private static func siteFolderName(from host: String) -> String {
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("twitch")     { return "Twitch" }
        if host.contains("twitter") || host.contains("x.com") { return "Twitter" }
        if host.contains("instagram")  { return "Instagram" }
        if host.contains("tiktok")     { return "TikTok" }
        if host.contains("vimeo")      { return "Vimeo" }
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("reddit")     { return "Reddit" }
        if host.contains("rumble")     { return "Rumble" }
        if host.contains("kick")       { return "Kick" }
        if host.contains("bilibili")   { return "Bilibili" }
        // Generic: use second-level domain
        let parts = host.components(separatedBy: ".")
        return parts.dropLast().last?.capitalized ?? host
    }

    private static func runShortcut(named name: String, filePath: String, title: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        proc.arguments = ["run", name, "--input-path", filePath]
        try? proc.run()
    }

    // MARK: Helpers

    func cookieArgs(for job: DownloadJob) -> [String] {
        guard !job.manualCookies.isEmpty else { return [] }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink_cookies_meta_\(job.id.uuidString).txt")
        try? job.manualCookies.write(to: tmp, atomically: true, encoding: .utf8)
        return ["--cookies", tmp.path]
    }

    /// Deletes the metadata-fetch cookie temp file written by cookieArgs(for:).
    private func cleanupMetaCookies(for job: DownloadJob) {
        guard !job.manualCookies.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink_cookies_meta_\(job.id.uuidString).txt")
        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - Global Thumbnail Cache

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private init() {}

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func image(for url: String) -> NSImage? { images[url] }

    func prefetch(_ urls: [String]) {
        for url in urls { load(url) }
    }

    func load(_ urlStr: String) {
        guard !urlStr.isEmpty, images[urlStr] == nil, !inFlight.contains(urlStr),
              let url = URL(string: urlStr) else { return }
        inFlight.insert(urlStr)
        Task.detached(priority: .background) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = NSImage(data: data) {
                await MainActor.run {
                    self.images[urlStr] = img
                    self.inFlight.remove(urlStr)
                    return
                }
            } else {
                await MainActor.run { self.inFlight.remove(urlStr); return }
            }
        }
    }
}

// MARK: - App Update Service

enum AppUpdateStatus: Equatable {
    case unknown
    case checking
    case upToDate(version: String)
    case available(current: String, latest: String, downloadURL: String)
    case failed(String)
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    private init() {}

    @Published var status: AppUpdateStatus = .unknown
    @Published var showUpdateAlert = false

    // Replace these with your real GitHub release URL when you have the repo
    private let releasesAPIURL = "https://api.github.com/repos/0x1p0/yoink/releases/latest"
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Check

    /// Called from Settings "Check Now" button or on launch.
    func checkForUpdates() {
        status = .checking
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.performCheck()
        }
    }

    /// Daily automatic check - skips if checked recently.
    func checkIfNeeded() {
        let sm = SettingsManager.shared
        guard sm.checkUpdatesOnLaunch else { return }
        let now = Date().timeIntervalSince1970
        guard now - sm.lastAppUpdateCheck > 86_400 else { return }
        sm.lastAppUpdateCheck = now
        checkForUpdates()
    }

    private func performCheck() async {
        guard let url = URL(string: releasesAPIURL) else {
            await MainActor.run { status = .failed("Invalid release URL") }
            return
        }
        do {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else {
                await MainActor.run { status = .failed("Could not parse release info") }
                return
            }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let downloadURL: String
            if let assets = json["assets"] as? [[String: Any]],
               let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
               let browserURL = dmg["browser_download_url"] as? String {
                downloadURL = browserURL
            } else {
                downloadURL = (json["html_url"] as? String) ?? "https://github.com/0x1p0/yoink/releases"
            }

            let current = currentVersion
            let skipped = await MainActor.run { SettingsManager.shared.skippedAppVersion }
            let isNewer = latestVersion.compare(current, options: .numeric) == .orderedDescending

            await MainActor.run {
                if isNewer && latestVersion != skipped {
                    self.status = .available(current: current, latest: latestVersion, downloadURL: downloadURL)
                    self.showUpdateAlert = true
                } else {
                    self.status = .upToDate(version: current)
                }
            }
        } catch {
            await MainActor.run { status = .failed(error.localizedDescription) }
        }
    }

    func openDownloadPage() {
        if case .available(_, _, let urlStr) = status, let u = URL(string: urlStr) {
            NSWorkspace.shared.open(u)
        }
    }

    func skipThisVersion() {
        if case .available(_, let latest, _) = status {
            SettingsManager.shared.skippedAppVersion = latest
        }
        status = .upToDate(version: currentVersion)
        showUpdateAlert = false
    }

    func remindLater() {
        showUpdateAlert = false
    }

    var statusLabel: String {
        switch status {
        case .unknown:                return "Not checked"
        case .checking:               return "Checking…"
        case .upToDate(let v):        return "Up to date (v\(v))"
        case .available(_, let l, _): return "v\(l) available ↑"
        case .failed(let e):          return "Error: \(e)"
        }
    }

    var dotColor: Color {
        switch status {
        case .unknown, .checking: return Color(.systemGray)
        case .upToDate:           return .green
        case .available:          return .orange
        case .failed:             return .red
        }
    }
}
