import SwiftUI

extension Notification.Name {
    static let openPlaylistURL      = Notification.Name("openPlaylistURL")
    static let playlistURLDetected  = Notification.Name("playlistURLDetected")
    static let redownloadEntry      = Notification.Name("redownloadEntry")
    static let pasteAndFocus        = Notification.Name("pasteAndFocus")
    /// Object: the `DownloadJob.id` whose link field should take keyboard focus.
    static let focusJobURLField     = Notification.Name("focusJobURLField")
}

struct ContentView: View {
    @EnvironmentObject var queue       : DownloadQueue
    @EnvironmentObject var deps        : DependencyService
    @EnvironmentObject var theme       : ThemeManager
    @EnvironmentObject var settings    : SettingsManager
    @EnvironmentObject var clipMonitor : ClipboardMonitor
    @EnvironmentObject var watchLater  : WatchLaterStore

    @State private var showCrashResume = false
    @State private var showTutorial    = false

    var body: some View {
        ZStack {
            // Rich window bed — material + subtle depth so glass chrome has something to refract
            ZStack {
                if settings.useBlurBackground {
                    VisualEffectBlur(material: theme.blurMaterial)
                } else {
                    theme.windowBackground
                }
                // Soft vignette / gradient for dimension
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.03),
                        Color.clear,
                        Color.black.opacity(0.04)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Clear space so floating header doesn't collide with content
                Color.clear.frame(height: 62)

                if settings.appMode == .video {
                    SimpleDownloadView()
                } else if settings.appMode == .playlist {
                    AdvancedView()
                        .environmentObject(queue).environmentObject(deps)
                        .environmentObject(theme).environmentObject(settings)
                } else if settings.appMode == .watchLater {
                    WatchLaterView()
                        .environmentObject(watchLater).environmentObject(queue)
                        .environmentObject(settings).environmentObject(theme)
                } else {
                    HistoryView().environmentObject(theme)
                }
            }
            // Floating Liquid Glass header
            .overlay(alignment: .top) {
                WindowHeader()
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Clipboard banner floats below header
            .overlay(alignment: .top) {
                ClipboardBanner()
                    .padding(.top, 70)
                    .animation(.spring(response: 0.35, dampingFraction: 0.82), value: clipMonitor.showBanner)
            }
        }
        .onAppear {
            deps.checkAll()
            // Start clipboard monitor if enabled
            if settings.clipboardMonitor { clipMonitor.start() }
            // Check for interrupted downloads
            if !DownloadQueue.interruptedURLs.isEmpty { showCrashResume = true }
            // Show tutorial on very first launch
            if !settings.hasSeenTutorial { showTutorial = true }
        }
        .onChange(of: settings.clipboardMonitor) { enabled in
            if enabled { clipMonitor.start() } else { clipMonitor.stop() }
        }

        .onDrop(of: [.url, .text], isTargeted: nil) { providers in handleDrop(providers) }
        // Tag this window so AppDelegate only makes the main window transparent
        .background(MainWindowTagger())
        // ⌘V: paste clipboard URL into the next empty card (without auto-pasting on every focus)
        .onReceive(NotificationCenter.default.publisher(for: .pasteAndFocus)) { _ in
            pasteClipboardURL()
        }
        .onReceive(NotificationCenter.default.publisher(for: .redownloadEntry)) { notif in
            guard let urlStr = notif.object as? String else { return }
            withAnimation(.spring(response: 0.3)) { settings.appModeRaw = AppMode.video.rawValue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let empty = queue.jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
                    empty.url = urlStr
                } else { queue.addJob(url: urlStr) }
            }
        }
        // Crash-resume alert
        .alert("Resume Interrupted Downloads?", isPresented: $showCrashResume) {
            Button("Resume All") {
                let urls = DownloadQueue.interruptedURLs
                DownloadQueue.interruptedURLs = []
                for url in urls { queue.addJob(url: url) }
                withAnimation { settings.appModeRaw = AppMode.video.rawValue }
            }
            Button("Dismiss", role: .cancel) { DownloadQueue.interruptedURLs = [] }
        } message: {
            let count = DownloadQueue.interruptedURLs.count
            Text("\(count) download\(count == 1 ? "" : "s") didn't finish last time. Re-queue \(count == 1 ? "it" : "them") now?")
        }
        .sheet(isPresented: $showTutorial) {
            TutorialView { showTutorial = false }
        }
    }

    // MARK: - ⌘V Paste & Focus

    private func pasteClipboardURL() {
        guard settings.appMode == .video else { return }
        let pb = NSPasteboard.general
        guard let raw = pb.string(forType: .string) ?? pb.string(forType: .URL) else { return }

        // Extract all HTTP URLs from the clipboard (handles multi-line paste from spreadsheets,
        // text editors, etc.). Deduplicate against URLs already in the queue.
        let existingURLs = Set(queue.jobs.map(\.url))
        let urls = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") && !existingURLs.contains($0) }

        guard !urls.isEmpty else { return }

        if urls.count == 1 {
            // Single URL - original behaviour: fill an empty slot or add a new card
            if let emptyJob = queue.jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
                emptyJob.url = urls[0]
            } else {
                queue.addJob(url: urls[0])
            }
        } else {
            // Multiple URLs - fill any empty slots first, then batch-add the rest
            var remaining = urls
            for job in queue.jobs where !job.hasURL && job.status == .idle {
                guard !remaining.isEmpty else { break }
                job.url = remaining.removeFirst()
            }
            if !remaining.isEmpty {
                queue.addBatchURLs(remaining)
            }
        }
    }

    // MARK: - Drag-drop onto main window

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        var urlStrings: [String] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url { urlStrings.append(u.absoluteString) }
                    group.leave()
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { str, _ in
                    if let s = str {
                        let lines = s.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { $0.lowercased().hasPrefix("http") }
                        urlStrings.append(contentsOf: lines)
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
            handled = true
        }

        group.notify(queue: .main) {
            let unique = urlStrings.filter { !queue.jobs.map(\.url).contains($0) }
            guard !unique.isEmpty else { return }
            if unique.count == 1 {
                if let empty = queue.jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
                    empty.url = unique[0]
                } else {
                    queue.addJob(url: unique[0])
                }
            } else {
                queue.addBatchURLs(unique)
            }
            Haptics.success()
        }
        return handled
    }
}

