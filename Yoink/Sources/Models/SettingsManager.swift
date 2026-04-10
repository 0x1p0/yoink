import SwiftUI
import Foundation

// MARK: - Output Category (save-location presets per content type)

struct OutputCategory: Identifiable, Codable, Hashable {
    var id      : UUID   = UUID()
    var name    : String        // e.g. "Educational", "Music", "Misc"
    var emoji   : String        // e.g. "🎓"
    var path    : String        // absolute path to folder

    static let defaults: [OutputCategory] = [
        OutputCategory(name: "Educational", emoji: "🎓", path: ""),
        OutputCategory(name: "Music",       emoji: "🎵", path: ""),
        OutputCategory(name: "Misc",        emoji: "📦", path: ""),
    ]
}

// MARK: - Menu Bar Icon Options

struct MenuBarIcon: Identifiable, Hashable {
    let id   : String
    let label: String
    let value: String
    let kind : IconKind

    enum IconKind { case emoji, sfSymbol, dynamic, customText }

    static let presets: [MenuBarIcon] = [
        .init(id:"arrow.down", label:"Arrow Down",   value:"arrow.down.circle",       kind:.sfSymbol),
        .init(id:"tray",       label:"Tray",         value:"tray.and.arrow.down",      kind:.sfSymbol),
        .init(id:"film",       label:"Film",         value:"film",                     kind:.sfSymbol),
        .init(id:"waveform",   label:"Waveform",     value:"waveform",                 kind:.sfSymbol),
        .init(id:"bolt",       label:"Bolt",         value:"bolt.fill",                kind:.sfSymbol),
        .init(id:"cloud.dl",   label:"Cloud DL",     value:"icloud.and.arrow.down",    kind:.sfSymbol),
        .init(id:"__dynamic",  label:"% Counter",    value:"0",                        kind:.dynamic),
    ]
}

// MARK: - Process Priority / QoS

enum ProcessQoS: String, CaseIterable, Identifiable {
    case background = "background"
    case utility    = "utility"
    case normal     = "normal"
    case high       = "high"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .background: return "Low - cooler, efficiency cores"
        case .utility:    return "Balanced - recommended"
        case .normal:     return "Normal - faster, more heat"
        case .high:       return "High - max speed, most heat"
        }
    }
    var qualityOfService: QualityOfService {
        switch self {
        case .background: return .background
        case .utility:    return .utility
        case .normal:     return .default
        case .high:       return .userInitiated
        }
    }
}

enum ConcurrentLimit: Int, CaseIterable, Identifiable {
    case one = 1, two = 2, three = 3, five = 5, unlimited = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .one: return "1 at a time"
        case .two: return "2 at a time"
        case .three: return "3 at a time"
        case .five: return "5 at a time"
        case .unlimited: return "Unlimited"
        }
    }
}

// MARK: - Post-Download Conversion

enum PostConvertAction: String, CaseIterable, Identifiable {
    case none    = "none"
    case hevc    = "hevc"      // re-encode video to H.265/HEVC
    case mp3     = "mp3"       // extract audio as MP3
    case m4a     = "m4a"       // extract audio as M4A (AAC)
    case compressAudio = "compressAudio"  // compress audio to 128kbps AAC

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:          return "No conversion"
        case .hevc:          return "Re-encode to H.265 (HEVC)"
        case .mp3:           return "Extract audio → MP3"
        case .m4a:           return "Extract audio → M4A"
        case .compressAudio: return "Compress audio (128kbps)"
        }
    }
    var icon: String {
        switch self {
        case .none:          return "minus.circle"
        case .hevc:          return "film.stack"
        case .mp3:           return "music.note"
        case .m4a:           return "waveform"
        case .compressAudio: return "arrow.down.square"
        }
    }
    func ffmpegArgs(inputExt: String) -> [String]? {
        switch self {
        case .none: return nil
        case .hevc:
            return ["-c:v", "libx265", "-crf", "28", "-preset", "medium",
                    "-c:a", "copy", "-tag:v", "hvc1"]
        case .mp3:
            return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a:
            return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .compressAudio:
            return ["-vn", "-c:a", "aac", "-b:a", "128k"]
        }
    }
    func outputExt(inputExt: String) -> String {
        switch self {
        case .none:          return inputExt
        case .hevc:          return inputExt == "mkv" ? "mkv" : "mp4"
        case .mp3:           return "mp3"
        case .m4a:           return "m4a"
        case .compressAudio: return "m4a"
        }
    }
}

