import SwiftUI
import AppKit

// MARK: - Cached thumbnail view (uses global ThumbnailCache)

struct CachedThumb: View {
    let urlString: String
    let width: CGFloat; let height: CGFloat
    let radius: CGFloat
    let placeholder: AnyView

    @ObservedObject private var cache = ThumbnailCache.shared

    var body: some View {
        Group {
            if let img = cache.image(for: urlString) {
                Image(nsImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            } else {
                placeholder
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            }
        }
        .onAppear { ThumbnailCache.shared.load(urlString) }
        .onChange(of: urlString) { ThumbnailCache.shared.load($0) }
    }
}

// MARK: - Menu Bar Popover

struct MenuBarView: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager
    @ObservedObject private var clipboard = ClipboardMonitor.shared

    // Tick every second so header progress stays live (individual job @Published
    // changes don't propagate up through queue's @Published jobs array)
    @State private var tick = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Single-video state
    @State private var newURL             = ""
    @State private var format             : DownloadFormat = .best
    @State private var selectedVideoFmtId : String = ""   // empty = best
    @State private var selectedAudioFmtId : String = ""   // empty = best
    @State private var audioOnly          = false   // NEW: quick audio-only toggle
    @State private var downloadSubs       = false
    @State private var subLang            = "en"
    @State private var removeSponsor      = false

    @State private var pendingJob         : DownloadJob? = nil
    @State private var startH = ""; @State private var startM = ""; @State private var startS = ""
    @State private var endH   = ""; @State private var endM   = ""; @State private var endS   = ""

    // NEW: Duplicate detection - set when pasted URL is found in history
    @FocusState private var urlFieldFocused: Bool
    @State private var duplicateEntry    : HistoryEntry? = nil
    // NEW: Batch import state
    @State private var showBatchDropZone = false
    @State private var batchImportCount  = 0
    @State private var showBatchConfirm  = false

    // Playlist state
    @State private var playlistItems : [PlaylistItem] = []
    @State private var playlistURL   = ""
    @State private var playlistFetch : PlFetchState = .idle
    @State private var playlistError = ""

    // Inline playlist-choice banner
    @State private var showPlaylistBanner  = false
    @State private var detectedPlaylistURL = ""
    @State private var urlDebounceTask     : Task<Void, Never>? = nil
    @AppStorage("menuBarShowRecents") private var showRecents: Bool = true

    enum PlFetchState { case idle, fetching, ready, error }

    var isPlaylistMode: Bool { playlistFetch != .idle }
    var selectedItems: [PlaylistItem] { playlistItems.filter(\.selected) }
    var activeJobs: [DownloadJob] { queue.jobs.filter { $0.hasURL } }

    // MARK: - Theme colours

    // The popover window has its own surface - we can't rely on SwiftUI's adaptive colours.
    // Compute everything explicitly so every theme looks perfect.
    var isDark: Bool {
        switch theme.current {
        case .system:   return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        default:        return theme.current.colorScheme == .dark
        }
    }

