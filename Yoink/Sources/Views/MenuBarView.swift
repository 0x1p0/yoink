import SwiftUI
import Combine
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

// MARK: - Menu bar draft (options for the link being composed)

/// Holds the choices for the link currently typed into the popover. Kept in one
/// observable object so the preview card re-renders as soon as anything changes.
@MainActor
final class MenuDraft: ObservableObject {
    @Published var audioOnly      = false
    @Published var videoFmtId     = ""                // "" = best available
    @Published var fallbackFormat : DownloadFormat = .best
    @Published var downloadSubs   = false
    @Published var subLang        = ""
    @Published var removeSponsor  = false
    @Published var clipOn         = false
    @Published var showOptions    = false
    @Published var startH = ""; @Published var startM = ""; @Published var startS = ""
    @Published var endH   = ""; @Published var endM   = ""; @Published var endS   = ""

    init() { reset() }

    /// Back to the user's defaults from Settings.
    func reset() {
        let sm = SettingsManager.shared
        let def = sm.defaultFormat
        audioOnly      = def.isAudio
        videoFmtId     = ""
        fallbackFormat = def.isAudio ? .best : def
        downloadSubs   = sm.autoDownloadSubs
        subLang        = ""
        removeSponsor  = sm.sponsorBlock
        clipOn         = false
        showOptions    = false
        startH = ""; startM = ""; startS = ""
        endH   = ""; endM   = ""; endS   = ""
    }

    var hasClipTimes: Bool {
        !startH.isEmpty || !startM.isEmpty || !startS.isEmpty ||
        !endH.isEmpty   || !endM.isEmpty   || !endS.isEmpty
    }

    /// How many of the tucked-away options are switched on (shown as a badge).
    var activeOptionCount: Int {
        [downloadSubs, removeSponsor, clipOn].filter { $0 }.count
    }
}

// MARK: - Menu Bar Popover

