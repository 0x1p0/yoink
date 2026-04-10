import Foundation
import SwiftUI

// MARK: - Formats

struct VideoFormatInfo: Identifiable, Hashable {
    let id        : String   // format_id e.g. "137"
    let ext       : String   // "mp4", "webm"
    let height    : Int?     // nil for audio-only
    let fps       : Double?
    let vcodec    : String   // "avc1.xxx", "vp9", "av01"
    let filesize  : Int64?   // bytes, nil if unknown
    let tbr       : Double?  // total bitrate kbps

    var label: String {
        let res = height.map { "\($0)p" } ?? "?"
        let codec = vcodec.components(separatedBy: ".").first ?? vcodec
        var s = "\(res) · \(codec.uppercased()) · \(ext.uppercased())"
        if let fps, fps > 30 { s += " · \(Int(fps))fps" }
        if let fs = filesize  { s += "  (\(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file)))" }
        return s
    }
    var ytdlpFormatId: String { id }
}

struct AudioFormatInfo: Identifiable, Hashable {
    let id       : String
    let ext      : String
    let acodec   : String
    let abr      : Double?   // audio bitrate kbps
    let filesize : Int64?

    var label: String {
        let br = abr.map { "\(Int($0))kbps" } ?? "?"
        var s = "\(acodec.uppercased()) · \(ext.uppercased()) · \(br)"
        if let fs = filesize { s += "  (\(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file)))" }
        return s
    }
}

enum DownloadFormat: String, CaseIterable, Identifiable, Hashable {
    case best        = "bestvideo+bestaudio/best"
    case mp4_1080    = "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]/best"
    case mp4_720     = "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]/best"
    case mp4_480     = "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best[height<=480]/best"
    case mp4_360     = "bestvideo[height<=360][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=360]+bestaudio/best[height<=360]/best"
    case audioBest   = "bestaudio/best"
    case audioMP3    = "bestaudio[ext=mp3]/bestaudio"
    case audioM4A    = "bestaudio[ext=m4a]/bestaudio"
    case audioOpus   = "bestaudio[ext=opus]/bestaudio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .best:      return "Best available"
        case .mp4_1080:  return "1080p · H.264"
        case .mp4_720:   return "720p · H.264"
        case .mp4_480:   return "480p · H.264"
        case .mp4_360:   return "360p · H.264"
        case .audioBest: return "Audio · best"
        case .audioMP3:  return "Audio · MP3"
        case .audioM4A:  return "Audio · M4A"
        case .audioOpus: return "Audio · Opus"
        }
    }
    var isAudio: Bool {
        switch self {
        case .audioBest, .audioMP3, .audioM4A, .audioOpus: return true
        default: return false
        }
    }
    var icon: String { isAudio ? "waveform" : "film" }
}

// MARK: - Job Status

enum JobStatus: Equatable {
    case idle
    case fetching
    case downloading(Double)
    case paused(Double)      // NEW: paused mid-download, holds last progress
    case merging
    case done(URL)
    case failed(String)
    case cancelled

    var progress: Double {
        switch self {
        case .downloading(let p): return p
        case .paused(let p):      return p
        case .merging, .done:     return 1.0
        default:                  return 0
        }
    }
    var isActive: Bool {
        switch self { case .fetching, .downloading, .merging: return true; default: return false }
    }
    var isPaused: Bool {
        if case .paused = self { return true }; return false
    }
    var isTerminal: Bool {
        switch self { case .done, .failed, .cancelled: return true; default: return false }
    }
    var isDone: Bool { if case .done = self { return true }; return false }
    var shortLabel: String {
        switch self {
        case .idle:               return "Ready"
        case .fetching:           return "Fetching…"
        case .downloading(let p): return "\(Int(p * 100))%"
        case .paused(let p):      return "Paused \(Int(p * 100))%"
        case .merging:            return "Merging…"
        case .done:               return "Done"
        case .failed:             return "Failed"
        case .cancelled:          return "Cancelled"
        }
    }
    var accentColor: Color {
        switch self {
        case .idle:         return .secondary
        case .fetching:     return .orange
        case .downloading:  return .accentColor
        case .paused:       return .yellow
        case .merging:      return .purple
        case .done:         return .green
        case .failed:       return .red
        case .cancelled:    return .secondary
        }
    }
}

// MARK: - Metadata Fetch State

enum MetaFetchState: Equatable {
    case idle
    case fetching
    case done
    case needsAuth          // no cookies set, auth required
    case needsAuthRetry     // cookies set but still failing auth
}