    var fg: Color       { isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.85) }
    var fgSec: Color    { fg.opacity(0.50) }
    var fgTer: Color    { fg.opacity(0.28) }
    var surfaceBg: Color {
        // Solid background tinted per-theme
        switch theme.current {
        case .system:   return isDark ? Color(white: 0.15) : Color(white: 0.97)
        case .midnight: return Color(red: 0.08, green: 0.09, blue: 0.15)
        case .dawn:     return Color(red: 0.99, green: 0.96, blue: 0.88)
        case .forest:   return Color(red: 0.86, green: 0.97, blue: 0.88)
        case .ocean:    return Color(red: 0.04, green: 0.12, blue: 0.19)
        case .monoDark:  return Color(red: 0.07, green: 0.07, blue: 0.07)
        case .slate:    return Color(red: 0.14, green: 0.11, blue: 0.20)
        case .monoLight: return Color(red: 0.94, green: 0.94, blue: 0.94)
        }
    }
    var rowBg: Color    { fg.opacity(0.04) }
    var rowBorder: Color { fg.opacity(0.10) }
    var accent: Color   { theme.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider().foregroundStyle(fg.opacity(0.12))

            if isPlaylistMode {
                playlistSection
            } else {
                singleVideoSection
                Divider().foregroundStyle(fg.opacity(0.08))
                jobsSection
                Divider().foregroundStyle(fg.opacity(0.06))
                footerSection
            }
        }
        .frame(width: 430)
        .background(
            ZStack {
                VisualEffectBlur(material: .popover)
                surfaceBg.opacity(isDark ? 0.55 : 0.45)
            }
        )
        .foregroundStyle(fg)
        .accentColor(accent)
        .onReceive(timer) { _ in tick += 1 }
        // Auto-focus the URL field as soon as the popover appears
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { urlFieldFocused = true } }
        // Escape key closes the popover (macOS 13 compatible via NSEvent)
        .background(EscapeKeyHandler { NSApp.keyWindow?.close() })
        .onReceive(NotificationCenter.default.publisher(for: .dropURLOnMenuBar)) { notif in
            guard let urlString = notif.object as? String else { return }
            withAnimation(.spring(response: 0.25)) {
                newURL = urlString
                handleURLChange(urlString)
            }
        }
        // Batch TXT file drop on the whole popover
        .onDrop(of: [.fileURL, .plainText], isTargeted: $showBatchDropZone) { providers in
            handleBatchDrop(providers: providers)
        }
        .overlay(
            // Batch drop target highlight
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(accent.opacity(showBatchDropZone ? 0.8 : 0), lineWidth: 2)
                .animation(.easeInOut(duration: 0.15), value: showBatchDropZone)
        )
    }   // end var body

    // MARK: - Header

    var headerSection: some View {
        HStack(spacing: 10) {
            MenuBarMiniRing(queue: queue, accent: accent, tick: tick)

            VStack(alignment: .leading, spacing: 1) {
                Text("Yoink")
                    .font(.system(size: 15, weight: .heavy, design: .serif))
                    .tracking(0.8)
                    .foregroundStyle(fg)
                Text(headerSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(fgSec)
                    .animation(.spring(response: 0.3), value: headerSubtitle)
            }
            Spacer()
            HStack(spacing: 6) {
                DepDot(label: "yt-dlp", status: deps.ytdlp, fg: fg)
                DepDot(label: "ffmpeg", status: deps.ffmpeg, fg: fg)
            }
            Button { openMainWindow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow").font(.system(size: 10, weight: .semibold))
                    Text("Open App").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(accent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(surfaceBg.opacity(0.3))
    }

    // MARK: - Single-video section

    var singleVideoSection: some View {
        VStack(spacing: 8) {

            // ── URL field + download button ──────────────────────────────
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: siteIcon(newURL))
                        .font(.system(size: 12)).foregroundStyle(accent.opacity(0.85))
                        .frame(width: 16)
                    TextField("Paste URL - YouTube, Twitch, Vimeo…", text: $newURL)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(fg)
                        .focused($urlFieldFocused)
                        .onChange(of: newURL) { handleURLChange($0) }
                        .onSubmit { 
                            if showPlaylistBanner {
                                showPlaylistBanner = false
                                let clean = DownloadJob.stripPlaylistParams(from: newURL)
                                newURL = clean
                            }
                            commitDownload()
                        }
                    if !newURL.isEmpty {
                        Button { clearAll() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(fgSec)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(fg.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(rowBorder, lineWidth: 0.5))

                Button { 
                    if showPlaylistBanner {
                        showPlaylistBanner = false
                        let clean = DownloadJob.stripPlaylistParams(from: newURL)
                        newURL = clean
                    }
                    commitDownload()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(newURL.hasPrefix("http") ? accent : fgTer)
                }
                .buttonStyle(.plain)
                .disabled(!newURL.hasPrefix("http"))
            }

            // ── Duplicate detection warning (FIX #6) ────────────────────
            if let dupe = duplicateEntry {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green.opacity(0.85))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Already downloaded")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(fg)
                        Text(dupe.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(fgSec)
                    }
                    Spacer()
                    if FileManager.default.fileExists(atPath: dupe.outputPath) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: dupe.outputPath)])
                        } label: {
                            Text("Show file").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(accent.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.green.opacity(0.20), lineWidth: 0.5))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Playlist detection banner ────────────────────────────────
            if showPlaylistBanner {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.fill")
                            .font(.system(size: 14)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Playlist detected")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(fg)
                            Text("Download just this video, or the full playlist?")
                                .font(.system(size: 11)).foregroundStyle(fgSec)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button {
                            showPlaylistBanner = false
                            let clean = DownloadJob.stripPlaylistParams(from: detectedPlaylistURL)
                            newURL = clean; startPreview(url: clean)
                        } label: {
                            Text("This video only")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(fg)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(fg.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)

                        Button {
                            showPlaylistBanner = false
                            playlistURL = detectedPlaylistURL; newURL = ""
                            fetchPlaylist(url: detectedPlaylistURL)
                        } label: {
                            Text("Full playlist")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(accent.opacity(0.22), lineWidth: 0.5))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Auth banner ──────────────────────────────────────────────
            if pendingJob?.metaState == .needsAuth || pendingJob?.metaState == .needsAuthRetry {
                let cookiesFailed = pendingJob?.metaState == .needsAuthRetry
                HStack(spacing: 8) {
                    Image(systemName: cookiesFailed ? "lock.trianglebadge.exclamationmark.fill" : "lock.shield.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(cookiesFailed ? .red : .orange)
                    Text(cookiesFailed ? "Cookies not working" : "Needs authentication")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(fg)
                    Spacer()
                    Button { openMainWindow() } label: {
                        Text("Open in app").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(cookiesFailed ? Color.red : Color.orange).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background((cookiesFailed ? Color.red : Color.orange).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // ── Preview card ─────────────────────────────────────────────
            if let job = pendingJob, job.metaState != .needsAuth && job.metaState != .needsAuthRetry {
                MiniPreviewCard(job: job, fg: fg, fgSec: fgSec, accent: accent)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            // ── Audio-only quick toggle (Feature #4) ─────────────────────
            OptionRow(fg: fg) {
                Image(systemName: audioOnly ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 13)).foregroundStyle(audioOnly ? accent : fgSec)
                Toggle("", isOn: $audioOnly.animation()).labelsHidden().toggleStyle(SlimToggleStyle())
                    .onChange(of: audioOnly) { on in
                        if on {
                            // Lock format to audio-only, clear video selection
                            selectedVideoFmtId = "audio"
                            selectedAudioFmtId = ""
                        } else {
                            selectedVideoFmtId = ""
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Audio only").font(.system(size: 12)).foregroundStyle(audioOnly ? fg : fgSec)
                    if audioOnly {
                        Text("Saves as MP3").font(.system(size: 9.5)).foregroundStyle(fgTer)
                    }
                }
                Spacer()
                if audioOnly {
                    Text("MP3").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accent.opacity(0.12)).clipShape(Capsule())
                }
            }

            // ── Format ───────────────────────────────────────────────────
            let videoFmts = pendingJob?.meta?.videoFormats ?? []
            let audioFmts = pendingJob?.meta?.audioFormats ?? []

            if !videoFmts.isEmpty {
                // VIDEO track picker
                OptionRow(fg: fg) {
                    Text("VIDEO").font(.system(size: 9, weight: .bold)).foregroundStyle(fgTer)
                        .frame(width: 38, alignment: .leading)
                    Menu {
                        Button { selectedVideoFmtId = "" } label: {
                            HStack {
                                Text("Best available")
                                if selectedVideoFmtId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(videoFmts) { fmt in
                            Button { selectedVideoFmtId = fmt.id } label: {
                                HStack {
                                    Text(fmt.label)
                                    if selectedVideoFmtId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                        }
                        Divider()
                        Button { selectedVideoFmtId = "audio" } label: {
                            HStack {
                                Text("Audio only")
                                if selectedVideoFmtId == "audio" { Spacer(); Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if selectedVideoFmtId == "audio" {
                                Text("Audio only").font(.system(size: 11, weight: .medium))
                            } else if selectedVideoFmtId.isEmpty {
                                Text("Best").font(.system(size: 11, weight: .medium))
                                if let best = videoFmts.first, let h = best.height {
                                    Text("(\(h)p)").font(.system(size: 10)).foregroundStyle(fgSec)
                                    if let fs = best.filesize {
                                        Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                            .font(.system(size: 9.5)).foregroundStyle(fgTer)
                                    }
                                }
                            } else if let fmt = videoFmts.first(where: { $0.id == selectedVideoFmtId }) {
                                Text(fmt.height.map { "\($0)p" } ?? fmt.id).font(.system(size: 11, weight: .medium))
                                Text("· \(fmt.ext.uppercased())").font(.system(size: 10)).foregroundStyle(fgSec)
                                if let fs = fmt.filesize {
                                    Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                        .font(.system(size: 9.5)).foregroundStyle(fgTer)
                                }
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                        }
                        .foregroundStyle(fg)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(fg.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(rowBorder, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }

                // AUDIO track picker (hidden in audio-only mode)
                if selectedVideoFmtId != "audio" {
                    OptionRow(fg: fg) {
                        Text("AUDIO").font(.system(size: 9, weight: .bold)).foregroundStyle(fgTer)
                            .frame(width: 38, alignment: .leading)
                        Menu {
                            Button { selectedAudioFmtId = "" } label: {
                                HStack {
                                    Text("Best available")
                                    if selectedAudioFmtId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                            Divider()
                            ForEach(audioFmts) { fmt in
                                Button { selectedAudioFmtId = fmt.id } label: {
                                    HStack {
                                        Text(fmt.label)
                                        if selectedAudioFmtId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if selectedAudioFmtId.isEmpty {
                                    Text("Best").font(.system(size: 11, weight: .medium))
                                    if let best = audioFmts.first {
                                        Text("(\(best.acodec.uppercased()))").font(.system(size: 10)).foregroundStyle(fgSec)
                                    }
                                } else if let fmt = audioFmts.first(where: { $0.id == selectedAudioFmtId }) {
                                    Text(fmt.abr.map { "\(Int($0))k" } ?? fmt.id).font(.system(size: 11, weight: .medium))
                                    Text("· \(fmt.acodec.uppercased())").font(.system(size: 10)).foregroundStyle(fgSec)
                                }
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                            }
                            .foregroundStyle(fg)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(fg.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(rowBorder, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                // Fallback: hardcoded picker while metadata loads or unsupported site
                OptionRow(fg: fg) {
                    Text("FORMAT").font(.system(size: 9, weight: .bold)).foregroundStyle(fgTer)
                    Picker("", selection: $format) {
                        ForEach(DownloadFormat.allCases) { fmt in Text(fmt.displayName).tag(fmt) }
                    }.labelsHidden().pickerStyle(.menu).accentColor(accent)
                    Spacer()
                }
            }

            // ── Subtitles ────────────────────────────────────────────────
            OptionRow(fg: fg) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 11)).foregroundStyle(downloadSubs ? accent : fgSec)
                Toggle("", isOn: $downloadSubs.animation()).labelsHidden().toggleStyle(SlimToggleStyle())
                Text("Subtitles")
                    .font(.system(size: 12)).foregroundStyle(downloadSubs ? fg : fgSec)
                if downloadSubs {
                    Spacer()
                    let langs = pendingJob?.meta?.availableSubLangs ?? []
                    if !langs.isEmpty {
                        Menu {
                            ForEach(langs, id: \.self) { lang in
                                Button {
                                    subLang = lang
                                } label: {
                                    HStack {
                                        Text(lang)
                                        if subLang == lang { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(subLang.isEmpty ? (langs.first ?? "?") : subLang)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .medium))
                            }
                            .foregroundStyle(fg)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(fg.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(rowBorder, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if subLang.isEmpty || !langs.contains(subLang),
                               let first = langs.first { subLang = first }
                        }
                    } else {
                        Text(pendingJob?.metaState == .fetching ? "detecting…" : "paste URL first")
                            .font(.system(size: 10)).foregroundStyle(fgTer)
                    }
                }
                Spacer()
            }

            // ── Clip range (always visible) ───────────────────────────────
            OptionRow(fg: fg) {
                Image(systemName: "scissors")
                    .font(.system(size: 11)).foregroundStyle(fgSec)
                Text("Clip").font(.system(size: 12, weight: .medium)).foregroundStyle(fgSec)
                Spacer()
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("START").font(.system(size: 7, weight: .bold)).foregroundStyle(fgTer)
                        MiniHMSInput(h: $startH, m: $startM, s: $startS, fg: fg)
                    }
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(fgTer)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("END").font(.system(size: 7, weight: .bold)).foregroundStyle(fgTer)
                        MiniHMSInput(h: $endH, m: $endM, s: $endS,
                                     placeholders: pendingJob?.videoDurationHMS, fg: fg)
                    }
                }
            }

            // ── SponsorBlock ─────────────────────────────────────────────
            OptionRow(fg: fg) {
                Image(systemName: "scissors.badge.ellipsis")
                    .font(.system(size: 11)).foregroundStyle(removeSponsor ? accent : fgSec)
                Toggle("", isOn: $removeSponsor.animation()).labelsHidden().toggleStyle(SlimToggleStyle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Skip sponsors")
                        .font(.system(size: 12)).foregroundStyle(removeSponsor ? fg : fgSec)
                    Text("SponsorBlock integration")
                        .font(.system(size: 9.5)).foregroundStyle(fgTer)
                }
                Spacer()
                if removeSponsor {
                    Text("ON").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(accent.opacity(0.12)).clipShape(Capsule())
                }
            }

            // ── Save to ──────────────────────────────────────────────────
            Divider().opacity(0.08).padding(.vertical, 2)
            OptionRow(fg: fg) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11)).foregroundStyle(accent.opacity(0.8))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Save to").font(.system(size: 9, weight: .medium)).foregroundStyle(fgTer)
                    Text(queue.outputDirectory.lastPathComponent)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(fg)
                        .lineLimit(1)
                }
                Spacer()
                HStack(spacing: 6) {
                    // Category quick-switcher - only shown when categories are configured
                    let cats = settings.outputCategories.filter { !$0.path.isEmpty }
                    if !cats.isEmpty {
                        Menu {
                            ForEach(cats) { cat in
                                Button {
                                    queue.outputDirectory = URL(fileURLWithPath: cat.path)
                                    Haptics.tap()
                                } label: {
                                    HStack {
                                        Text("\(cat.emoji) \(cat.name)")
                                        if URL(fileURLWithPath: cat.path) == queue.outputDirectory {
                                            Spacer(); Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button {
                                openFolderPicker(queue: queue)
                            } label: {
                                Label("Choose folder…", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            let activeCat = cats.first(where: { URL(fileURLWithPath: $0.path) == queue.outputDirectory })
                            HStack(spacing: 4) {
                                Text(activeCat.map { "\($0.emoji) \($0.name)" } ?? "Custom")
                                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                            }
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    } else {
                        // No categories configured - just a folder picker button
                        Button { openFolderPicker(queue: queue) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.badge.plus").font(.system(size: 10))
                                Text("Change").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(accent.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .help(queue.outputDirectory.path)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: pendingJob?.metaState)
    }

    // MARK: - Playlist section

    var playlistSection: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.2)) { clearAll() }
                    Haptics.tap()
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fgSec)
                        .frame(width: 28, height: 28)
                        .background(fg.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(string: playlistURL)?.host ?? "Playlist")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(fg).lineLimit(1)
                    if playlistFetch == .ready {
                        Text("\(playlistItems.count) videos · \(selectedItems.count) selected")
                            .font(.system(size: 10)).foregroundStyle(fgSec)
                    }
                }
                Spacer()
                Button {
                    settings.pendingPlaylistURL = playlistURL
                    settings.appModeRaw = AppMode.playlist.rawValue
                    openMainWindow()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 9))
                        Text("Open in app").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(fgSec)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(fg.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(fg.opacity(0.04))

            Divider().foregroundStyle(fg.opacity(0.10))

            Group {
                if playlistFetch == .fetching {
                    VStack(spacing: 12) {
                        ProgressView().tint(accent)
                        Text("Fetching playlist…").font(.system(size: 13, weight: .medium)).foregroundStyle(fgSec)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)

                } else if playlistFetch == .error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28)).foregroundStyle(.orange)
                        Text(playlistError).font(.system(size: 12)).foregroundStyle(fgSec)
                            .multilineTextAlignment(.center)
                        Button("Retry") { fetchPlaylist(url: playlistURL) }
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(accent).clipShape(Capsule()).buttonStyle(.plain)
                    }
                    .padding(20).frame(maxWidth: .infinity)

                } else if playlistFetch == .ready {
                    VStack(spacing: 0) {
                        // Select all bar
                        HStack {
                            Button {
                                let allSel = selectedItems.count == playlistItems.count
                                playlistItems.forEach { $0.selected = !allSel }
                                allSel ? Haptics.toggleOff() : Haptics.toggleOn()
                            } label: {
                                Text(selectedItems.count == playlistItems.count ? "Deselect all" : "Select all")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(accent.opacity(0.10))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                            Spacer()
                            let mbAllSponsor = !playlistItems.isEmpty && playlistItems.allSatisfy(\.sponsorBlock)
                            Button {
                                let enable = !mbAllSponsor
                                playlistItems.forEach { $0.sponsorBlock = enable }
                                enable ? Haptics.toggleOn() : Haptics.toggleOff()
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: mbAllSponsor ? "scissors.badge.ellipsis" : "scissors")
                                        .font(.system(size: 9))
                                    Text(mbAllSponsor ? "SponsorBlock: All" : "SponsorBlock")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(mbAllSponsor ? Color.purple : fgSec)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background((mbAllSponsor ? Color.purple : fg).opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)

                        Divider().foregroundStyle(fg.opacity(0.08))

                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 3) {
                                ForEach(playlistItems) { item in
                                    MiniPlaylistRow(item: item, fg: fg, fgSec: fgSec, fgTer: fgTer,
                                                   accent: accent, rowBg: rowBg, rowBorder: rowBorder)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        .frame(minHeight: 200, maxHeight: 320)

                        Divider().foregroundStyle(fg.opacity(0.08))

                        // Download bar
                        HStack(spacing: 10) {
                            Text("\(selectedItems.count) of \(playlistItems.count) selected")
                                .font(.system(size: 11)).foregroundStyle(fgSec)
                            Spacer()
                            Button { downloadSelectedPlaylistItems() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                                    Text(selectedItems.isEmpty ? "Select videos" : "Download \(selectedItems.count)")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(selectedItems.isEmpty ? fg.opacity(0.20) : accent)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain).disabled(selectedItems.isEmpty)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(fg.opacity(0.04))
                    }
                }
            }

            // Active downloads strip
            if !activeJobs.isEmpty {
                Divider().foregroundStyle(fg.opacity(0.08))
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(activeJobs) { job in
                            MiniJobRow(job: job, queue: queue, fg: fg, fgSec: fgSec, accent: accent, openMainWindow: openMainWindow)
                        }
                    }.padding(8)
                }
                .frame(maxHeight: 130)
            }
        }
    }

    // MARK: - Jobs section

    var jobsSection: some View {
        VStack(spacing: 0) {
            // Active downloads - shown only when jobs are in flight
            if activeJobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28)).foregroundStyle(fgTer)
                    Text("No active downloads")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(fgTer)
                    Text("Paste a URL above to get started")
                        .font(.system(size: 10.5)).foregroundStyle(fg.opacity(0.16))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 5) {
                        ForEach(activeJobs) { job in
                            MiniJobRow(job: job, queue: queue, fg: fg, fgSec: fgSec, accent: accent, openMainWindow: openMainWindow)
                        }
                    }.padding(8)
                }
                .frame(minHeight: 60, maxHeight: 280)
            }

            // Recent downloads - collapsible
            let recent = Array(HistoryStore.shared.entries.prefix(3))
            if !recent.isEmpty {
                Divider().opacity(0.08).padding(.horizontal, 12)
                VStack(spacing: 0) {
                    HStack {
                        Text("RECENT")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(fgTer)
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showRecents.toggle() }
                            Haptics.tap()
                        } label: {
                            Image(systemName: showRecents ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(fgTer)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                    if showRecents {
                        LazyVStack(spacing: 2) {
                            ForEach(recent) { entry in
                                MiniHistoryRow(entry: entry, fg: fg, fgSec: fgSec, fgTer: fgTer, accent: accent)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    // MARK: - Footer

    var footerSection: some View {
        VStack(spacing: 0) {
            // Monitoring fully disabled banner - only visible when the toggle is off
            if !settings.clipboardMonitor {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("Clipboard monitoring is off")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn on") {
                        settings.clipboardMonitor = true
                        Haptics.tap()
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.blue)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                Divider().foregroundStyle(fg.opacity(0.06))
            }

            // Snooze status bar - only visible when snoozed
            if let snoozeLabel = ClipboardMonitor.shared.snoozeLabel {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Text(snoozeLabel)
                        .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85))
                    Spacer()
                    Button("Clear") {
                        ClipboardMonitor.shared.clearSnooze()
                        Haptics.tap()
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.orange.opacity(0.10))
                Divider().foregroundStyle(fg.opacity(0.06))
            }

            HStack(spacing: 8) {
                if queue.jobs.contains(where: { $0.status.isTerminal }) {
                    Button { queue.clearCompleted(); Haptics.tap() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle").font(.system(size: 10))
                            Text("Clear done").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(fgSec)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(fg.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(activeJobs.count) item\(activeJobs.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(fgTer)
                Button { openMainWindow() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                        Text("Full app").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(fgSec)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(fg.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(fg.opacity(0.04))
        }
    }

    // MARK: - Logic

    var headerSubtitle: String {
        _ = tick // depend on timer tick so this recomputes every second
        let active = queue.jobs.filter { $0.status.isActive }
        guard !active.isEmpty else { return "Ready to download" }
        let pct = Int((active.map { $0.status.progress }.reduce(0,+) / Double(active.count)) * 100)
        return "\(active.count) downloading · \(pct)%"
    }

    func handleURLChange(_ url: String) {
        guard url.hasPrefix("http") else {
            urlDebounceTask?.cancel()
            pendingJob = nil; showPlaylistBanner = false
            withAnimation { duplicateEntry = nil }
            return
        }
        // Debounce: cancel previous task, wait 300ms before acting
        // This prevents spawning a process on every keystroke / mid-paste character
        urlDebounceTask?.cancel()
        urlDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let normalised = url.trimmingCharacters(in: .whitespaces)
            withAnimation(.easeInOut(duration: 0.2)) {
                duplicateEntry = HistoryStore.shared.entries.first(where: {
                    $0.url.trimmingCharacters(in: .whitespaces) == normalised
                })
            }
            if DownloadJob.looksLikePlaylist(url) {
                detectedPlaylistURL = url; showPlaylistBanner = true
                // Still start preview for the individual video
                let clean = DownloadJob.stripPlaylistParams(from: url)
                startPreview(url: clean)
            } else {
                showPlaylistBanner = false
                startPreview(url: url)
            }
        }
    }

    func openFolderPicker(queue: DownloadQueue) {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Start access, store the directory, then stop - the bookmark stored in
            // outputDirectory handles future access; we only need access for this assignment.
            let accessing = url.startAccessingSecurityScopedResource()
            queue.outputDirectory = url
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }

    func startPreview(url: String) {
        if let existing = pendingJob, existing.url == url { return }
        let job = DownloadJob(); job.url = url; job.format = format
        pendingJob = job
        DownloadService.shared.fetchMetadata(for: job)
    }

    func clearAll() {
        newURL = ""; pendingJob = nil; showPlaylistBanner = false
        startH = ""; startM = ""; startS = ""; endH = ""; endM = ""; endS = ""
        playlistItems = []; playlistFetch = .idle; playlistURL = ""; detectedPlaylistURL = ""
        selectedVideoFmtId = ""; selectedAudioFmtId = ""
        audioOnly = false
        withAnimation { duplicateEntry = nil }
    }

    func commitDownload() {
        guard newURL.hasPrefix("http") else { return }
        let job = pendingJob ?? { let j = DownloadJob(); j.url = newURL; return j }()
        // Audio-only quick toggle takes priority
        job.audioOnlyMode = audioOnly
        if audioOnly {
            job.selectedVideoFormatId = "audio"
            job.selectedAudioFormatId = ""
            job.format = .audioBest
        } else if !selectedVideoFmtId.isEmpty {
            job.selectedVideoFormatId = selectedVideoFmtId
            job.selectedAudioFormatId = selectedAudioFmtId
        } else {
            job.format = format
        }
        job.downloadSubs   = downloadSubs; job.subLang = subLang
        // FIX #6: use Bool? override - nil means "inherit global setting"
        job.sponsorBlockOverride = removeSponsor ? true : nil
        let hasClip = !startH.isEmpty || !startM.isEmpty || !startS.isEmpty ||
                      !endH.isEmpty   || !endM.isEmpty   || !endS.isEmpty
        if hasClip {
            job.useSegment = true
            job.startH = startH; job.startM = startM; job.startS = startS
            job.endH = endH;     job.endM = endM;     job.endS = endS
        }
        queue.jobs.append(job); queue.ensureOutputDir()
        DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
        Haptics.start(); clearAll()
    }

    func fetchPlaylist(url: String) {
        guard !url.isEmpty, deps.ytdlp.isReady else { return }
        playlistFetch = .fetching; playlistItems = []
        Task {
            let result = await DownloadService.shared.fetchPlaylist(url: url)
            await MainActor.run {
                switch result {
                case .success(let items):
                    playlistItems = items; playlistFetch = .ready; Haptics.success()
                    ThumbnailCache.shared.prefetch(items.compactMap { $0.thumbnail.isEmpty ? nil : $0.thumbnail })
                case .failure(let err):   playlistError = err.localizedDescription; playlistFetch = .error; Haptics.error()
                }
            }
        }
    }

    func downloadSelectedPlaylistItems() {
        guard !selectedItems.isEmpty else { return }
        queue.ensureOutputDir()
        for item in selectedItems where item.downloadStatus == .waiting {
            let job = DownloadJob()
            if playlistURL.contains("youtube.com") || playlistURL.contains("youtu.be") {
                job.url = "https://www.youtube.com/watch?v=\(item.videoID)"
            } else {
                job.url = playlistURL; job.extraArgs = "--playlist-items \(item.index)"
            }
            job.format = item.format
            switch item.segmentMode {
            case .manual:
                if !item.startH.isEmpty || !item.startM.isEmpty || !item.startS.isEmpty {
                    job.useSegment  = true
                    job.segmentMode = .manual
                    job.startH = item.startH; job.startM = item.startM; job.startS = item.startS
                    job.endH   = item.endH;   job.endM   = item.endM;   job.endS   = item.endS
                }
            case .chapters:
                if !item.selectedChapters.isEmpty {
                    job.useSegment       = true
                    job.segmentMode      = .chapters
                    job.selectedChapters = item.selectedChapters
                    if job.meta == nil {
                        let parts = item.duration.split(separator: ":").map(String.init)
                        let dH = parts.count == 3 ? parts[0] : ""
                        let dM = parts.count >= 2 ? parts[parts.count - 2] : ""
                        let dS = parts.last ?? ""
                        job.meta = VideoMeta(
                            title: item.title, thumbnail: item.thumbnail,
                            duration: item.duration,
                            durationH: dH, durationM: dM, durationS: dS,
                            hasSubs: false, chapters: item.chapters
                        )
                    }
                }
            }
            job.sponsorBlockOverride = item.sponsorBlock ? true : nil
            queue.jobs.append(job)
            DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
            item.downloadStatus = .downloading
        }
        Haptics.start()
        playlistItems.forEach { if $0.downloadStatus != .downloading { $0.selected = false } }
    }

    func siteIcon(_ url: String) -> String {
        let u = url.lowercased()
        if u.contains("youtube.com") || u.contains("youtu.be") { return "play.rectangle.fill" }
        if u.contains("twitch.tv")      { return "tv.fill" }
        if u.contains("twitter.com") || u.contains("x.com") { return "bubble.left.fill" }
        if u.contains("soundcloud.com") { return "waveform" }
        if u.contains("vimeo.com")      { return "film.fill" }
        if u.contains("instagram.com")  { return "camera.fill" }
        if u.contains("tiktok.com")     { return "music.note" }
        return "link"
    }

    func openMainWindow() {
        Haptics.tap()
        // If we're in accessory (menu-bar-only) mode, re-show dock icon first
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) {
            win.makeKeyAndOrderFront(nil)
        } else {
            // No window exists - post the standard "reopen" action to create one
            NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)), to: nil, from: nil)
        }
    }

    // MARK: - Batch TXT URL import (Feature: Batch Import)

    @discardableResult
    func handleBatchDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let fileURL = URL(dataRepresentation: data, relativeTo: nil),
                          fileURL.pathExtension.lowercased() == "txt"
                    else { return }
                    importURLsFromFile(fileURL)
                }
                return true
            }
            // Plain text dropped directly
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { str, _ in
                    guard let str = str else { return }
                    DispatchQueue.main.async { importURLsFromString(str) }
                }
                return true
            }
        }
        return false
    }

    func importURLsFromFile(_ fileURL: URL) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        DispatchQueue.main.async { importURLsFromString(content) }
    }

    func importURLsFromString(_ text: String) {
        let urls = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") && !$0.hasPrefix("#") }
            // Deduplicate
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !urls.isEmpty else { return }
        queue.ensureOutputDir()
        for url in urls {
            let job = DownloadJob()
            job.url = url
            job.format = format
            job.audioOnlyMode = audioOnly
            queue.jobs.append(job)
            DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
        }
        batchImportCount = urls.count
        Haptics.success()
    }
}  // end MenuBarView

// MARK: - Mini History Row (recent downloads in idle state)

struct MiniHistoryRow: View {
    let entry: HistoryEntry
    let fg: Color; let fgSec: Color; let fgTer: Color; let accent: Color
    @State private var hovered = false

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: entry.outputPath)
    }

    var body: some View {
        HStack(spacing: 8) {
            CachedThumb(
                urlString: entry.thumbnail,
                width: 44, height: 26, radius: 4,
                placeholder: AnyView(
                    RoundedRectangle(cornerRadius: 4).fill(fg.opacity(0.07))
                        .overlay(Image(systemName: "clock")
                            .font(.system(size: 9)).foregroundStyle(fg.opacity(0.3)))
                )
            )
            .opacity(fileExists ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? (URL(string: entry.url)?.host ?? entry.url) : entry.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fileExists ? fg : fg.opacity(0.4))
                    .lineLimit(1)
                if fileExists {
                    Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(fgTer)
                } else {
                    Text("File not found")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.red.opacity(0.7))
                }
            }
            Spacer(minLength: 0)

            if fileExists {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.outputPath)])
                } label: {
                    Image(systemName: "folder.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(hovered ? accent : fg.opacity(0.25))
                }
                .buttonStyle(.plain)
            } else {
                // File missing - show remove button on hover
                Button {
                    withAnimation { HistoryStore.shared.remove(entry) }
                    Haptics.tap()
                } label: {
                    Image(systemName: hovered ? "xmark.circle.fill" : "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(hovered ? .red : fg.opacity(0.25))
                }
                .buttonStyle(.plain)
                .help("Remove from recents")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovered ? fg.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Option Row helper

struct OptionRow<Content: View>: View {
    let fg: Color
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(fg.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(fg.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Dep Dot

struct DepDot: View {
    let label: String; let status: DepStatus; let fg: Color
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(status.dotColor).frame(width: 6)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(fg.opacity(0.45))
        }.help("\(label): \(status.statusLabel)")
    }
}

// MARK: - Mini Preview Card

struct MiniPreviewCard: View {
    @ObservedObject var job: DownloadJob
    let fg: Color; let fgSec: Color; let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            CachedThumb(
                urlString: job.meta?.thumbnail ?? "",
                width: 60, height: 34, radius: 5,
                placeholder: AnyView(
                    RoundedRectangle(cornerRadius: 5).fill(fg.opacity(0.08))
                        .overlay(Image(systemName: "photo").foregroundStyle(fg.opacity(0.25)).font(.system(size: 12)))
                )
            )

            VStack(alignment: .leading, spacing: 4) {
                if job.metaState == .fetching {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).tint(accent)
                        Text("Fetching…").font(.system(size: 11.5)).foregroundStyle(fgSec)
                    }
                } else if let meta = job.meta {
                    Text(meta.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(fg).lineLimit(2)
                    Text(meta.duration).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(fgSec)
                } else {
                    Text(URL(string: job.url)?.host ?? job.url)
                        .font(.system(size: 11.5)).foregroundStyle(fgSec).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Mini Playlist Row

struct MiniPlaylistRow: View {
    @ObservedObject var item: PlaylistItem
    let fg: Color; let fgSec: Color; let fgTer: Color
    let accent: Color; let rowBg: Color; let rowBorder: Color
    @State private var expanded = false
    @State private var hovered  = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Checkbox
                Button {
                    item.selected.toggle()
                    item.selected ? Haptics.toggleOn() : Haptics.toggleOff()
                } label: {
                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(item.selected ? accent : fg.opacity(0.22))
                        .frame(width: 34, height: 38)
                }.buttonStyle(.plain)

                // Row body
                Button {
                    withAnimation(.spring(response: 0.2)) { expanded.toggle() }
                    Haptics.tap()
                } label: {
                    HStack(spacing: 8) {
                        CachedThumb(
                            urlString: item.thumbnail,
                            width: 50, height: 28, radius: 3,
                            placeholder: AnyView(
                                RoundedRectangle(cornerRadius: 3).fill(fg.opacity(0.07))
                                    .overlay(Image(systemName: "film")
                                        .font(.system(size: 9)).foregroundStyle(fg.opacity(0.25)))
                            )
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: item.selected ? .medium : .regular))
                                .foregroundStyle(item.selected ? fg : fgSec)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if !item.duration.isEmpty {
                                HStack(spacing: 5) {
                                    Text("#\(item.index)").font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(fgTer)
                                    Text(item.duration).font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(fgTer)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(fgTer)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.vertical, 7).padding(.trailing, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .background(hovered ? fg.opacity(0.05) : Color.clear)

            // Expanded panel
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Format
                    HStack(spacing: 8) {
                        Text("FORMAT").font(.system(size: 8, weight: .bold)).foregroundStyle(fgTer)
                            .frame(width: 56, alignment: .leading)
                        Picker("", selection: $item.format) {
                            ForEach(DownloadFormat.allCases) { f in Text(f.displayName).tag(f) }
                        }.labelsHidden().pickerStyle(.menu).accentColor(accent)
                        Spacer()
                    }
                    // Clip times
                    HStack(spacing: 8) {
                        Text("CLIP").font(.system(size: 8, weight: .bold)).foregroundStyle(fgTer)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("START").font(.system(size: 7, weight: .bold)).foregroundStyle(fgTer)
                            MiniHMSInput(h: $item.startH, m: $item.startM, s: $item.startS, fg: fg)
                        }
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(fgTer)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                Text("END").font(.system(size: 7, weight: .bold)).foregroundStyle(fgTer)
                                if !item.duration.isEmpty {
                                    Text("/ \(item.duration)").font(.system(size: 7, design: .monospaced)).foregroundStyle(fgTer)
                                }
                            }
                            MiniHMSInput(h: $item.endH, m: $item.endM, s: $item.endS, fg: fg)
                        }
                        Spacer()
                    }
                    // SponsorBlock
                    HStack(spacing: 8) {
                        Text("SPONSOR").font(.system(size: 8, weight: .bold)).foregroundStyle(fgTer)
                            .frame(width: 56, alignment: .leading)
                        Toggle("", isOn: $item.sponsorBlock.animation()).labelsHidden()
                            .toggleStyle(SlimToggleStyle()).accentColor(accent)
                        Text("Skip sponsors (SponsorBlock)")
                            .font(.system(size: 11)).foregroundStyle(item.sponsorBlock ? fg : fgSec)
                        Spacer()
                    }

                    // Chapters (only when video has chapter data)
                    if !item.chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            // Mode toggle
                            HStack(spacing: 8) {
                                Text("CHAPTER").font(.system(size: 8, weight: .bold)).foregroundStyle(fgTer)
                                    .frame(width: 56, alignment: .leading)
                                HStack(spacing: 0) {
                                    ForEach([("scissors", "Start/End", DownloadJob.SegmentMode.manual),
                                             ("list.bullet", "Chapters", DownloadJob.SegmentMode.chapters)],
                                            id: \.1) { icon, label, mode in
                                        let active = item.segmentMode == mode
                                        Button {
                                            withAnimation(.easeOut(duration: 0.15)) { item.segmentMode = mode }
                                            Haptics.tap()
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: icon).font(.system(size: 8, weight: .medium))
                                                Text(label).font(.system(size: 9.5, weight: .medium))
                                            }
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(active ? accent : Color.clear)
                                            .foregroundStyle(active ? Color.white : fgSec)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .background(fg.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(rowBorder, lineWidth: 0.5))
                            }

                            if item.segmentMode == .manual {
                                // Quick-fill chapter pill buttons
                                HStack(spacing: 8) {
                                    Text("").frame(width: 56)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 4) {
                                            ForEach(item.chapters) { ch in
                                                Button {
                                                    item.startH = ch.startTime >= 3600 ? String(format: "%02d", ch.startTime/3600) : ""
                                                    item.startM = String(format: "%02d", (ch.startTime%3600)/60)
                                                    item.startS = String(format: "%02d", ch.startTime%60)
                                                    item.endH   = ch.endTime >= 3600   ? String(format: "%02d", ch.endTime/3600)   : ""
                                                    item.endM   = String(format: "%02d", (ch.endTime%3600)/60)
                                                    item.endS   = String(format: "%02d", ch.endTime%60)
                                                    Haptics.toggleOn()
                                                } label: {
                                                    HStack(spacing: 3) {
                                                        Text(ch.title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                                                        Text(ch.duration).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(fgSec)
                                                    }
                                                    .foregroundStyle(accent)
                                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                                    .background(accent.opacity(0.09))
                                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            } else {
                                // Chapter multi-select list
                                HStack(alignment: .top, spacing: 8) {
                                    Text("").frame(width: 56)
                                    VStack(alignment: .leading, spacing: 1) {
                                        ForEach(item.chapters) { ch in
                                            let sel = item.selectedChapters.contains(ch.id)
                                            Button {
                                                withAnimation(.easeOut(duration: 0.12)) {
                                                    if sel { item.selectedChapters.remove(ch.id) }
                                                    else   { item.selectedChapters.insert(ch.id) }
                                                }
                                                sel ? Haptics.toggleOff() : Haptics.toggleOn()
                                            } label: {
                                                HStack(spacing: 5) {
                                                    Image(systemName: sel ? "checkmark.square.fill" : "square")
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(sel ? accent : fg.opacity(0.25))
                                                    Text(ch.title)
                                                        .font(.system(size: 10, weight: sel ? .medium : .regular))
                                                        .foregroundStyle(sel ? fg : fgSec).lineLimit(1)
                                                    Spacer()
                                                    Text(ch.duration)
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundStyle(fgTer)
                                                }
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(sel ? accent.opacity(0.09) : Color.clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        if item.chapters.count > 1 {
                                            HStack {
                                                Spacer()
                                                let allSel = item.selectedChapters.count == item.chapters.count
                                                Button(allSel ? "Deselect all" : "Select all") {
                                                    withAnimation(.easeOut(duration: 0.12)) {
                                                        if allSel { item.selectedChapters.removeAll() }
                                                        else { item.selectedChapters = Set(item.chapters.map(\.id)) }
                                                    }
                                                    Haptics.tap()
                                                }
                                                .buttonStyle(.plain)
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(accent.opacity(0.8))
                                            }
                                        }
                                    }
                                    .padding(4)
                                    .background(fg.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 34).padding(.trailing, 10).padding(.vertical, 8)
                .background(fg.opacity(0.04))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { h in hovered = h; if h { Haptics.hover() } }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Mini Job Row

struct MiniJobRow: View {
    @ObservedObject var job: DownloadJob
    @ObservedObject var queue: DownloadQueue
    let fg: Color; let fgSec: Color; let accent: Color
    var openMainWindow: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            CachedThumb(
                urlString: job.meta?.thumbnail ?? "",
                width: 50, height: 30, radius: 4,
                placeholder: AnyView(
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(fg.opacity(0.07))
                        Circle().fill(job.status.accentColor).frame(width: 7)
                            .shadow(color: job.status.accentColor.opacity(0.5), radius: 3)
                    }
                )
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(job.meta?.title ?? (URL(string: job.url)?.host ?? job.url))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(fg).lineLimit(1)
                HStack(spacing: 5) {
                    Text(job.status.shortLabel)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(job.status.accentColor)
                    if let log = job.log.last(where: { $0.kind == .progress }) {
                        Text("·").foregroundStyle(fg.opacity(0.25))
                        Text(log.text).font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(fgSec).lineLimit(1)
                    } else if let size = job.sizeLabel {
                        Text("·").foregroundStyle(fg.opacity(0.25))
                        Text(size).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(fgSec)
                    } else if job.status == .idle, let meta = job.meta {
                        // Show estimated size next to "Ready" based on best format
                        let estSize: Int64? = {
                            if let vf = meta.videoFormats.first, let af = meta.audioFormats.first,
                               let vs = vf.filesize, let as_ = af.filesize { return vs + as_ }
                            if let vf = meta.videoFormats.first, let vs = vf.filesize { return vs }
                            if let af = meta.audioFormats.first, let as_ = af.filesize { return as_ }
                            return nil
                        }()
                        if let sz = estSize {
                            Text("·").foregroundStyle(fg.opacity(0.25))
                            Text("~\(ByteCountFormatter.string(fromByteCount: sz, countStyle: .file))")
                                .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(fgSec)
                        }
                    }
                }
            }
            Spacer(minLength: 0)

            if job.status.isActive {
                // Pause button (FIX #5)
                Button {
                    if case .downloading = job.status { job.pause() }
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(fg.opacity(hovered ? 0.6 : 0.22))
                }.buttonStyle(.plain)
                Button { job.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(fg.opacity(hovered ? 0.7 : 0.28))
                }.buttonStyle(.plain)
            } else if job.status.isPaused {
                // Resume button
                Button {
                    job.resume()
                } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 15))
                        .foregroundStyle(Color.yellow.opacity(0.9))
                }.buttonStyle(.plain)
                Button { job.cancel() } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 13))
                        .foregroundStyle(fg.opacity(0.35))
                }.buttonStyle(.plain)
            } else if case .done(let url) = job.status {
                Button {
                    // url is the exact media file - reveal it directly in Finder
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(url.deletingLastPathComponent())
                        }
                    }
                } label: {
                    Image(systemName: "folder.circle.fill").font(.system(size: 15))
                        .foregroundStyle(Color.green.opacity(0.85))
                }.buttonStyle(.plain)
            } else if job.status == .idle || job.status == .cancelled {
                // Download button for queued/ready jobs
                HStack(spacing: 4) {
                    Button {
                        let deps = DependencyService.shared
                        guard deps.ytdlp.isReady && deps.ffmpeg.isReady else { return }
                        // Need queue context - open in main app
                        openMainWindow()
                    } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 15))
                            .foregroundStyle(accent.opacity(0.85))
                    }.buttonStyle(.plain)
                    Button {
                        // Remove from queue
                        if let idx = queue.jobs.firstIndex(where: { $0.id == job.id }) {
                            queue.jobs.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 13))
                            .foregroundStyle(fg.opacity(0.35))
                    }.buttonStyle(.plain)
                }
            } else if case .failed = job.status {
                HStack(spacing: 4) {
                    Button {
                        job.reset()
                        let deps = DependencyService.shared
                        guard deps.ytdlp.isReady && deps.ffmpeg.isReady else { return }
                        DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 15))
                            .foregroundStyle(Color.red.opacity(0.75))
                    }.buttonStyle(.plain)
                    Button {
                        if let idx = queue.jobs.firstIndex(where: { $0.id == job.id }) {
                            queue.jobs.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 13))
                            .foregroundStyle(fg.opacity(0.35))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            ZStack {
                if job.status.isActive && job.status.progress > 0 {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 7).fill(accent.opacity(0.07))
                            .frame(width: geo.size.width * job.status.progress)
                            .animation(.spring(response: 0.5), value: job.status.progress)
                    }
                }
                RoundedRectangle(cornerRadius: 7).fill(hovered ? fg.opacity(0.06) : fg.opacity(0.03))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Menu Bar Ring (popover header)

struct MenuBarMiniRing: View {
    @ObservedObject var queue: DownloadQueue
    let accent: Color
    let tick: Int  // passed from parent timer so ring updates every second
    var progress: Double {
        _ = tick
        let a = queue.jobs.filter { $0.status.isActive }
        guard !a.isEmpty else { return 0 }
        return a.map { $0.status.progress }.reduce(0, +) / Double(a.count)
    }
    var hasActive: Bool {
        _ = tick
        return queue.jobs.contains { $0.status.isActive }
    }
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5).frame(width: 30)
            if hasActive {
                Circle().trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 30).rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: progress)
            }
            Image(systemName: hasActive ? "arrow.down" : "arrow.down.circle")
                .font(.system(size: hasActive ? 11 : 13, weight: .semibold))
                .foregroundStyle(hasActive ? accent : Color.secondary)
        }
    }
}

// MARK: - Menu Bar Label (macOS menu bar icon)

struct MenuBarProgressLabel: View {
    @ObservedObject var queue:    DownloadQueue
    @ObservedObject var settings: SettingsManager
    // Own 0.5s timer - the label lives outside MenuBarView's timer scope
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @State private var tick = 0

    var progress: Double {
        _ = tick  // depend on tick so SwiftUI re-evaluates every 0.5s
        let a = queue.jobs.filter { $0.status.isActive }
        guard !a.isEmpty else { return 0 }
        return a.map { $0.status.progress }.reduce(0, +) / Double(a.count)
    }
    var hasActive: Bool {
        _ = tick
        return queue.jobs.contains { $0.status.isActive }
    }
    var icon: MenuBarIcon { settings.menuBarIcon }

    // Maps 0.0–1.0 → user's custom emoji set (11 slots: 0%,10%,...,100%)
    var progressPercent: Int {
        Int(progress * 100)
    }

    var body: some View {
        ZStack {
            if icon.kind == .dynamic {
                // Dynamic numeric counter mode - shows 0–100 as download progresses
                if hasActive {
                    Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1.5).frame(width: 20)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 20).rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: progress)
                    Text("\(progressPercent)")
                        .font(.system(size: progressPercent >= 100 ? 7 : 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .animation(.spring(response: 0.25), value: progressPercent)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }

            } else if icon.kind == .customText {
                // Custom text label - shown at fixed small size, ring when active
                if hasActive {
                    Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1.5).frame(width: 20)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 20).rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: progress)
                }
                Text(icon.value)
                    .font(.system(size: icon.value.count > 2 ? 8 : 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 20)

            } else {
                // SF Symbol mode - ring + icon
                if hasActive {
                    Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1.8).frame(width: 20)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 20).rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.4), value: progress)
                }
                Image(systemName: icon.value)
                    .font(.system(size: hasActive ? 9 : 12, weight: .medium))
            }
        }
        .frame(width: 22, height: 22)
        .onReceive(timer) { _ in tick += 1 }
        // Drag a URL onto the menu bar icon → auto-detect and open popover
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        DispatchQueue.main.async {
                            handleDroppedURL(url.absoluteString)
                        }
                    }
                    return true
                }
                if provider.canLoadObject(ofClass: String.self) {
                    _ = provider.loadObject(ofClass: String.self) { str, _ in
                        guard let str = str, str.hasPrefix("http") else { return }
                        DispatchQueue.main.async {
                            handleDroppedURL(str)
                        }
                    }
                    return true
                }
            }
            return false
        }
    }

    func handleDroppedURL(_ urlString: String) {
        Haptics.success()
        // Post notification so MenuBarView picks it up and starts fetching
        NotificationCenter.default.post(name: .dropURLOnMenuBar, object: urlString)
    }
}

// MARK: - Mini HMS Input

struct MiniHMSInput: View {
    @Binding var h: String; @Binding var m: String; @Binding var s: String
    var placeholders: (h: String, m: String, s: String)? = nil
    var fg: Color = .primary
    var body: some View {
        HStack(spacing: 1) {
            MiniTimeBox(text: $h, placeholder: placeholders?.h ?? "00", maxVal: 99, fg: fg)
            Text(":").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(fg.opacity(0.4))
            MiniTimeBox(text: $m, placeholder: placeholders?.m ?? "00", maxVal: 59, fg: fg)
            Text(":").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(fg.opacity(0.4))
            MiniTimeBox(text: $s, placeholder: placeholders?.s ?? "00", maxVal: 59, fg: fg)
        }
    }
}

struct MiniTimeBox: View {
    @Binding var text: String; let placeholder: String; let maxVal: Int
    var fg: Color = .primary
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .multilineTextAlignment(.center)
            .frame(width: 26, height: 22)
            .background(focused ? Color.accentColor.opacity(0.12) : fg.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? Color.accentColor.opacity(0.5) : fg.opacity(0.18), lineWidth: 0.5))
            .focused($focused)
            .onChange(of: text) { v in
                let d = String(v.filter(\.isNumber).prefix(2))
                if let n = Int(d), n > maxVal { text = String(maxVal) } else { text = d }
            }
            .background(ScrollWheelReceiver { delta in
                let cur = Int(text) ?? 0
                let next = min(maxVal, max(0, cur + (delta > 0 ? 1 : -1)))
                if next != cur { text = String(format: "%02d", next); Haptics.tick() }
            })
    }
}

// MARK: - Escape Key Handler (macOS 13 compatible)

/// Installs a local NSEvent monitor for the Escape key so the popover can be
/// dismissed without requiring macOS 14's .onKeyPress modifier.
private struct EscapeKeyHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                self.onEscape()
                return nil
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var monitor: Any?
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