struct MenuBarView: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @ObservedObject private var history   = HistoryStore.shared
    @StateObject private var draft = MenuDraft()

    // Tick every second so aggregate progress stays live (individual job @Published
    // changes don't propagate up through queue's @Published jobs array)
    @State private var tick = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var newURL          = ""
    @State private var pendingJob      : DownloadJob? = nil
    @State private var duplicateEntry  : HistoryEntry? = nil
    @State private var clipboardCandidate: String? = nil
    @FocusState private var urlFieldFocused: Bool

    // Batch drop + toast
    @State private var showBatchDropZone = false
    @State private var toast: String? = nil

    // Playlist state
    @State private var playlistItems : [PlaylistItem] = []
    @State private var playlistURL   = ""
    @State private var playlistFetch : PlFetchState = .idle
    @State private var playlistError = ""
    @State private var playlistTick  = 0

    // Inline playlist-choice banner
    @State private var showPlaylistBanner  = false
    @State private var detectedPlaylistURL = ""
    @State private var urlDebounceTask     : Task<Void, Never>? = nil

    enum PlFetchState { case idle, fetching, ready, error }

    var isPlaylistMode: Bool { playlistFetch != .idle }
    var selectedItems: [PlaylistItem] { _ = playlistTick; return playlistItems.filter(\.selected) }
    var activeJobs: [DownloadJob] { _ = tick; return queue.jobs.filter { $0.hasURL } }
    var canSubmit: Bool { newURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http") }
    var needsAuth: Bool {
        pendingJob?.metaState == .needsAuth || pendingJob?.metaState == .needsAuthRetry
    }

    // MARK: Appearance

    // The popover window has its own surface; resolve light/dark explicitly so a
    // forced app theme is honoured even though the menu bar follows the system.
    var isDark: Bool {
        if let forced = theme.current.colorScheme { return forced == .dark }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    var accent: Color { theme.accentColor }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            if isPlaylistMode {
                playlistSection
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    composer
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                    if deps.enginesFailed {
                        engineNotice
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                    }

                    downloadsSection
                    hairline
                    footer
                }
                .transition(.opacity)
            }
        }
        .frame(width: 380)
        .background {
            ZStack {
                VisualEffectBlur(material: isDark ? .hudWindow : .popover)
                (isDark ? Color(white: 0.12).opacity(0.86) : Color.white.opacity(0.96))
            }
        }
        .environment(\.colorScheme, isDark ? .dark : .light)
        .tint(accent)
        .overlay { dropOverlay }
        .overlay(alignment: .bottom) { toastView }
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: layoutKey)
        .onReceive(timer) { _ in tick += 1 }
        .onAppear {
            refreshClipboardCandidate()
            DispatchQueue.main.async { urlFieldFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshClipboardCandidate()
        }
        // Escape closes the popover (only the popover — never the main window)
        .background(EscapeKeyHandler { window in window.close() })
        .onReceive(NotificationCenter.default.publisher(for: .dropURLOnMenuBar)) { notif in
            guard let urlString = notif.object as? String else { return }
            newURL = urlString
            handleURLChange(urlString)
        }
        // Batch drop: a .txt file of links, or a block of text, anywhere on the popover
        .onDrop(of: [.fileURL, .plainText], isTargeted: $showBatchDropZone) { providers in
            handleBatchDrop(providers: providers)
        }
    }

    /// Everything that changes the popover's height — animate those together.
    private var layoutKey: [String] {
        [
            "\(isPlaylistMode)", "\(playlistFetch)", "\(showPlaylistBanner)",
            "\(pendingJob?.id.uuidString ?? "")", "\(pendingJob?.metaState == .fetching)",
            "\(draft.showOptions)", "\(draft.clipOn)", "\(draft.downloadSubs)", "\(draft.audioOnly)",
            "\(duplicateEntry?.id.uuidString ?? "")", "\(activeJobs.count)", "\(needsAuth)",
        ]
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(isDark ? 0.10 : 0.08)).frame(height: 0.5)
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 10) {
            headerGlyph

            VStack(alignment: .leading, spacing: 1) {
                Text("Yoink")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            QuietIconButton(systemImage: "macwindow", help: "Open Yoink Window") { openMainWindow() }
            moreMenu
        }
        .padding(.leading, 14).padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private var headerGlyph: some View {
        let active = hasActiveJobs
        return ZStack {
            Circle()
                .fill(accent.opacity(0.13))
            if active {
                Circle()
                    .trim(from: 0, to: max(0.02, activeProgress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(1.2)
                    .animation(.linear(duration: 0.45), value: activeProgress)
            }
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var moreMenu: some View {
        Menu {
            Toggle("Watch Clipboard for Links", isOn: Binding(
                get: { settings.clipboardMonitor },
                set: { on in
                    settings.clipboardMonitor = on
                    if on { clipboard.start() } else { clipboard.stop() }
                }
            ))
            if clipboard.snoozeLabel != nil {
                Button("Resume Clipboard Watching") { clipboard.clearSnooze() }
            } else if settings.clipboardMonitor {
                Menu("Snooze Clipboard Watching") {
                    Button("For 5 Minutes")  { clipboard.snooze(.fiveMinutes) }
                    Button("For 30 Minutes") { clipboard.snooze(.thirtyMinutes) }
                    Button("Until Tomorrow") { clipboard.snooze(.untilTomorrow) }
                }
            }
            Divider()
            Button("Import Links from File…") { importFromFilePanel() }
            Button("Show Download History") {
                settings.appModeRaw = AppMode.history.rawValue
                openMainWindow()
            }
            Divider()
            if #available(macOS 14.0, *) {
                SettingsLink { Text("Settings…") }
                    .keyboardShortcut(",", modifiers: .command)
            } else {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            Button("Quit Yoink") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .compactMenuStyle()
        .help("More")
    }

    private var hasActiveJobs: Bool {
        _ = tick
        return queue.jobs.contains { $0.status.isActive }
    }
    private var activeProgress: Double {
        _ = tick
        let a = queue.jobs.filter { $0.status.isActive }
        guard !a.isEmpty else { return 0 }
        return a.map { $0.status.progress }.reduce(0, +) / Double(a.count)
    }

    var headerSubtitle: String {
        _ = tick // recompute every second
        let active = queue.jobs.filter { $0.status.isActive }
        if !active.isEmpty {
            let pct = Int(activeProgress * 100)
            return active.count == 1 ? "Downloading · \(pct)%" : "\(active.count) downloading · \(pct)%"
        }
        let paused = queue.jobs.filter { $0.status.isPaused }.count
        if paused > 0 { return "\(paused) paused" }
        if deps.enginesFailed { return "Needs attention" }
        if !deps.enginesReady { return "Preparing engines…" }
        let waiting = queue.jobs.filter { $0.hasURL && $0.status == .idle }.count
        if waiting > 0 { return "\(waiting) waiting to start" }
        return "Ready"
    }

    // MARK: - Composer (link field + contextual preview)

    var composer: some View {
        VStack(spacing: 10) {
            urlRow

            if let dupe = duplicateEntry {
                duplicateNotice(dupe)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showPlaylistBanner {
                playlistChoice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if needsAuth {
                authNotice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let job = pendingJob {
                MenuJobSetup(job: job, draft: draft, accent: accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private var urlRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: siteIcon(newURL))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(newURL.isEmpty ? Color.secondary : accent)
                    .frame(width: 16)
                TextField("", text: $newURL, prompt: Text("Paste a video link"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($urlFieldFocused)
                    .onChange(of: newURL) { handleURLChange($0) }
                    .onSubmit { submit() }

                if newURL.isEmpty, let candidate = clipboardCandidate {
                    Button { paste(candidate) } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Paste \(candidate)")
                    .transition(.opacity)
                } else if !newURL.isEmpty {
                    Button { clearAll() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.leading, 10).padding(.trailing, 7)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isDark ? 0.07 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(urlFieldFocused ? accent.opacity(0.55) : Color.primary.opacity(0.10),
                                  lineWidth: urlFieldFocused ? 1 : 0.5)
            )
            .animation(.easeOut(duration: 0.15), value: urlFieldFocused)

            Button { submit() } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSubmit ? Color.white : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(canSubmit ? accent : Color.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Download (Return)")
            .accessibilityLabel("Download")
            .animation(.easeOut(duration: 0.15), value: canSubmit)
        }
    }

    private func duplicateNotice(_ dupe: HistoryEntry) -> some View {
        let exists = FileManager.default.fileExists(atPath: dupe.outputPath)
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text("You downloaded this \(dupe.date.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if exists {
                Button("Show File") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dupe.outputPath)])
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.08)))
    }

    private var playlistChoice: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This link is part of a playlist")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Download just this video, or choose from the playlist?")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    showPlaylistBanner = false
                    let clean = DownloadJob.stripPlaylistParams(from: detectedPlaylistURL)
                    newURL = clean; startPreview(url: clean)
                } label: {
                    Text("Just This Video")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)

                Button {
                    showPlaylistBanner = false
                    playlistURL = detectedPlaylistURL; newURL = ""
                    pendingJob = nil
                    fetchPlaylist(url: detectedPlaylistURL)
                } label: {
                    Text("Choose from Playlist…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.07)))
    }

    private var authNotice: some View {
        let cookiesFailed = pendingJob?.metaState == .needsAuthRetry
        let tint: Color = cookiesFailed ? .red : .orange
        return HStack(spacing: 9) {
            Image(systemName: cookiesFailed ? "lock.trianglebadge.exclamationmark.fill" : "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(cookiesFailed ? "Those cookies didn't work" : "This video needs you to sign in")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add browser cookies in the Yoink window to continue.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Open") {
                if let job = pendingJob, !queue.jobs.contains(where: { $0.id == job.id }) {
                    queue.jobs.append(job)
                }
                settings.appModeRaw = AppMode.video.rawValue
                clearAll()
                openMainWindow()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 24)
            .background(Capsule().fill(tint))
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.09)))
    }

    private var engineNotice: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Download engine problem")
                    .font(.system(size: 12, weight: .semibold))
                Text("yt-dlp: \(deps.ytdlp.statusLabel) · ffmpeg: \(deps.ffmpeg.statusLabel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Retry") { deps.checkAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.09)))
    }

    // MARK: - Downloads / recents / empty state

    @ViewBuilder
    var downloadsSection: some View {
        let jobs = activeJobs
        let recent = Array(history.entries.prefix(3))
        if !jobs.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    SectionTitle(title: "Downloads", count: jobs.count)
                    Spacer()
                    if jobs.contains(where: { $0.status.isTerminal }) {
                        Button("Clear Finished") {
                            queue.clearCompleted(); Haptics.tap()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                    }
                }
                .padding(.horizontal, 14)

                if jobs.count > 5 {
                    ScrollView(.vertical, showsIndicators: true) {
                        jobRows(jobs)
                    }
                    .frame(height: 290)
                } else {
                    jobRows(jobs)
                }
            }
            .padding(.top, 2).padding(.bottom, 8)
        } else if !recent.isEmpty && pendingJob == nil && !showPlaylistBanner {
            VStack(spacing: 4) {
                HStack {
                    SectionTitle(title: "Recent")
                    Spacer()
                    Button("Show All") {
                        settings.appModeRaw = AppMode.history.rawValue
                        openMainWindow()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                }
                .padding(.horizontal, 14)
                VStack(spacing: 1) {
                    ForEach(recent) { entry in
                        MiniHistoryRow(entry: entry, accent: accent)
                    }
                }
                .padding(.horizontal, 6)
            }
            .padding(.top, 2).padding(.bottom, 8)
        } else if pendingJob == nil && !showPlaylistBanner {
            emptyState
        }
    }

    private func jobRows(_ jobs: [DownloadJob]) -> some View {
        LazyVStack(spacing: 1) {
            ForEach(jobs) { job in
                MiniJobRow(job: job, queue: queue, accent: accent, openMainWindow: openMainWindow)
            }
        }
        .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("Nothing downloading")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(settings.clipboardMonitor
                 ? "Paste a link above — or just copy one anywhere and Yoink will offer it."
                 : "Paste a link above, or drop a text file of links here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    var footer: some View {
        HStack(spacing: 8) {
            SaveLocationMenu(compact: true)
            Spacer(minLength: 6)
            clipboardStatus
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var clipboardStatus: some View {
        let snoozed = clipboard.snoozeLabel
        let on = settings.clipboardMonitor
        let color: Color = snoozed != nil ? .orange : (on ? .green : Color.secondary.opacity(0.6))
        let label = snoozed != nil ? "Snoozed" : (on ? "Watching clipboard" : "Clipboard off")
        return Button {
            if snoozed != nil {
                clipboard.clearSnooze()
            } else {
                settings.clipboardMonitor.toggle()
                if settings.clipboardMonitor { clipboard.start() } else { clipboard.stop() }
            }
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(snoozed.map { "\($0) — click to resume" }
              ?? (on ? "Yoink offers links you copy. Click to turn off."
                     : "Click to have Yoink offer video links you copy."))
    }

    // MARK: - Overlays

    @ViewBuilder
    private var dropOverlay: some View {
        if showBatchDropZone {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                Label("Drop links to download", systemImage: "arrow.down.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .padding(.bottom, 52)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.3)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(.easeOut(duration: 0.25)) { if toast == text { toast = nil } }
        }
    }

    // MARK: - Playlist section

    var playlistSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                QuietIconButton(systemImage: "chevron.left", help: "Back") {
                    clearAll(); Haptics.tap()
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Playlist")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(playlistFetch == .ready
                         ? "\(playlistItems.count) videos · \(YoinkFormat.host(playlistURL))"
                         : YoinkFormat.host(playlistURL))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                QuietIconButton(systemImage: "arrow.up.forward.app", help: "Open in Yoink Window") {
                    settings.pendingPlaylistURL = playlistURL
                    settings.appModeRaw = AppMode.playlist.rawValue
                    openMainWindow()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)

            hairline

            switch playlistFetch {
            case .fetching:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading playlist…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 44)

            case .error:
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.orange)
                    Text(playlistError.isEmpty ? "Couldn't load this playlist." : playlistError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    Button("Try Again") { fetchPlaylist(url: playlistURL) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(Capsule().fill(accent))
                }
                .padding(24).frame(maxWidth: .infinity)

            case .ready:
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(playlistItems) { item in
                            MiniPlaylistRow(item: item,
                                            fg: .primary, fgSec: .secondary,
                                            fgTer: Color.secondary.opacity(0.75),
                                            accent: accent,
                                            rowBg: Color.primary.opacity(0.05),
                                            rowBorder: Color.primary.opacity(0.1),
                                            onToggle: { playlistTick += 1 })
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
                .frame(height: 320)

                hairline

                HStack(spacing: 8) {
                    let allSelected = !playlistItems.isEmpty && selectedItems.count == playlistItems.count
                    Button(allSelected ? "Select None" : "Select All") {
                        playlistItems.forEach { $0.selected = !allSelected }
                        playlistTick += 1
                        allSelected ? Haptics.toggleOff() : Haptics.toggleOn()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(accent)

                    let allSponsor = !playlistItems.isEmpty && playlistItems.allSatisfy(\.sponsorBlock)
                    OptionChip(title: "Skip Sponsors", icon: "forward.end", isOn: allSponsor,
                               help: "Remove sponsor segments from every video (SponsorBlock)") {
                        playlistItems.forEach { $0.sponsorBlock = !allSponsor }
                        playlistTick += 1
                    }

                    Spacer()

                    Button { downloadSelectedPlaylistItems() } label: {
                        Text(selectedItems.isEmpty ? "Download" : "Download \(selectedItems.count)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(selectedItems.isEmpty ? Color.secondary : .white)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedItems.isEmpty ? Color.primary.opacity(0.08) : accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedItems.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)

            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: - Logic

    func refreshClipboardCandidate() {
        let pb = NSPasteboard.general
        guard let raw = (pb.string(forType: .string) ?? pb.string(forType: .URL))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.contains("\n"),
              raw.lowercased().hasPrefix("http"),
              raw.count < 2048,
              !queue.jobs.contains(where: { $0.url == raw })
        else { clipboardCandidate = nil; return }
        clipboardCandidate = raw
    }

    func paste(_ url: String) {
        newURL = url
        clipboardCandidate = nil
        urlFieldFocused = true
    }

    func submit() {
        guard canSubmit else { return }
        if showPlaylistBanner {
            showPlaylistBanner = false
            newURL = DownloadJob.stripPlaylistParams(from: newURL)
        }
        commitDownload()
    }

    func handleURLChange(_ url: String) {
        guard url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http") else {
            urlDebounceTask?.cancel()
            pendingJob = nil; showPlaylistBanner = false
            duplicateEntry = nil
            return
        }
        // Debounce: wait 300ms so we don't spawn a process on every keystroke / mid-paste
        urlDebounceTask?.cancel()
        urlDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            let normalised = url.trimmingCharacters(in: .whitespaces)
            duplicateEntry = HistoryStore.shared.existingEntry(for: normalised)
            if DownloadJob.looksLikePlaylist(url) && !DownloadService.isSoopOrAfreecaURL(url) {
                detectedPlaylistURL = url; showPlaylistBanner = true
                // Still preview the individual video
                startPreview(url: DownloadJob.stripPlaylistParams(from: url))
            } else {
                showPlaylistBanner = false
                startPreview(url: normalised)
            }
        }
    }

    func startPreview(url: String) {
        if let existing = pendingJob, existing.url == url { return }
        let job = DownloadJob(); job.url = url
        pendingJob = job
        DispatchQueue.main.async { DownloadService.shared.fetchMetadata(for: job) }
    }

    func clearAll() {
        urlDebounceTask?.cancel()
        newURL = ""; pendingJob = nil; showPlaylistBanner = false
        playlistItems = []; playlistFetch = .idle; playlistURL = ""; detectedPlaylistURL = ""
        duplicateEntry = nil
        draft.reset()
        refreshClipboardCandidate()
    }

    func commitDownload() {
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard url.lowercased().hasPrefix("http") else { return }
        let job: DownloadJob = {
            if let p = pendingJob, p.url == url { return p }
            let j = DownloadJob(); j.url = url; return j
        }()

        if draft.audioOnly {
            job.audioOnlyMode = true
            job.selectedVideoFormatId = "audio"
            job.selectedAudioFormatId = ""
            job.format = .audioBest
        } else if !draft.videoFmtId.isEmpty {
            job.selectedVideoFormatId = draft.videoFmtId
            job.selectedAudioFormatId = ""
        } else {
            job.format = draft.fallbackFormat
        }

        job.downloadSubs = draft.downloadSubs
        if !draft.subLang.isEmpty { job.subLang = draft.subLang }
        // nil = inherit the global SponsorBlock setting
        job.sponsorBlockOverride = draft.removeSponsor == settings.sponsorBlock ? nil : draft.removeSponsor

        if draft.clipOn && draft.hasClipTimes {
            job.useSegment = true
            job.segmentMode = .manual
            job.startH = draft.startH; job.startM = draft.startM; job.startS = draft.startS
            job.endH   = draft.endH;   job.endM   = draft.endM;   job.endS   = draft.endS
        }

        queue.jobs.append(job); queue.ensureOutputDir()
        DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
        Haptics.start()
        clearAll()
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
                case .failure(let err):
                    playlistError = err.localizedDescription; playlistFetch = .error; Haptics.error()
                }
            }
        }
    }

    func downloadSelectedPlaylistItems() {
        guard !selectedItems.isEmpty else { return }
        queue.ensureOutputDir()
        let count = selectedItems.count
        for item in selectedItems where item.downloadStatus == .waiting {
            let job = DownloadJob()
            if playlistURL.contains("youtube.com") || playlistURL.contains("youtu.be") {
                job.url = "https://www.youtube.com/watch?v=\(item.videoID)"
            } else if DownloadService.isSoopOrAfreecaURL(playlistURL) {
                // afreecatv/soop: multi-part VOD — must NOT set isPlaylist (avoids playlist
                // output template) but also must NOT let buildArguments add --no-playlist
                // (which forces part 1 regardless of --playlist-items).
                job.url = playlistURL
                job.isPartialPlaylist = true
                job.extraArgs = "--playlist-items \(item.index)"
                // Pre-populate meta so the row shows this part's title/thumbnail/duration
                // and never fires a metadata fetch (which would return part 1's info).
                let durParts = item.duration.split(separator: ":").map(String.init)
                let dH = durParts.count == 3 ? durParts[0] : "00"
                let dM = durParts.count >= 2 ? durParts[durParts.count - 2] : "00"
                let dS = durParts.last ?? "00"
                job.meta = VideoMeta(
                    title: item.title, thumbnail: item.thumbnail,
                    duration: item.duration,
                    durationH: dH, durationM: dM, durationS: dS,
                    hasSubs: false)
                job.endH = dH; job.endM = dM; job.endS = dS
                job.metaState = .done
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
        // Back to the main popover so the user sees their downloads starting
        playlistFetch = .idle
        playlistItems = []
        playlistURL   = ""
        detectedPlaylistURL = ""
        showToast("Started \(count) download\(count == 1 ? "" : "s")")
    }

    func siteIcon(_ url: String) -> String { YoinkFormat.siteSymbol(url) }

    func openMainWindow() {
        Haptics.tap()
        // If we're in accessory (menu-bar-only) mode, re-show the Dock icon first
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        let main = NSApp.windows.first { $0.identifier == YoinkWindowID.main }
            ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            // No window exists - post the standard "reopen" action to create one
            NSApp.sendAction(#selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)), to: nil, from: nil)
        }
    }

    // MARK: - Batch URL import

    func importFromFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Links"
        panel.message = "Choose a text file with one link per line"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importURLsFromFile(url)
        }
    }

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
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        DispatchQueue.main.async { importURLsFromString(content) }
    }

    func importURLsFromString(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("http") && !$0.hasPrefix("#") }
        let urls = lines.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !urls.isEmpty else { return }
        // A single dropped link goes into the composer so the user can pick options
        if urls.count == 1 {
            newURL = urls[0]
            return
        }
        queue.ensureOutputDir()
        for url in urls {
            let job = DownloadJob()
            job.url = url
            job.format = draft.fallbackFormat
            job.audioOnlyMode = draft.audioOnly
            queue.jobs.append(job)
            DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
        }
        Haptics.success()
        showToast("Added \(urls.count) downloads")
    }
}  // end MenuBarView

// MARK: - Menu Job Setup (preview + quick choices for the pasted link)

struct MenuJobSetup: View {
    @ObservedObject var job: DownloadJob
    @ObservedObject var draft: MenuDraft
    let accent: Color
    @ObservedObject private var settings = SettingsManager.shared

    private var meta: VideoMeta? { job.meta }
    private var videoFmts: [VideoFormatInfo] { meta?.videoFormats ?? [] }
    private var fetching: Bool { job.metaState == .fetching }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewRow
            controlsRow
            if draft.showOptions {
                optionsPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: draft.showOptions)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: draft.clipOn)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: draft.downloadSubs)
    }

    // Thumbnail + title
    private var previewRow: some View {
        HStack(spacing: 10) {
            CachedThumb(
                urlString: meta?.thumbnail ?? "",
                width: 72, height: 40, radius: 6,
                placeholder: AnyView(
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07))
                        .overlay(
                            Group {
                                if fetching { ProgressView().controlSize(.small) }
                                else { Image(systemName: draft.audioOnly ? "waveform" : "film")
                                        .font(.system(size: 13)).foregroundStyle(.tertiary) }
                            }
                        )
                )
            )

            VStack(alignment: .leading, spacing: 3) {
                if let meta, !meta.title.isEmpty {
                    Text(meta.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(meta))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else if fetching {
                    Text("Getting video details…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(YoinkFormat.host(job.url))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text(YoinkFormat.host(job.url))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("Ready to download")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func subtitle(_ meta: VideoMeta) -> String {
        var parts: [String] = []
        if !meta.duration.isEmpty { parts.append(meta.duration) }
        parts.append(YoinkFormat.host(job.url))
        if let size = estimatedSize { parts.append("~" + YoinkFormat.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    private var estimatedSize: Int64? {
        guard let meta else { return nil }
        let audio = meta.audioFormats.first?.filesize
        if draft.audioOnly { return audio }
        let video: Int64? = draft.videoFmtId.isEmpty
            ? meta.videoFormats.first?.filesize
            : meta.videoFormats.first { $0.id == draft.videoFmtId }?.filesize
        guard let v = video else { return nil }
        return v + (audio ?? 0)
    }

    // Video/Audio + quality + options disclosure
    private var controlsRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: $draft.audioOnly) {
                Text("Video").tag(false)
                Text("Audio").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 122)
            .help("Audio downloads are saved as MP3")

            if !draft.audioOnly {
                qualityMenu
            } else {
                Text("MP3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                draft.showOptions.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("Options")
                        .font(.system(size: 11.5, weight: .medium))
                    if draft.activeOptionCount > 0 {
                        Text("\(draft.activeOptionCount)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Circle().fill(accent))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(draft.showOptions ? 180 : 0))
                }
                .foregroundStyle(draft.showOptions ? accent : Color.secondary)
                .padding(.horizontal, 6).frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Subtitles, clipping and SponsorBlock")
        }
    }

    private var qualityTitle: String {
        if !videoFmts.isEmpty {
            if draft.videoFmtId.isEmpty {
                if let h = videoFmts.first?.height { return "Best · \(h)p" }
                return "Best"
            }
            if let f = videoFmts.first(where: { $0.id == draft.videoFmtId }) {
                return f.height.map { "\($0)p" } ?? f.id
            }
            return "Best"
        }
        switch draft.fallbackFormat {
        case .best:     return "Best"
        case .mp4_1080: return "1080p"
        case .mp4_720:  return "720p"
        case .mp4_480:  return "480p"
        case .mp4_360:  return "360p"
        default:        return draft.fallbackFormat.displayName
        }
    }

    private var qualityMenu: some View {
        Menu {
            if !videoFmts.isEmpty {
                Button { draft.videoFmtId = "" } label: {
                    checkLabel("Best Available", draft.videoFmtId.isEmpty)
                }
                Divider()
                ForEach(videoFmts) { fmt in
                    Button { draft.videoFmtId = fmt.id } label: {
                        checkLabel(fmt.label, draft.videoFmtId == fmt.id)
                    }
                }
            } else {
                ForEach(DownloadFormat.allCases.filter { !$0.isAudio }) { fmt in
                    Button { draft.fallbackFormat = fmt } label: {
                        checkLabel(fmt.displayName, draft.fallbackFormat == fmt)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(qualityTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .compactMenuStyle()
        .help("Video quality")
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // Subtitles / SponsorBlock / Clip
    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                OptionChip(title: "Subtitles", icon: "captions.bubble", isOn: draft.downloadSubs,
                           help: "Download subtitles alongside the video") {
                    draft.downloadSubs.toggle()
                }
                OptionChip(title: "Skip Sponsors", icon: "forward.end", isOn: draft.removeSponsor,
                           help: "Cut sponsor segments using SponsorBlock") {
                    draft.removeSponsor.toggle()
                }
                OptionChip(title: "Clip", icon: "scissors", isOn: draft.clipOn,
                           help: "Download only part of the video") {
                    draft.clipOn.toggle()
                }
            }

            if draft.downloadSubs {
                HStack(spacing: 8) {
                    Text("Language")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    subtitleLanguage
                    Spacer(minLength: 0)
                }
            }

            if draft.clipOn {
                HStack(spacing: 6) {
                    Text("From")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)
                    MiniHMSInput(h: $draft.startH, m: $draft.startM, s: $draft.startS)
                    Text("to")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    MiniHMSInput(h: $draft.endH, m: $draft.endM, s: $draft.endS,
                                 placeholders: job.meta == nil ? nil : job.videoDurationHMS)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var subtitleLanguage: some View {
        let langs = meta?.availableSubLangs ?? []
        if !langs.isEmpty {
            Menu {
                ForEach(langs, id: \.self) { lang in
                    Button { draft.subLang = lang } label: {
                        checkLabel(lang, draft.subLang == lang)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(draft.subLang.isEmpty ? (langs.first ?? "") : draft.subLang)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            .compactMenuStyle()
            .onAppear { pickDefaultLanguage(langs) }
            .onChange(of: langs) { pickDefaultLanguage($0) }
        } else if fetching {
            Text("Checking available languages…")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            Text("Default (\(settings.defaultSubLang)) if available")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func pickDefaultLanguage(_ langs: [String]) {
        guard draft.subLang.isEmpty || !langs.contains(draft.subLang) else { return }
        let preferred = settings.defaultSubLang
        draft.subLang = langs.contains(preferred) ? preferred : (langs.first ?? "")
    }
}

// MARK: - Mini History Row (recent downloads)

struct MiniHistoryRow: View {
    let entry: HistoryEntry
    let accent: Color
    @State private var hovered = false

    private var fileExists: Bool { FileManager.default.fileExists(atPath: entry.outputPath) }
    private var fileURL: URL { URL(fileURLWithPath: entry.outputPath) }

    var body: some View {
        let exists = fileExists
        HStack(spacing: 10) {
            CachedThumb(
                urlString: entry.thumbnail,
                width: 48, height: 27, radius: 5,
                placeholder: AnyView(
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                        .overlay(Image(systemName: "film")
                            .font(.system(size: 9)).foregroundStyle(.tertiary))
                )
            )
            .opacity(exists ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? YoinkFormat.host(entry.url) : entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(exists ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Text(exists ? entry.date.formatted(.relative(presentation: .named)) : "File moved or deleted")
                    .font(.system(size: 10.5))
                    .foregroundStyle(exists ? Color.secondary : Color.orange)
            }
            Spacer(minLength: 4)

            if exists {
                QuietIconButton(systemImage: "magnifyingglass", help: "Show in Finder", size: 24) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                .opacity(hovered ? 1 : 0)
            } else {
                QuietIconButton(systemImage: "xmark", help: "Remove from History", size: 24) {
                    withAnimation { HistoryStore.shared.remove(entry) }
                }
                .opacity(hovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if exists { NSWorkspace.shared.open(fileURL) } }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(exists ? "Double-click to open" : entry.url)
        .contextMenu {
            if exists {
                Button("Open") { NSWorkspace.shared.open(fileURL) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Remove from History") { withAnimation { HistoryStore.shared.remove(entry) } }
        }
    }
}

// MARK: - Mini Playlist Row
struct MiniPlaylistRow: View {
    @ObservedObject var item: PlaylistItem
    let fg: Color; let fgSec: Color; let fgTer: Color
    let accent: Color; let rowBg: Color; let rowBorder: Color
    var onToggle: () -> Void = {}
    @State private var expanded = false
    @State private var hovered  = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Checkbox
                Button {
                    item.selected.toggle()
                    onToggle()
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
                        Text("Format").font(.system(size: 8, weight: .semibold)).foregroundStyle(fgSec)
                            .frame(width: 56, alignment: .leading)
                        Picker("", selection: $item.format) {
                            ForEach(DownloadFormat.allCases) { f in Text(f.displayName).tag(f) }
                        }.labelsHidden().pickerStyle(.menu).accentColor(accent)
                        Spacer()
                    }
                    // Clip times
                    HStack(spacing: 8) {
                        Text("Clip").font(.system(size: 8, weight: .semibold)).foregroundStyle(fgSec)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start").font(.system(size: 7, weight: .semibold)).foregroundStyle(fgSec)
                            MiniHMSInput(h: $item.startH, m: $item.startM, s: $item.startS, fg: fg)
                        }
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(fgTer)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 3) {
                                Text("End").font(.system(size: 7, weight: .semibold)).foregroundStyle(fgSec)
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
                        Text("Sponsor").font(.system(size: 8, weight: .semibold)).foregroundStyle(fgSec)
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
                                Text("Chapter").font(.system(size: 8, weight: .semibold)).foregroundStyle(fgSec)
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

        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Mini Job Row

struct MiniJobRow: View {
    @ObservedObject var job: DownloadJob
    @ObservedObject var queue: DownloadQueue
    let accent: Color
    var openMainWindow: () -> Void = {}
    @State private var hovered = false

    private var title: String {
        if let t = job.meta?.title, !t.isEmpty { return t }
        return YoinkFormat.host(job.url)
    }

    private var tint: Color {
        switch job.status {
        case .done:     return .green
        case .failed:   return .red
        case .paused:   return .orange
        case .merging:  return .purple
        default:        return accent
        }
    }

    private var showsBar: Bool {
        job.status.isActive || job.status.isPaused
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if showsBar {
                    ThinProgressBar(progress: job.status.progress, tint: tint, height: 3)
                }
                Text(job.statusDetail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(job.status.isDone ? Color.green
                                     : (job.status == .cancelled || job.status == .idle ? Color.secondary
                                        : (job.isFailed ? Color.red.opacity(0.9) : Color.secondary)))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                secondaryAction
                    .opacity(hovered ? 1 : 0)
                    .allowsHitTesting(hovered)
                primaryAction
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(job.url)
        .contextMenu { contextItems }
    }

    private var thumbnail: some View {
        CachedThumb(
            urlString: job.meta?.thumbnail ?? "",
            width: 48, height: 27, radius: 5,
            placeholder: AnyView(
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                    .overlay(Image(systemName: job.audioOnlyMode ? "waveform" : "film")
                        .font(.system(size: 9)).foregroundStyle(.tertiary))
            )
        )
        .overlay(alignment: .bottomTrailing) {
            if job.status.isDone || job.isFailed {
                Image(systemName: job.status.isDone ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, job.status.isDone ? Color.green : Color.red)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: 4, y: 4)
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch job.status {
        case .downloading:
            QuietIconButton(systemImage: "pause.fill", help: "Pause", size: 26) { job.pause() }
        case .paused:
            QuietIconButton(systemImage: "play.fill", help: "Resume", size: 26, tint: .orange) { job.resume() }
        case .done(let url):
            QuietIconButton(systemImage: "magnifyingglass", help: "Show in Finder", size: 26) { reveal(url) }
        case .failed:
            QuietIconButton(systemImage: "arrow.clockwise", help: "Try Again", size: 26, tint: .red) { retry() }
        case .idle, .cancelled:
            QuietIconButton(systemImage: "arrow.down.circle", help: "Start Download", size: 26, tint: accent) { startNow() }
        case .fetching, .merging:
            ProgressView().controlSize(.small).frame(width: 26, height: 26)
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if job.status.isActive || job.status.isPaused {
            QuietIconButton(systemImage: "xmark", help: "Cancel Download", size: 24) {
                job.cancel(); Haptics.tap()
            }
        } else {
            QuietIconButton(systemImage: "xmark", help: "Remove from List", size: 24) {
                queue.remove(job)
            }
        }
    }

    @ViewBuilder
    private var contextItems: some View {
        if case .done(let url) = job.status {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { reveal(url) }
            Divider()
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url, forType: .string)
        }
        Button("Show in Yoink Window") {
            SettingsManager.shared.appModeRaw = AppMode.video.rawValue
            openMainWindow()
        }
        Divider()
        if job.status.isActive || job.status.isPaused {
            Button("Cancel Download") { job.cancel() }
        } else {
            Button("Remove from List") { queue.remove(job) }
        }
    }

    private func reveal(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func startNow() {
        guard DependencyService.shared.enginesReady else { openMainWindow(); return }
        queue.ensureOutputDir()
        DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
        Haptics.start()
    }

    private func retry() {
        job.retryCount += 1
        job.reset()
        startNow()
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

    var progressPercent: Int { Int(progress * 100) }

    @ViewBuilder
    private var ring: some View {
        Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1.6).frame(width: 19)
        Circle().trim(from: 0, to: max(0.02, progress))
            .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 19).rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.4), value: progress)
    }

    var body: some View {
        ZStack {
            switch icon.kind {
            case .dynamic:
                // Live 0–100 counter while downloading
                if hasActive {
                    ring
                    Text("\(progressPercent)")
                        .font(.system(size: progressPercent >= 100 ? 7 : 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .medium))
                }

            case .customText:
                if hasActive { ring }
                Text(icon.value)
                    .font(.system(size: icon.value.count > 2 ? 8 : 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 20)

            case .emoji:
                if hasActive { ring }
                Text(icon.value)
                    .font(.system(size: hasActive ? 10 : 13))

            case .sfSymbol:
                if hasActive { ring }
                Image(systemName: icon.value)
                    .font(.system(size: hasActive ? 8.5 : 13, weight: hasActive ? .bold : .medium))
            }
        }
        .frame(width: 22, height: 22)
        .onReceive(timer) { _ in tick += 1 }
        .accessibilityLabel(hasActive ? "Yoink, downloading \(progressPercent) percent" : "Yoink")
        // Drag a URL onto the menu bar icon → pre-fill the popover
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
            for provider in providers {
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        DispatchQueue.main.async { handleDroppedURL(url.absoluteString) }
                    }
                    return true
                }
                if provider.canLoadObject(ofClass: String.self) {
                    _ = provider.loadObject(ofClass: String.self) { str, _ in
                        guard let str = str, str.hasPrefix("http") else { return }
                        DispatchQueue.main.async { handleDroppedURL(str) }
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
            Text(":").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
            MiniTimeBox(text: $m, placeholder: placeholders?.m ?? "00", maxVal: 59, fg: fg)
            Text(":").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary)
            MiniTimeBox(text: $s, placeholder: placeholders?.s ?? "00", maxVal: 59, fg: fg)
        }
    }
}

struct MiniTimeBox: View {
    @Binding var text: String; let placeholder: String; let maxVal: Int
    var fg: Color = .primary
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(fg)
            .multilineTextAlignment(.center)
            .frame(width: 26, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(focused ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12),
                                  lineWidth: 0.5)
            )
            .focused($focused)
            .onChange(of: text) { v in
                let d = String(v.filter(\.isNumber).prefix(2))
                if let n = Int(d), n > maxVal { text = String(maxVal) } else if d != v { text = d }
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
/// dismissed without requiring macOS 14's .onKeyPress modifier. Only reacts to
/// key events aimed at the window hosting this view — local monitors see every
/// event in the app, so without that check Escape would close the main window too.
struct EscapeKeyHandler: NSViewRepresentable {
    let onEscape: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard event.keyCode == 53, // Escape
                  let coordinator,
                  let window = coordinator.view?.window,
                  event.window === window,
                  window.attachedSheet == nil
            else { return event }
            // Let an open menu or field editor handle Escape first if it wants to
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            coordinator.onEscape?(window)
            return nil
        }
        coordinator.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onEscape: ((NSWindow) -> Void)?
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