// MARK: - Log Line

struct LogLine: Identifiable {
    let id   = UUID()
    let text : String
    let kind : Kind
    enum Kind { case command, info, progress, success, warning, error }
}

// MARK: - Chapter (video section)

struct VideoChapter: Identifiable {
    let id        = UUID()
    let title     : String
    let startTime : Int    // seconds
    let endTime   : Int    // seconds
    var startHMS  : String { secondsToHMS(startTime) }
    var endHMS    : String { secondsToHMS(endTime) }
    var duration  : String { secondsToHMS(endTime - startTime) }

    private func secondsToHMS(_ s: Int) -> String {
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - Video Metadata

struct VideoMeta {
    var title             : String
    var thumbnail         : String
    var duration          : String
    var durationH         : String
    var durationM         : String
    var durationS         : String
    var hasSubs           : Bool
    var chapters          : [VideoChapter] = []
    var availableSubLangs : [String] = []
    var videoFormats      : [VideoFormatInfo] = []   // real formats from yt-dlp
    var audioFormats      : [AudioFormatInfo] = []
    var nEntries          : Int = 1                  // >1 means multi-part (e.g. soop)
}

// MARK: - Download Job

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()

    // Input
    @Published var url    : String        = ""
    @Published var format : DownloadFormat = .best
    // When user picks specific video+audio tracks from the real format list:
    @Published var selectedVideoFormatId : String = ""   // empty = use DownloadFormat
    @Published var selectedAudioFormatId : String = ""   // empty = use DownloadFormat

    @Published var audioOnlyMode : Bool = false

    // Subtitles
    @Published var downloadSubs  : Bool   = false
    @Published var subLang       : String = "en"

    // Segment
    @Published var useSegment      : Bool          = false
    @Published var segmentMode     : SegmentMode   = .manual
    @Published var startH          : String        = ""
    @Published var startM          : String        = ""
    @Published var startS          : String        = ""
    @Published var endH            : String        = ""
    @Published var endM            : String        = ""
    @Published var endS            : String        = ""
    @Published var selectedChapters: Set<UUID>     = []

    enum SegmentMode { case manual, chapters }

    // Playlist
    @Published var isPlaylist       : Bool   = false
    @Published var playlistStart    : String = ""
    @Published var playlistEnd      : String = ""
    @Published var playlistReverse  : Bool   = false
    @Published var playlistRandom   : Bool   = false

    // Advanced flags
    @Published var extraArgs           : String = ""
    @Published var writeDescription    : Bool   = false
    @Published var writeThumbnail      : Bool   = false
    @Published var sponsorBlockOverride: Bool?  = nil

    // Twitch-specific: real quality list fetched directly from Twitch GQL/M3U8
    @Published var twitchQualities      : [TwitchQuality] = []
    @Published var selectedTwitchQuality: TwitchQuality?  = nil
    @Published var twitchTotalFragments : Int  = 0   // from stream M3U8 - enables accurate progress %
    @Published var isTwitchURL          : Bool = false
    @Published var twitchVODInfo        : TwitchVODInfo?  = nil
    @Published var twitchClipInfo       : TwitchClipInfo? = nil

    // Auth
    @Published var manualCookies     : String        = ""
    var metaFetchTask: Task<Void, Never>? = nil

    // Metadata
    @Published var meta            : VideoMeta?    = nil
    @Published var metaState       : MetaFetchState = .idle
    @Published var thumbnailLoaded : Bool = false   // per-card override: user tapped "Load" thumbnail

    // Download state
    @Published var status : JobStatus = .idle
    @Published var log    : [LogLine] = []

    // Size tracking - updated live from progress lines
    @Published var downloadedBytes : Int64 = 0
    @Published var totalBytes      : Int64 = 0   // 0 = unknown
    @Published var speedHistory    : [Double] = []  // KB/s samples for sparkline (max 40)
    @Published var retryCount      : Int      = 0

    var process: Process?

    // Computed
    var hasURL     : Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty }

    var sizeLabel: String? {
        guard totalBytes > 0 else { return nil }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if downloadedBytes > 0 && downloadedBytes < totalBytes {
            let done = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
            return "\(done) / \(total)"
        }
        return total
    }
    var hasCookies : Bool { !manualCookies.isEmpty }
    var isReady    : Bool { hasURL && metaState != .fetching }