// MARK: - Post-Download Action

enum PostDownloadAction: String, CaseIterable, Identifiable {
    case nothing    = "nothing"
    case reveal     = "reveal"
    case notify     = "notify"
    case openFolder = "openFolder"
    case openFile   = "openFile"      // FIX #3: open file in default app
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nothing:    return "Do nothing"
        case .reveal:     return "Reveal file in Finder"
        case .notify:     return "Send notification"
        case .openFolder: return "Open download folder"
        case .openFile:   return "Open file in default app"
        }
    }
    var icon: String {
        switch self {
        case .nothing:    return "minus.circle"
        case .reveal:     return "doc.viewfinder"
        case .notify:     return "bell.badge"
        case .openFolder: return "folder.badge.gearshape"
        case .openFile:   return "play.rectangle"
        }
    }
}

// MARK: - App Mode

enum AppMode: String, CaseIterable, Identifiable {
    case video      = "Video"
    case playlist   = "Playlist + Advanced"
    case watchLater = "Watch Later"
    case history    = "History"
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .video:      return "Video"
        case .playlist:   return "Playlist"
        case .watchLater: return "Watch Later"
        case .history:    return "History"
        }
    }
}

// MARK: - Playlist Download Status

enum PlaylistDownloadStatus {
    case waiting, downloading, done, failed, skipped
    var color: Color {
        switch self {
        case .waiting:     return .secondary
        case .downloading: return .accentColor
        case .done:        return .green
        case .failed:      return .red
        case .skipped:     return .secondary.opacity(0.4)
        }
    }
    var icon: String {
        switch self {
        case .waiting:     return "circle"
        case .downloading: return "arrow.down.circle"
        case .done:        return "checkmark.circle.fill"
        case .failed:      return "xmark.circle.fill"
        case .skipped:     return "minus.circle"
        }
    }
}

// MARK: - Playlist Item (Advanced mode)

final class PlaylistItem: ObservableObject, Identifiable, @unchecked Sendable {
    let id        = UUID()
    let index     : Int
    let videoID   : String
    let title     : String
    let duration  : String  // raw HH:MM:SS
    @Published var selected  : Bool   = true
    @Published var startH    : String = ""
    @Published var startM    : String = ""
    @Published var startS    : String = ""
    @Published var endH      : String
    @Published var endM      : String
    @Published var endS      : String
    @Published var format         : DownloadFormat = .best
    @Published var downloadStatus : PlaylistDownloadStatus = .waiting
    @Published var progress       : Double = 0
    @Published var chapters       : [VideoChapter] = []
    @Published var thumbnail      : String = ""
    @Published var sponsorBlock   : Bool   = false   // remove sponsors via SponsorBlock
    @Published var segmentMode    : DownloadJob.SegmentMode = .manual
    @Published var selectedChapters: Set<UUID> = []
    // Per-item quality (mirrors DownloadJob)
    @Published var selectedVideoFormatId : String = ""   // "" = best
    @Published var selectedAudioFormatId : String = ""   // "" = best
    @Published var videoFormats          : [VideoFormatInfo] = []
    @Published var audioFormats          : [AudioFormatInfo] = []
    @Published var downloadSubs          : Bool   = false
    @Published var subLang               : String = ""

    init(index: Int, videoID: String, title: String, duration: String) {
        self.index    = index
        self.videoID  = videoID
        self.title    = title
        self.duration = duration
        // duration is pre-formatted "H:MM:SS" or "" if unknown.
        // Parse into endH/endM/endS for the clip time boxes.
        // If duration is empty/unknown, leave end fields empty (shows placeholder, not 00:00:00)
        guard !duration.isEmpty else {
            endH = ""; endM = ""; endS = ""; return
        }
        let parts = duration.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            endH = String(format: "%02d", Int(parts[0]) ?? 0)
            endM = String(format: "%02d", Int(parts[1]) ?? 0)
            endS = String(format: "%02d", Int(parts[2]) ?? 0)
        case 2:
            endH = ""
            endM = String(format: "%02d", Int(parts[0]) ?? 0)
            endS = String(format: "%02d", Int(parts[1]) ?? 0)
        default:
            endH = ""; endM = ""; endS = ""
        }
    }
}

