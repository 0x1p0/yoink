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
            if settings.useBlurBackground {
                VisualEffectBlur(material: theme.blurMaterial).ignoresSafeArea()
            } else {
                ZStack {
                    theme.windowBackground.ignoresSafeArea()
                    theme.backgroundGradient.ignoresSafeArea()
                }
            }

            VStack(spacing: 0) {
                WindowHeader()
                Divider().opacity(0.08)

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
            // Clipboard banner floats over content - doesn't push layout
            .overlay(alignment: .top) {
                ClipboardBanner()
                    .padding(.top, 52) // clears the header
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
            Divider().opacity(0.06)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 9) {
                    ForEach(queue.jobs) { job in
                        JobCard(job: job, onPlaylistDetected: { handlePlaylist(job: job) })
                            .transition(.asymmetric(
                                insertion: .push(from: .top).combined(with: .opacity),
                                removal:   .push(from: .bottom).combined(with: .opacity)))
                    }
                    .onMove { queue.move(from: $0, to: $1) }
                    AddURLButton().padding(.top, 4)
                }
                .padding(20).padding(.bottom, 68)
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: queue.jobs.map(\.id))
            }
            Divider().opacity(0.08)
            BottomToolbar()
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

// MARK: - Window Header

struct WindowHeader: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 0) {
            // Mode toggle - left-aligned, no fixed width so 4 tabs fit
            ModeToggle()
                .padding(.leading, 16)

            Spacer()

            // Centered title
            VStack(spacing: 1) {
                Text("Yoink")
                    .font(.system(size: 20, weight: .heavy, design: .serif))
                    .foregroundStyle(.primary.opacity(0.9))
                    .tracking(1.2)
                Text("yt-dlp  ·  ffmpeg")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .tracking(2.2)
            }
            .frame(maxHeight: .infinity)

            Spacer()

            // Right side - settings gear + theme + blur quick toggles
            HStack(spacing: 6) {
                // Settings gear - always visible in header across all tabs
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .hoverHaptic()
                    .help("Settings  ⌘,")
                } else {
                    Button {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .hoverHaptic()
                    .help("Settings  ⌘,")
                    .keyboardShortcut(",", modifiers: .command)
                }

                // Blur quick-toggle - tap to toggle, clearly labelled
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.useBlurBackground.toggle()
                    }
                    Haptics.tap()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settings.useBlurBackground ? "sparkles" : "square.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(settings.useBlurBackground ? "Blur" : "Solid")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(settings.useBlurBackground ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(settings.useBlurBackground
                                ? Color.accentColor.opacity(0.1)
                                : Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            settings.useBlurBackground
                            ? Color.accentColor.opacity(0.2)
                            : Color(.separatorColor).opacity(0.5),
                            lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .hoverHaptic()
                .help("Toggle frosted glass background")

                // GitHub link - always visible
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/0x1p0/yoink")!)
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .hoverHaptic()
                .help("View source on GitHub")

                ThemePicker()
            }
            .padding(.trailing, 16)
        }
        .frame(height: 44)
        .background(.ultraThinMaterial)
    }
}

struct ModeToggle: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        settings.appModeRaw = mode.rawValue
                    }
                    Haptics.tap()
                } label: {
                    Text(mode.shortLabel)
                        .font(.system(size: 11.5,
                                      weight: settings.appMode == mode ? .semibold : .regular))
                        .foregroundStyle(settings.appMode == mode
                                         ? Color.primary
                                         : Color.secondary.opacity(0.7))
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(settings.appMode == mode
                                      ? Color(.controlBackgroundColor).opacity(0.9)
                                      : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .hoverHaptic()
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                        .fill(hovered ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                        .frame(width: 36, height: 36)
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.38))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add URL to download")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovered ? Color.accentColor : Color.secondary.opacity(0.55))
                    Text("Paste a YouTube, Twitch, Vimeo or any site URL   ·   ⌘N")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary.opacity(0.30))
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(hovered
                        ? Color.accentColor.opacity(0.45)
                        : Color(.separatorColor).opacity(0.35))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.hoverHaptic()
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: hovered)
        .keyboardShortcut("n", modifiers: .command)
    }
}

// MARK: - Bottom Toolbar

struct BottomToolbar: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager
    @State private var showFfmpegSheet  = false
    @State private var showYtdlpSheet   = false
    @State private var importToast: String? = nil   // brief "X URLs imported" message

    var body: some View {
        HStack(spacing: 10) {
            DepPill(label: "ffmpeg", status: deps.ffmpeg) { showFfmpegSheet = true }
            DepPill(label: "yt-dlp", status: deps.ytdlp) { showYtdlpSheet  = true }

            Divider().frame(height: 16).opacity(0.35)

            // Download location - NSOpenPanel avoids NSRendezvousSheetDelegate crash
            OutputFolderButton(directory: queue.outputDirectory, action: { pickOutputFolder() })

            CategoryPicker()
                .environmentObject(settings)
                .environmentObject(queue)

            // Batch .txt import button
            Button {
                importURLsFromFile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text(importToast ?? "Import URLs")
                        .font(.system(size: 12))
                }
                .foregroundStyle(importToast != nil ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Import a .txt file of URLs (one per line)")
            .animation(.easeOut(duration: 0.2), value: importToast)

            Spacer()

            if queue.jobs.contains(where: { $0.status.isTerminal }) {
                Button("Clear done") { queue.clearCompleted() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if queue.jobs.contains(where: { if case .failed = $0.status { return true }; return false }) {
                Button {
                    queue.retryFailed()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        Text("Retry failed").font(.system(size: 12))
                    }
                    .foregroundStyle(.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Re-queue all failed downloads")
            }

            Button {
                queue.downloadAll()
            } label: {
                Label("Download all", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
            .hoverHaptic()
            .disabled(!queue.jobs.contains { $0.hasURL && !$0.status.isActive })
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showFfmpegSheet) { DepSheet(tool: "ffmpeg").environmentObject(deps) }
        .sheet(isPresented: $showYtdlpSheet)  { DepSheet(tool: "yt-dlp").environmentObject(deps) }
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
                    .foregroundStyle(Color.accentColor.opacity(0.8))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Save to")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(directory.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                }

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovered ? Color.accentColor.opacity(0.3) : Color(.separatorColor).opacity(0.7), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.hoverHaptic()
        .help(directory.path)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Theme Picker

struct ThemePicker: View {
    @EnvironmentObject var theme: ThemeManager
    @State private var hovered = false
    var body: some View {
        Menu {
            ForEach(AppTheme.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { theme.set(t) }
                    Haptics.tap()
                } label: {
                    Label(t.rawValue, systemImage: t.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: theme.current.icon).font(.system(size: 11))
                Text(theme.current.rawValue).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(height: 28)
            .background(.primary.opacity(hovered ? 0.07 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(.separatorColor).opacity(0.6), lineWidth: 0.5))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.hoverHaptic().help("Switch theme")
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
                    .shadow(color: status.dotColor.opacity(0.5), radius: 3)
                    .opacity(isAnimating ? (animDot ? 0.2 : 1.0) : 1.0)
                    .animation(isAnimating ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .default, value: animDot)
                Text(label).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary.opacity(0.65))
                if let v = status.version {
                    Text(v).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(.primary.opacity(hovered ? 0.07 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(.separatorColor).opacity(0.7), lineWidth: 0.5))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.hoverHaptic()
        .onAppear { if isAnimating { animDot = true } }
        .onChange(of: isAnimating) { animDot = $0 }
        .help(status.statusLabel)
    }
}

// MARK: - Primary Button Style

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? .white : .secondary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(enabled ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1.0) : Color.primary.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