    var videoDurationHMS: (h: String, m: String, s: String) {
        guard let m = meta else { return ("00","00","00") }
        return (m.durationH, m.durationM, m.durationS)
    }

    func appendLog(_ text: String, kind: LogLine.Kind = .info) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        log.append(LogLine(text: t, kind: kind))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    func cancel() {
        metaFetchTask?.cancel(); metaFetchTask = nil
        process?.terminate(); process = nil; status = .cancelled
    }

    func reset() { cancel(); status = .idle; log = [] }

    // MARK: Pause / Resume (FIX #5)

    func pause() {
        guard case .downloading(let p) = status, let pid = process?.processIdentifier, pid > 0 else { return }
        kill(pid_t(pid), SIGSTOP)
        status = .paused(p)
        appendLog("⏸ Paused", kind: .info)
    }

    func resume() {
        guard case .paused(let p) = status, let pid = process?.processIdentifier, pid > 0 else { return }
        kill(pid_t(pid), SIGCONT)
        status = .downloading(p)
        appendLog("▶ Resumed", kind: .info)
    }

    private func hmsToSeconds(_ h: String, _ m: String, _ s: String) -> String? {
        let total = (Int(h) ?? 0) * 3600 + (Int(m) ?? 0) * 60 + (Int(s) ?? 0)
        return total > 0 ? String(total) : nil
    }

    static func stripPlaylistParams(from url: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        comps.queryItems = comps.queryItems?.filter { !["list", "index"].contains($0.name) }
        return comps.url?.absoluteString ?? url
    }