// macOS NSVisualEffectView bridge for true frosted-glass blur
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state        = .active
        v.material     = material
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

// Marks the main content window so AppDelegate never clears Settings/panels
private struct MainWindowTagger: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.identifier = YoinkWindowID.main
            v.window?.isOpaque = false
            v.window?.backgroundColor = .clear
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.identifier = YoinkWindowID.main
        }
    }
}

// MARK: - Simple / Video mode

struct SimpleDownloadView: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager

    // Playlist alert state
    @State private var showPlaylistAlert = false
    @State private var playlistAlertJob  : DownloadJob? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 12) {
                    ForEach(queue.jobs) { job in
                        JobCard(job: job, onPlaylistDetected: { handlePlaylist(job: job) })
                            .transition(.asymmetric(
                                insertion: .push(from: .top).combined(with: .opacity),
                                removal:   .push(from: .bottom).combined(with: .opacity)))
                    }
                    if queueIsEmpty {
                        EmptyQueueHints()
                            .transition(.opacity)
                    } else if !queue.jobs.contains(where: { !$0.hasURL }) {
                        // Only offer another card when there isn't a blank one already waiting
                        AddURLButton().padding(.top, 2)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: queue.jobs.map(\.id))
            }
        }
        // Floating bottom toolbar over content
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomToolbar()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .onChange(of: queue.jobs.isEmpty) { empty in
            if empty { queue.addJob() }
        }
        .onAppear { if queue.jobs.isEmpty { queue.addJob() } }
        .onReceive(NotificationCenter.default.publisher(for: .playlistURLDetected)) { notif in
            if let job = notif.object as? DownloadJob { handlePlaylist(job: job) }
        }
        .background(
            Group {
                Button("") {
                    NotificationCenter.default.post(name: .pasteAndFocus, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
            }
        )
        .alert("Playlist detected", isPresented: $showPlaylistAlert) {
            Button("Just This Video") {
                if let job = playlistAlertJob {
                    let cleaned = DownloadJob.stripPlaylistParams(from: job.url)
                    job.url = cleaned
                }
            }
            Button("Choose from Playlist…") {
                let url = playlistAlertJob?.url ?? ""
                if let job = playlistAlertJob { queue.remove(job) }
                settings.pendingPlaylistURL = url
                withAnimation(.spring(response: 0.3)) {
                    settings.appModeRaw = AppMode.playlist.rawValue
                }
            }
            Button("Cancel", role: .cancel) {
                if let job = playlistAlertJob { queue.remove(job) }
            }
        } message: {
            Text("This link is part of a playlist. Download just this video, or choose videos from the whole playlist?")
        }
    }

    private var queueIsEmpty: Bool {
        queue.jobs.allSatisfy { !$0.hasURL }
    }

    func handlePlaylist(job: DownloadJob) {
        playlistAlertJob = job
        showPlaylistAlert = true
    }
}