// MARK: - Settings Manager

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    private init() {}

    // Mode
    @AppStorage("appMode")            var appModeRaw:         String = AppMode.video.rawValue
    // Handoff URL for AdvancedView
    @AppStorage("pendingPlaylistURL") var pendingPlaylistURL: String = ""

    var appMode: AppMode { AppMode(rawValue: appModeRaw) ?? .video }

    // Appearance extras
    @AppStorage("useBlurBackground")   var useBlurBackground:  Bool   = true

    // Haptics
    @AppStorage("hapticsEnabled")       var hapticsEnabled:      Bool   = true
    @AppStorage("hapticIntensity")      var hapticIntensityRaw:  String = "medium"

    // Appearance
    @AppStorage("menuBarIconId")        var menuBarIconId:       String = "arrow.down"
    // Comma-separated 11-slot emoji sequence for progress (0%–100%)
    @AppStorage("progressEmojiSet")     var progressEmojiSetRaw: String = "0️⃣,1️⃣,2️⃣,3️⃣,4️⃣,5️⃣,6️⃣,7️⃣,8️⃣,9️⃣,🔟"

    var progressEmojiSet: [String] {
        let parts = progressEmojiSetRaw.split(separator: ",").map(String.init)

        guard parts.count == 11 else {
            return ["0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟"]
        }
        return parts
    }
    @AppStorage("showInDock")           var showInDock:          Bool   = true
    @AppStorage("compactCards")         var compactCards:        Bool   = false
    @AppStorage("showThumbnails")       var showThumbnails:      Bool   = false

    // Downloads
    @AppStorage("defaultFormat")        var defaultFormatRaw:    String = DownloadFormat.best.rawValue
    @AppStorage("defaultSubLang")       var defaultSubLang:      String = "en"
    @AppStorage("autoDownloadSubs")     var autoDownloadSubs:    Bool   = false
    @AppStorage("concurrentLimit")      var concurrentLimitRaw:  Int    = 3
    @AppStorage("postDownload")         var postDownloadRaw:     String = PostDownloadAction.reveal.rawValue
    @AppStorage("embedThumbnail")       var embedThumbnail:      Bool   = false
    @AppStorage("addMetadata")          var addMetadata:         Bool   = true
    @AppStorage("sponsorBlock")         var sponsorBlock:        Bool   = false

    // Output
    @AppStorage("outputTemplate")       var outputTemplate:      String = "%(title)s.%(ext)s"
    @AppStorage("outputSubDir")         var outputSubDir:        String = ""
    @AppStorage("outputCategories")     var outputCategoriesRaw: String = ""

    var outputCategories: [OutputCategory] {
        get {
            guard !outputCategoriesRaw.isEmpty,
                  let data = outputCategoriesRaw.data(using: .utf8),
                  let cats = try? JSONDecoder().decode([OutputCategory].self, from: data)
            else { return OutputCategory.defaults }
            return cats
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                outputCategoriesRaw = str
            }
        }
    }
    @AppStorage("avoidOverwrite")       var avoidOverwrite:      Bool   = true
    @AppStorage("keepPartialFiles")     var keepPartialFiles:    Bool   = false

    // Performance
    @AppStorage("ffmpegThreads")        var ffmpegThreads:       Int    = 4    // 0 = auto (all cores)
    @AppStorage("processPriority")      var processPriorityRaw:  String = "utility"

    var processPriority: ProcessQoS {
        ProcessQoS(rawValue: processPriorityRaw) ?? .utility
    }

    // Network
    @AppStorage("rateLimitKbps")        var rateLimitKbps:       Int    = 0    // 0 = unlimited
    @AppStorage("useProxy")             var useProxy:            Bool   = false
    @AppStorage("proxyURL")             var proxyURL:            String = ""
    @AppStorage("retryCount")           var retryCount:          Int    = 3

    // Advanced
    @AppStorage("ytdlpExtraArgs")       var ytdlpExtraArgs:      String = ""
    @AppStorage("checkUpdatesOnLaunch") var checkUpdatesOnLaunch:Bool   = true

    // App update
    @AppStorage("lastAppUpdateCheck")   var lastAppUpdateCheck:  Double = 0
    @AppStorage("skippedAppVersion")    var skippedAppVersion:   String = ""

    // Clipboard monitor - on by default
    @AppStorage("clipboardMonitor")     var clipboardMonitor:    Bool   = true

    // "Download Now" notification action presets
    @AppStorage("notifSponsorBlock")    var notifSponsorBlock:   Bool   = false
    @AppStorage("notifSubtitles")       var notifSubtitles:      Bool   = false

    // Custom domains for clipboard monitor - comma-separated, empty = use defaults
    @AppStorage("clipboardDomainsRaw")  var clipboardDomainsRaw: String = ""

    static let defaultClipboardDomains: [String] = [
        "youtube.com", "youtu.be", "twitch.tv", "twitter.com", "x.com",
        "instagram.com", "tiktok.com", "vimeo.com", "soundcloud.com",
        "dailymotion.com", "reddit.com", "facebook.com", "bilibili.com",
        "nicovideo.jp", "rumble.com", "odysee.com", "kick.com",
        "streamable.com", "medal.tv"
    ]

    var clipboardDomains: [String] {
        get {
            let custom = clipboardDomainsRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            return custom.isEmpty ? Self.defaultClipboardDomains : custom
        }
        set { clipboardDomainsRaw = newValue.joined(separator: ",") }
    }

    @AppStorage("hasSeenTutorial")    var hasSeenTutorial:     Bool   = false

    @AppStorage("watchLaterSponsorBlock") var watchLaterSponsorBlock: Bool = false
    @AppStorage("watchLaterSubtitles")    var watchLaterSubtitles:    Bool = false
    @AppStorage("autoOrganizeBySite")   var autoOrganizeBySite:  Bool   = false

    // Shortcuts integration - fire a shortcut by name on download complete
    @AppStorage("shortcutOnComplete")   var shortcutOnComplete:  String = ""  // empty = disabled

    // Post-download conversion using bundled ffmpeg
    @AppStorage("postConvert")          var postConvertRaw:      String = PostConvertAction.none.rawValue

    var postConvert: PostConvertAction {
        PostConvertAction(rawValue: postConvertRaw) ?? .none
    }

    // Per-site default format overrides - JSON dict: { "youtube.com": "mp4_1080", ... }
    @AppStorage("siteFormatOverrides")  var siteFormatOverridesRaw: String = ""

    var siteFormatOverrides: [String: String] {
        get {
            guard !siteFormatOverridesRaw.isEmpty,
                  let data = siteFormatOverridesRaw.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                siteFormatOverridesRaw = str
            }
        }
    }

    /// Returns the best matching per-site DownloadFormat for a URL, or nil if none is configured.
    func siteFormat(for url: String) -> DownloadFormat? {
        let lower = url.lowercased()
        for (domain, formatRaw) in siteFormatOverrides {
            if lower.contains(domain) { return DownloadFormat(rawValue: formatRaw) }
        }
        return nil
    }

    // Queue-complete notification - fires once when all jobs finish, not per-file
    @AppStorage("notifyOnQueueComplete") var notifyOnQueueComplete: Bool = false

    var menuBarIcon: MenuBarIcon {
        if menuBarIconId == "__dynamic" {
            return MenuBarIcon.presets.first { $0.kind == .dynamic }!
        }
        if menuBarIconId.hasPrefix("custom_") {
            let emoji = String(menuBarIconId.dropFirst(7))
            return MenuBarIcon(id: menuBarIconId, label: "Custom", value: emoji, kind: .emoji)
        }
        if menuBarIconId.hasPrefix("text_") {
            let text = String(menuBarIconId.dropFirst(5))
            return MenuBarIcon(id: menuBarIconId, label: "Text", value: text, kind: .customText)
        }
        return MenuBarIcon.presets.first { $0.id == menuBarIconId } ?? MenuBarIcon.presets[0]
    }
    var defaultFormat: DownloadFormat {
        DownloadFormat(rawValue: defaultFormatRaw) ?? .best
    }
    var concurrentLimit: ConcurrentLimit {
        ConcurrentLimit(rawValue: concurrentLimitRaw) ?? .three
    }
    var postDownload: PostDownloadAction {
        PostDownloadAction(rawValue: postDownloadRaw) ?? .reveal
    }
}