    static func looksLikePlaylist(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url) else { return false }
        return comps.queryItems?.contains(where: { $0.name == "list" }) == true
    }

    func buildArguments(outputDir: URL, ffmpegPath: String? = nil) -> [String] {
        var args: [String] = []
        let sm = SettingsManager.shared

        // Audio-only quick toggle takes highest priority
        if audioOnlyMode {
            args += ["-f", "bestaudio/best"]
            args += ["-x", "--audio-format", "mp3"]
        } else if isTwitchURL, let tq = selectedTwitchQuality {
            // Twitch: use the real HLS format ID we got from the M3U8
            args += ["-f", tq.ytdlpFormat]
            if !tq.ytdlpFormat.contains("bestaudio") { args += ["--merge-output-format", "mp4"] }
        } else if selectedVideoFormatId == "audio" {
            let audioId = selectedAudioFormatId.isEmpty ? "" : selectedAudioFormatId
            args += ["-f", audioId.isEmpty ? "bestaudio/best" : audioId]
        } else if !selectedVideoFormatId.isEmpty && !selectedAudioFormatId.isEmpty {
            args += ["-f", "\(selectedVideoFormatId)+\(selectedAudioFormatId)"]
            args += ["--merge-output-format", "mp4"]
        } else if !selectedVideoFormatId.isEmpty {
            args += ["-f", "\(selectedVideoFormatId)+bestaudio/\(selectedVideoFormatId)"]
            args += ["--merge-output-format", "mp4"]
        } else if !selectedAudioFormatId.isEmpty {
            args += ["-f", "bestvideo+\(selectedAudioFormatId)"]
            args += ["--merge-output-format", "mp4"]
        } else {
            args += ["-f", format.rawValue]
            if !format.isAudio && !audioOnlyMode { args += ["--merge-output-format", "mp4"] }
        }

        if let ffmpeg = ffmpegPath {
            args += ["--ffmpeg-location", ffmpeg]
        }

        if !isPlaylist {
            args += ["--no-playlist", "--playlist-items", "1"]
        }

        if useSegment {
            // Never use --force-keyframes-at-cuts: it triggers a full re-encode of the entire
            // source video just to insert keyframes at cut points, making a 28-second clip take
            // minutes instead of seconds. Without it, yt-dlp uses stream-copy (-c copy) which
            // cuts in near-real-time. The tradeoff is cuts land on the nearest existing keyframe
            // (usually within ~1-2s), which is acceptable for the massive speed gain.
            switch segmentMode {
            case .manual:
                let s = hmsToSeconds(startH, startM, startS) ?? "0"
                let e = hmsToSeconds(endH, endM, endS)       ?? "inf"
                args += ["--download-sections", "*\(s)-\(e)"]
            case .chapters:
                if let chapters = meta?.chapters {
                    let sel = chapters.filter { selectedChapters.contains($0.id) }
                    if !sel.isEmpty {
                        for ch in sel {
                            args += ["--download-sections", "*\(ch.startTime)-\(ch.endTime)"]
                        }
                    }
                }
            }
        }

        if downloadSubs {
            let rawLang = subLang.isEmpty ? "en" : subLang
            let lang = rawLang.hasSuffix("-orig")
                ? String(rawLang.dropLast(5))
                : rawLang
            args += ["--write-subs", "--write-auto-subs", "--sub-langs", lang]
            args += ["--no-abort-on-error"]
        }

        let threads = sm.ffmpegThreads
        if threads > 0 {
            args += ["--postprocessor-args", "Merger:-threads \(threads)"]
        }

        // Cookie file - path derived via cookieTempURL, written here then cleaned by DownloadService
        if !manualCookies.isEmpty, let cookieURL = cookieTempURL {
            try? manualCookies.write(to: cookieURL, atomically: true, encoding: .utf8)
            args += ["--cookies", cookieURL.path]
        }

        // Output goes into the temp workDir (set via proc.currentDirectoryURL in DownloadService).
        // yt-dlp writes both the final file AND all fragments there.
        // After the process exits, DownloadService moves only the final file to outputDir
        // and then deletes the entire workDir, taking all fragments with it.
        // No --paths flag is used — yt-dlp resolves -o relative to its working directory.
        if isPlaylist {
            if let s = Int(playlistStart), s > 0 { args += ["--playlist-start", String(s)] }
            if let e = Int(playlistEnd),   e > 0 { args += ["--playlist-end",   String(e)] }
            if playlistReverse { args += ["--playlist-reverse"] }
            if playlistRandom  { args += ["--playlist-random"]  }
            args += ["-o", "%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s"]
        } else {
            let template = sm.outputTemplate.isEmpty ? "%(title)s.%(ext)s" : sm.outputTemplate
            args += ["-o", template]
        }

        if sm.avoidOverwrite { args += ["--no-overwrites"] }
        if sm.keepPartialFiles {
            args += ["--keep-fragments"]
        } else {
            args += ["--no-keep-fragments"]
        }

        if writeDescription { args += ["--write-description"] }
        if writeThumbnail   { args += ["--write-thumbnail"] }

        let useSponsorBlock: Bool
        if let override = sponsorBlockOverride {
            useSponsorBlock = override
        } else {
            useSponsorBlock = sm.sponsorBlock
        }
        if useSponsorBlock {

            args += ["--sponsorblock-remove", "sponsor,selfpromo,interaction"]
            args += ["--write-info-json"]

            args += ["--remux-video", "mp4"]
        }

        if sm.embedThumbnail  { args += ["--embed-thumbnail"] }
        if sm.addMetadata     { args += ["--add-metadata"] }

        if downloadSubs {
            args += ["--convert-subs", "srt"]
        }

        if !sm.ytdlpExtraArgs.trimmingCharacters(in: .whitespaces).isEmpty {
            let globalParts = sm.ytdlpExtraArgs.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            args += globalParts
        }
        if !extraArgs.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = extraArgs.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            args += parts
        }

        if sm.rateLimitKbps > 0 { args += ["--rate-limit", "\(sm.rateLimitKbps)K"] }
        if sm.retryCount > 0    { args += ["--retries", "\(sm.retryCount)"] }
        if sm.useProxy && !sm.proxyURL.isEmpty { args += ["--proxy", sm.proxyURL] }

        // Stream HLS directly into a single continuous file for all non-audio downloads.
        // This prevents yt-dlp from ever writing individual .part-Frag files to disk.
        if !audioOnlyMode && selectedVideoFormatId != "audio" && !format.isAudio {
            args += ["--hls-use-mpegts"]
        }

        // Twitch-specific optimisations
        let isTwitch = url.lowercased().contains("twitch.tv")
        if isTwitch && !audioOnlyMode && selectedVideoFormatId != "audio" && !format.isAudio {
            if useSegment {
                args += ["--remux-video", "mp4"]
            } else {
                args += ["--concurrent-fragments", "8"]
                args += ["--http-chunk-size", "10M"]
            }
        }

        args += ["--newline", "--progress-template",
                 "%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.fragment_index)s|%(progress.fragment_count)s"]
        args += [url.trimmingCharacters(in: .whitespaces)]
        return args
    }

    /// Cookie temp file URL - single source of truth, used for both writing and cleanup
    var cookieTempURL: URL? {
        guard !manualCookies.isEmpty else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("yoink_cookies_\(id.uuidString).txt")
    }
}