// MARK: - Window Header (floating Liquid Glass)

struct WindowHeader: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            Text("Yoink")
                .font(.system(size: 16, weight: .heavy, design: .serif))
                .foregroundStyle(.primary.opacity(0.9))
                .tracking(0.4)
                .padding(.leading, 10)
                .frame(minWidth: 80, alignment: .leading)

            Spacer(minLength: 8)

            ModeToggle()
                .fixedSize()

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings  ⌘,")
                } else {
                    QuietIconButton(systemImage: "gearshape", help: "Settings  ⌘,", size: 30) {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(.ultraThinMaterial, in: Capsule(style: .circular))
        .overlay {
            Capsule(style: .circular)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .clipShape(Capsule(style: .circular))
        .modifier(GlassChromeModifier(cornerRadius: 0, interactive: false, shape: Capsule(style: .circular)))
    }
}

/// Applies Liquid Glass to a view (not just its background) on macOS 26+.
struct GlassChromeModifier<S: Shape>: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool
    var shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
        }
    }
}

/// Tabs with icons and live counts. Click a tab, or press anywhere on the bar and slide —
/// the Liquid Glass pill follows the pointer, morphs between tab widths, and snaps to the
/// nearest tab on release. ⌘1–⌘4 switch tabs from the keyboard.
struct ModeToggle: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var watchLater: WatchLaterStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var tabFrames: [AppMode: CGRect] = [:]
    /// Pill centre while the user is sliding it; nil when at rest.
    @State private var dragX: CGFloat? = nil
    @State private var isPressing = false
    @State private var hoveredMode: AppMode? = nil
    @State private var lastDragMode: AppMode? = nil

    private let modes = AppMode.allCases
    private static let space = "modeTabs"

    private var isDragging: Bool { dragX != nil }

    /// The tab that reads as "selected" right now — follows the pill while dragging.
    private var highlighted: AppMode {
        if let x = dragX { return mode(at: x) }
        return settings.appMode
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            pill
            HStack(spacing: 2) {
                ForEach(modes) { mode in
                    tabLabel(mode)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(TabFramesKey.self) { tabFrames = $0 }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
        .contentShape(Capsule(style: .continuous))
        .gesture(slideGesture)
        .background(shortcutButtons)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    // MARK: Pill

    private var pillFrame: CGRect? {
        guard let selected = tabFrames[settings.appMode] else { return nil }
        guard let x = dragX else { return selected }
        let width = interpolatedWidth(at: x)
        let first = modes.compactMap { tabFrames[$0] }.first ?? selected
        let last  = modes.compactMap { tabFrames[$0] }.last ?? selected
        let centre = min(max(x, first.minX + width / 2), last.maxX - width / 2)
        return CGRect(x: centre - width / 2, y: selected.minY, width: width, height: selected.height)
    }

    @ViewBuilder
    private var pill: some View {
        if let frame = pillFrame {
            pillShape
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(isDragging ? 1.1 : (isPressing ? 0.97 : 1))
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var pillShape: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(isDragging ? 0.04 : 0.10)
                                           : Color.white.opacity(isDragging ? 0.25 : 0.85))
                .glassEffect(isDragging ? .clear.interactive() : .regular.interactive(), in: shape)
                .shadow(color: .black.opacity(isDragging ? 0.18 : 0.08), radius: isDragging ? 8 : 2, y: isDragging ? 3 : 1)
        } else {
            shape
                .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                .overlay(shape.strokeBorder(Color.primary.opacity(isDragging ? 0.12 : 0.05), lineWidth: 0.5))
                .shadow(color: .black.opacity(isDragging ? 0.18 : (colorScheme == .dark ? 0 : 0.10)),
                        radius: isDragging ? 8 : 2, y: isDragging ? 3 : 1)
        }
    }

    // MARK: Tabs

    private func count(for mode: AppMode) -> Int {
        switch mode {
        case .video:      return queue.jobs.filter { $0.hasURL && !$0.status.isTerminal }.count
        case .watchLater: return watchLater.items.count
        default:          return 0
        }
    }

    private func tabLabel(_ mode: AppMode) -> some View {
        let lit = highlighted == mode
        let n = count(for: mode)
        let index = (modes.firstIndex(of: mode) ?? 0) + 1
        return HStack(spacing: 5) {
            Image(systemName: lit ? mode.selectedIcon : mode.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(mode.shortLabel)
                .font(.system(size: 12, weight: lit ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()   // never truncate a tab name (e.g. when a count badge appears)
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(lit ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 17, minHeight: 16)
                    .background(Capsule().fill(lit ? Color.accentColor : Color.primary.opacity(0.1)))
                    .fixedSize()
            }
        }
        .foregroundStyle(lit ? Color.primary : (hoveredMode == mode ? Color.primary.opacity(0.8) : Color.secondary))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .contentShape(Capsule())
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: TabFramesKey.self,
                                       value: [mode: geo.frame(in: .named(Self.space))])
            }
        )
        .onHover { inside in
            if inside { hoveredMode = mode } else if hoveredMode == mode { hoveredMode = nil }
        }
        .animation(.easeOut(duration: 0.15), value: lit)
        .help("\(mode.shortLabel)  ⌘\(index)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(settings.appMode == mode ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(mode) }
    }

    // MARK: Interaction

    private var slideGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !isPressing {
                    withAnimation(.easeOut(duration: 0.12)) { isPressing = true }
                }
                // Treat small movements as a click; past a few points the pill follows the pointer
                guard isDragging || abs(value.translation.width) > 4 else { return }
                if !isDragging { Haptics.tick() }
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.82)) {
                    dragX = value.location.x
                }
                let m = mode(at: value.location.x)
                if m != lastDragMode {
                    if lastDragMode != nil { Haptics.tick() }
                    lastDragMode = m
                }
            }
            .onEnded { value in
                let target = mode(at: value.location.x)
                withAnimation(.spring(response: 0.36, dampingFraction: 0.76)) {
                    dragX = nil
                    isPressing = false
                    settings.appModeRaw = target.rawValue
                }
                lastDragMode = nil
            }
    }

    private func select(_ mode: AppMode) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
            settings.appModeRaw = mode.rawValue
        }
    }

    /// Nearest tab to an x position in the bar's coordinate space.
    private func mode(at x: CGFloat) -> AppMode {
        modes.min { a, b in
            abs((tabFrames[a]?.midX ?? .infinity) - x) < abs((tabFrames[b]?.midX ?? .infinity) - x)
        } ?? settings.appMode
    }

    /// Pill width blended between neighbouring tabs so it morphs smoothly as it slides.
    private func interpolatedWidth(at x: CGFloat) -> CGFloat {
        let frames = modes.compactMap { tabFrames[$0] }
        guard let first = frames.first, let last = frames.last else { return 80 }
        if x <= first.midX { return first.width }
        for (a, b) in zip(frames, frames.dropFirst()) where x <= b.midX {
            let t = (x - a.midX) / max(1, b.midX - a.midX)
            return a.width + (b.width - a.width) * t
        }
        return last.width
    }

    /// Invisible buttons that carry the ⌘1–⌘4 shortcuts.
    private var shortcutButtons: some View {
        ZStack {
            ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                Button("") { select(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [AppMode: CGRect] = [:]
    static func reduce(value: inout [AppMode: CGRect], nextValue: () -> [AppMode: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Add URL Button

struct AddURLButton: View {
    @EnvironmentObject var queue: DownloadQueue
    @State private var hovered = false
    var body: some View {
        Button { queue.addJob() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add Another Link")
                    .font(.system(size: 12.5, weight: .medium))
                Text("⌘N")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(hovered ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .keyboardShortcut("n", modifiers: .command)
    }
}

// MARK: - Getting-started hints (shown under an empty queue)

struct EmptyQueueHints: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 22) {
                hint(icon: "command", title: "⌘V to paste", detail: "anywhere in this window")
                hint(icon: "arrow.down.doc", title: "Drop links", detail: "or a .txt file of them")
                hint(icon: settings.clipboardMonitor ? "doc.on.clipboard" : "menubar.arrow.up.rectangle",
                     title: settings.clipboardMonitor ? "Just copy a link" : "Use the menu bar",
                     detail: settings.clipboardMonitor ? "Yoink will offer it" : "download without this window")
            }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity)
    }

    private func hint(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(height: 20)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 150)
    }
}

// MARK: - Bottom Toolbar (floating Liquid Glass bar)

struct BottomToolbar: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager
    @State private var showFfmpegSheet  = false
    @State private var showYtdlpSheet   = false
    @State private var importToast: String? = nil

    var body: some View {
        toolbarContent
        .sheet(isPresented: $showFfmpegSheet) { DepSheet(tool: "ffmpeg").environmentObject(deps) }
        .sheet(isPresented: $showYtdlpSheet)  { DepSheet(tool: "yt-dlp").environmentObject(deps) }
    }

    @ViewBuilder
    private var toolbarContent: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                toolbarButtons
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            toolbarButtons
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        }
    }

    private var pendingCount: Int {
        queue.jobs.filter { $0.hasURL && ($0.status == .idle || $0.status == .cancelled) }.count
    }
    private var hasFinished: Bool { queue.jobs.contains { $0.status.isTerminal } }
    private var failedCount: Int { queue.jobs.filter(\.isFailed).count }

    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            EngineStatusMenu(onShowYtdlp: { showYtdlpSheet = true },
                             onShowFfmpeg: { showFfmpegSheet = true })

            SaveLocationMenu()

            QuietIconButton(systemImage: "square.and.arrow.down.on.square",
                            help: "Import links from a text file (one per line)", size: 30) {
                importURLsFromFile()
            }

            if let importToast {
                Label(importToast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)

            if failedCount > 0 {
                Button {
                    queue.retryFailed()
                } label: {
                    Label(failedCount == 1 ? "Retry Failed" : "Retry \(failedCount) Failed",
                          systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Try all failed downloads again")
            }

            if hasFinished {
                Button("Clear Finished") { queue.clearCompleted() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help("Remove finished, failed and cancelled downloads from the list  ⇧⌘⌫")
            }

            Button {
                queue.downloadAll()
            } label: {
                Label(pendingCount > 1 ? "Download All (\(pendingCount))" : "Download All",
                      systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .glassPrimaryButtonStyle()
            .disabled(pendingCount == 0)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("Start every download in the list  ⇧⌘D")
        }
        .animation(.easeOut(duration: 0.2), value: importToast)
        .animation(.easeOut(duration: 0.2), value: failedCount)
        .animation(.easeOut(duration: 0.2), value: hasFinished)
    }

    private func importURLsFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Links"
        panel.message = "Choose a text file with one link per line"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let count = queue.importURLsFromFile(url)
            guard count > 0 else { return }
            importToast = "Added \(count) link\(count == 1 ? "" : "s")"
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { importToast = nil }
        }
    }
}

// MARK: - Primary Button Style

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? .white : .secondary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(enabled
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0)
                    : Color.primary.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass helpers

extension View {
    /// Prominent primary CTA — real glass on macOS 26+, accent pill fallback.
    @ViewBuilder
    func glassPrimaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(PrimaryButtonStyle())
        }
    }

    /// Secondary toolbar/control button.
    @ViewBuilder
    func glassSecondaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain)
        }
    }

    /// Floating chrome bar (header / toolbar). Liquid Glass on macOS 26+, material fallback.
    /// Always passes an explicit shape — bare `glassEffect(.regular)` draws a giant circle.
    @ViewBuilder
    func yoinkGlassSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                }
                .glassEffect(.regular.interactive(), in: shape)
                .clipShape(shape)
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5)
                }
        }
    }

    /// Card / grouped-section glass surface.
    @ViewBuilder
    func yoinkGlassCard(cornerRadius: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(shape.fill(.thinMaterial))
                .overlay {
                    shape.strokeBorder(Color(.separatorColor).opacity(0.35), lineWidth: 0.5)
                }
                .glassEffect(.regular, in: shape)
        } else {
            self
        }
    }
}

