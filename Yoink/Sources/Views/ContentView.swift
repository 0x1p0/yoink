import SwiftUI

extension Notification.Name {
    static let openPlaylistURL      = Notification.Name("openPlaylistURL")
    static let playlistURLDetected  = Notification.Name("playlistURLDetected")
    static let redownloadEntry      = Notification.Name("redownloadEntry")
    static let pasteAndFocus        = Notification.Name("pasteAndFocus")
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
                    .onMove { queue.move(from: $0, to: $1) }
                    AddURLButton().padding(.top, 2)
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
            Button("Just this video") {
                if let job = playlistAlertJob {
                    let cleaned = DownloadJob.stripPlaylistParams(from: job.url)
                    job.url = cleaned
                }
            }
            Button("Full playlist →") {
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
            Text("This URL contains a playlist. Download just this video, or open the full playlist in advanced mode?")
        }
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
    @State private var hoverGear = false
    @State private var hoverSrc  = false

    var body: some View {
        HStack(spacing: 12) {
            ModeToggle()
                .fixedSize()

            Spacer(minLength: 8)

            VStack(spacing: 0) {
                Text("Yoink")
                    .font(.system(size: 17, weight: .heavy, design: .serif))
                    .foregroundStyle(.primary.opacity(0.92))
                    .tracking(0.6)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        headerIcon("gearshape", hovered: hoverGear)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverGear = $0 }
                    .help("Settings  ⌘,")
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        headerIcon("gearshape", hovered: hoverGear)
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverGear = $0 }
                    .help("Settings  ⌘,")
                    .keyboardShortcut(",", modifiers: .command)
                }

                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/0x1p0/yoink")!)
                } label: {
                    headerIcon("chevron.left.forwardslash.chevron.right", hovered: hoverSrc, size: 11)
                }
                .buttonStyle(.plain)
                .onHover { hoverSrc = $0 }
                .help("View source on GitHub")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(.ultraThinMaterial, in: Capsule(style: .circular))
        .overlay {
            Capsule(style: .circular)
                .strokeBorder(
                    Color.white.opacity(
                        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            ? 0.12 : 0.18
                    ),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
        .clipShape(Capsule(style: .circular))
        .modifier(GlassChromeModifier(cornerRadius: 0, interactive: true, shape: Capsule(style: .circular)))
    }

    @ViewBuilder
    private func headerIcon(_ name: String, hovered: Bool, size: CGFloat = 12) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(hovered ? Color.primary.opacity(0.85) : Color.secondary)
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(hovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Circle())
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

struct ModeToggle: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        Picker("", selection: Binding(
            get: { settings.appModeRaw },
            set: { newValue in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    settings.appModeRaw = newValue
                }
            }
        )) {
            ForEach(AppMode.allCases) { mode in
                Text(mode.shortLabel).tag(mode.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

// MARK: - Add URL Button

struct AddURLButton: View {
    @EnvironmentObject var queue: DownloadQueue
    @State private var hovered = false
    var body: some View {
        Button { queue.addJob() } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(hovered ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                        .frame(width: 36, height: 36)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add URL to download")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.55))
                    Text("Paste a YouTube, Twitch, Vimeo or any site URL   ·   ⌘N")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary.opacity(0.32))
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                if #available(macOS 26.0, *) {
                    shape
                        .fill(hovered ? Color.accentColor.opacity(0.04) : Color.clear)
                        .overlay {
                            shape.strokeBorder(
                                style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                            )
                            .foregroundStyle(hovered
                                ? Color.accentColor.opacity(0.5)
                                : Color(.separatorColor).opacity(0.35))
                        }
                        .glassEffect(.regular.interactive(hovered), in: shape)
                        .allowsHitTesting(false)
                } else {
                    shape
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                        .foregroundStyle(hovered
                            ? Color.accentColor.opacity(0.45)
                            : Color(.separatorColor).opacity(0.35))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: hovered)
        .keyboardShortcut("n", modifiers: .command)
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
                    .glassEffect(.regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            toolbarButtons
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 10) {
            DepPill(label: "ffmpeg", status: deps.ffmpeg) { showFfmpegSheet = true }
            DepPill(label: "yt-dlp", status: deps.ytdlp) { showYtdlpSheet  = true }

            Divider().frame(height: 16).opacity(0.35)

            OutputFolderButton(directory: queue.outputDirectory, action: { pickOutputFolder() })

            CategoryPicker()
                .environmentObject(settings)
                .environmentObject(queue)

            Button {
                importURLsFromFile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text(importToast ?? "Import")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(importToast != nil ? .green : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Import a .txt file of URLs (one per line)")
            .animation(.easeOut(duration: 0.2), value: importToast)

            Spacer(minLength: 8)

            if queue.jobs.contains(where: { $0.status.isTerminal }) {
                Button("Clear") { queue.clearCompleted() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            if queue.jobs.contains(where: { if case .failed = $0.status { return true }; return false }) {
                Button {
                    queue.retryFailed()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                        Text("Retry").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Re-queue all failed downloads")
            }

            Button {
                queue.downloadAll()
            } label: {
                Label("Download All", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .glassPrimaryButtonStyle()
            .disabled(!queue.jobs.contains { $0.hasURL && !$0.status.isActive })
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            queue.outputDirectory = url
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func importURLsFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import URLs from Text File"
        panel.message = "Select a plain-text file with one URL per line"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let count = queue.importURLsFromFile(url)
            guard count > 0 else { return }
            importToast = "\(count) URL\(count == 1 ? "" : "s") imported"
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { importToast = nil }
        }
    }
}

// MARK: - Output Folder Button (clearly clickable)

struct OutputFolderButton: View {
    let directory: URL
    var action: (() -> Void)? = nil
    // Legacy binding support (ignored - kept for API compat)
    var showPicker: Binding<Bool> = .constant(false)
    @State private var hovered = false

    var body: some View {
        Button {
            if let action { action() }
            else { showPicker.wrappedValue = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor.opacity(0.85))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Save to")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.65))
                    Text(directory.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if #available(macOS 26.0, *) {
                    shape.fill(hovered ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.05))
                        .overlay {
                            shape.strokeBorder(
                                hovered ? Color.accentColor.opacity(0.35) : Color(.separatorColor).opacity(0.55),
                                lineWidth: 0.5
                            )
                        }
                        .glassEffect(.regular.interactive(hovered), in: shape)
                        .allowsHitTesting(false)
                } else {
                    shape.fill(hovered ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05))
                        .overlay {
                            shape.strokeBorder(
                                hovered ? Color.accentColor.opacity(0.3) : Color(.separatorColor).opacity(0.7),
                                lineWidth: 0.5
                            )
                        }
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .help(directory.path)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Dep Pill

struct DepPill: View {
    let label: String; let status: DepStatus; let action: () -> Void
    @State private var hovered = false; @State private var animDot = false
    var isAnimating: Bool {
        switch status { case .checking, .updating: return true; default: return false }
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(status.dotColor).frame(width: 6, height: 6)
                    .shadow(color: status.dotColor.opacity(0.55), radius: 3)
                    .opacity(isAnimating ? (animDot ? 0.2 : 1.0) : 1.0)
                    .animation(isAnimating ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .default, value: animDot)
                Text(label).font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(hovered ? 0.8 : 0.65))
                if let v = status.version {
                    Text(v).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                if #available(macOS 26.0, *) {
                    shape.fill(Color.primary.opacity(hovered ? 0.07 : 0.04))
                        .overlay {
                            shape.strokeBorder(Color(.separatorColor).opacity(0.55), lineWidth: 0.5)
                        }
                        .glassEffect(.regular.interactive(hovered), in: shape)
                        .allowsHitTesting(false)
                } else {
                    shape.fill(Color.primary.opacity(hovered ? 0.07 : 0.04))
                        .overlay {
                            shape.strokeBorder(Color(.separatorColor).opacity(0.7), lineWidth: 0.5)
                        }
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .onAppear { if isAnimating { animDot = true } }
        .onChange(of: isAnimating) { animDot = $0 }
        .help(status.statusLabel)
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

