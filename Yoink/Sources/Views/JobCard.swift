import SwiftUI

// MARK: - Job Card
//
// One card per link. The top row is always the same: status, link, a "…" menu for
// the less common actions, the primary Download/Pause/Reveal button, and remove.
// Options are only shown while they can still change the download; once it starts,
// the card collapses to a progress line.

struct JobCard: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var theme: ThemeManager
    var onPlaylistDetected: (() -> Void)? = nil
    @State private var showCookies        = false
    @State private var hovered            = false
    @State private var dismissedDuplicate = false
    @State private var showSchedule       = false
    @State private var showLog            = false

    /// Check if this URL was already downloaded
    private var duplicateEntry: HistoryEntry? {
        guard job.hasURL && !dismissedDuplicate && job.status == .idle else { return nil }
        return HistoryStore.shared.existingEntry(for: job.url)
    }

    private var showsProgress: Bool {
        job.status.isActive || job.status.isPaused || job.status.isDone
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.leading, 14).padding(.trailing, 12)
                .padding(.vertical, 11)

            if showsProgress && job.meta == nil {
                progressSection
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.opacity)
            }

            if let dup = duplicateEntry {
                DuplicateWarningBanner(
                    entry: dup,
                    onDismiss: { dismissedDuplicate = true },
                    onReveal:  { dismissedDuplicate = true },
                    onRemove:  { queue.remove(job) }
                )
                .padding(.horizontal, 14).padding(.bottom, 12)
            }

            if job.hasURL {
                Group {
                    switch job.metaState {
                    case .fetching:
                        cardDivider
                        MetadataSkeletonView()
                            .transition(.opacity)
                    case .needsAuth, .needsAuthRetry:
                        cardDivider
                        AuthNudgeBanner(job: job, cookiesFailed: job.metaState == .needsAuthRetry)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .transition(.opacity)
                    case .done, .idle:
                        if job.meta != nil || job.isEditable {
                            cardDivider
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            if let meta = job.meta {
                                MetadataHeaderView(meta: meta, job: job)
                            }
                            if showsProgress && job.meta != nil {
                                progressSection
                                    .transition(.opacity)
                            }
                            if job.isEditable {
                                JobOptionsPanel(job: job)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, (job.meta != nil || job.isEditable) ? 14 : 0)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: job.metaState)
            }

            if job.isFailed {
                failureFooter
            }
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if #available(macOS 26.0, *) {
                shape
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(hovered ? 0.12 : 0.06), radius: hovered ? 12 : 6, y: 3)
                    .overlay { shape.strokeBorder(borderColor, lineWidth: 0.5) }
            } else {
                shape
                    .fill(theme.cardFill)
                    .shadow(color: theme.cardShadow.opacity(hovered ? 0.10 : 0.05), radius: hovered ? 10 : 5, y: 2)
                    .overlay { shape.strokeBorder(borderColor, lineWidth: 0.5) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .modifier(JobCardGlassModifier(hovered: hovered))
        .animation(.easeOut(duration: 0.18), value: hovered)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: job.isEditable)
        .onHover { hovered = $0 }
        .sheet(isPresented: $showCookies) {
            CookiesSheet(job: job)
                .onDisappear { DownloadService.shared.refetchMetadata(for: job) }
        }
        .sheet(isPresented: $showSchedule) {
            ScheduleSheet(url: job.url,
                          title: job.meta?.title ?? "",
                          thumbnail: job.meta?.thumbnail ?? "",
                          format: job.format)
        }
        .sheet(isPresented: $showLog) { FullLogSheet(log: job.log) }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: job.hasURL)
    }

    private var borderColor: Color {
        if job.isFailed { return Color.red.opacity(0.35) }
        if hovered { return Color.accentColor.opacity(0.25) }
        return Color(.separatorColor).opacity(0.35)
    }

    private var cardDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 10) {
            StatusIndicator(job: job)
            URLInputField(job: job)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if job.hasURL { moreMenu }
                if job.status.isActive || job.status.isPaused {
                    IconButton(systemImage: "stop.fill", tint: .red, tooltip: "Cancel Download") {
                        job.cancel()
                        Haptics.tap()
                    }
                }
                DownloadButton(job: job)
                if job.status.isDone || job.status == .cancelled || queue.jobs.count > 1 || job.hasURL {
                    IconButton(systemImage: "xmark", tint: nil,
                               tooltip: job.status.isTerminal ? "Dismiss" : "Remove") {
                        removeOrReset()
                    }
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if job.status == .idle {
                Button {
                    WatchLaterStore.shared.add(url: job.url,
                        title: job.meta?.title ?? "",
                        thumbnail: job.meta?.thumbnail ?? "",
                        format: job.format,
                        isPlaylist: DownloadJob.looksLikePlaylist(job.url) && !DownloadService.isSoopOrAfreecaURL(job.url))
                    queue.remove(job)
                } label: { Label("Save to Watch Later", systemImage: "bookmark") }
                Button { showSchedule = true } label: { Label("Schedule Download…", systemImage: "alarm") }
                Divider()
            }
            if case .done(let url) = job.status {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open", systemImage: "play.rectangle") }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                Divider()
            }
            Button { showCookies = true } label: {
                Label(job.hasCookies ? "Edit Sign-in Cookies…" : "Add Sign-in Cookies…",
                      systemImage: job.hasCookies ? "key.fill" : "key")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.url, forType: .string)
            } label: { Label("Copy Link", systemImage: "link") }
            if !job.log.isEmpty {
                Button { showLog = true } label: { Label("Show Log", systemImage: "doc.text.magnifyingglass") }
            }
        } label: {
            Image(systemName: job.hasCookies ? "ellipsis.circle.fill" : "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(job.hasCookies ? Color.orange : Color.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .compactMenuStyle()
        .help(job.hasCookies ? "More (sign-in cookies added)" : "More")
    }

    private func removeOrReset() {
        if queue.jobs.count > 1 || job.hasURL {
            queue.remove(job)
        } else {
            job.reset()
            job.url = ""
            job.meta = nil
            job.metaState = .idle
            job.thumbnailLoaded = false
            job.selectedVideoFormatId = ""
            job.selectedAudioFormatId = ""
        }
    }

    // MARK: Progress

    private var progressTint: Color {
        switch job.status {
        case .done:    return .green
        case .paused:  return .orange
        case .merging: return .purple
        default:       return .accentColor
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThinProgressBar(progress: job.status.progress, tint: progressTint, height: 4)
            HStack(spacing: 8) {
                Text(job.statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(job.status.isDone ? Color.green : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 8)
                if job.status.isActive, let size = job.sizeLabel {
                    Text(size)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                if job.status.isActive && job.speedHistory.count > 2 {
                    SpeedSparkline(samples: job.speedHistory)
                }
            }
        }
    }

    // MARK: Failure

    private var failureFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(.top, 1)
            Text(failureMessage)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if !job.log.isEmpty {
                Button("Show Log") { showLog = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.red.opacity(0.06))
    }

    private var failureMessage: String {
        if case .failed(let msg) = job.status {
            let m = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty { return m }
        }
        if let err = job.log.last(where: { $0.kind == .error })?.text { return err }
        return "The download didn't finish. Try again, or check the log for details."
    }
}

// Liquid Glass for job cards — applied on the card content, not a detached background shape
struct JobCardGlassModifier: ViewModifier {
    let hovered: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.interactive(hovered),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        } else {
            content
        }
    }
}

// MARK: - Metadata Header (thumbnail + title + duration)

struct MetadataHeaderView: View {
    let meta: VideoMeta
    @ObservedObject var job: DownloadJob

    var body: some View {
        HStack(spacing: 14) {
            if !meta.thumbnail.isEmpty {
                CachedThumb(
                    urlString: meta.thumbnail, width: 112, height: 63, radius: 8,
                    placeholder: AnyView(
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07))
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    )
                )
                .overlay(alignment: .bottomTrailing) {
                    if !meta.duration.isEmpty {
                        Text(meta.duration)
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.7)))
                            .padding(4)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(meta.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(YoinkFormat.host(job.url))
                    if meta.thumbnail.isEmpty && !meta.duration.isEmpty {
                        Text("·")
                        Text(meta.duration).monospacedDigit()
                    }
                    if !meta.chapters.isEmpty {
                        Text("·")
                        Text("\(meta.chapters.count) chapters")
                    }
                    if meta.hasSubs || !meta.availableSubLangs.isEmpty {
                        Text("·")
                        Text("Subtitles")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Skeleton shimmer while fetching metadata

struct MetadataSkeletonView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Fake metadata row
            HStack(spacing: 12) {
                ShimmerRect(width: 100, height: 58, radius: 6)
                VStack(alignment: .leading, spacing: 8) {
                    ShimmerRect(width: 220, height: 13, radius: 4)
                    ShimmerRect(width: 120, height: 11, radius: 4)
                }
                Spacer()
            }

            // Fake format row
            HStack(spacing: 0) {
                ShimmerRect(width: 80, height: 11, radius: 4)
                Spacer().frame(width: 12)
                ShimmerRect(width: 160, height: 28, radius: 7)
                Spacer()
            }

            HStack(spacing: 8) {
                RotatingIcon()
                Text("Gathering video details…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

struct RotatingIcon: View {
    @State private var angle: Double = 0
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11))
            .foregroundStyle(Color.secondary.opacity(0.5))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

struct ShimmerRect: View {
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    @State private var animating = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(animating ? 0.05 : 0.1))
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: animating)
            .onAppear { animating = true }
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    @ObservedObject var job: DownloadJob
    @State private var pulsing = false
    var body: some View {
        ZStack {
            if job.status.isActive {
                Circle().fill(job.status.accentColor.opacity(0.2)).frame(width: 20)
                    .scaleEffect(pulsing ? 1.6 : 1.0).opacity(pulsing ? 0 : 1)
                    .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulsing)
            }
            Circle().fill(job.status.accentColor).frame(width: 8)
                .shadow(color: job.status.accentColor.opacity(0.5), radius: 4)
        }
        .frame(width: 22)
        .onAppear { pulsing = job.status.isActive }
        .onChange(of: job.status.isActive) { pulsing = $0 }
    }
}

// MARK: - URL Input

struct URLInputField: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var queue: DownloadQueue
    @FocusState private var focused: Bool
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var urlUnsupported: Bool = false   // true when yt-dlp doesn't know this site

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: YoinkFormat.siteSymbol(job.url))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(job.hasURL ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: 16)
                .animation(.easeOut(duration: 0.15), value: job.hasURL)
            TextField("", text: $job.url,
                      prompt: Text("Paste a link — YouTube, Twitch, Vimeo, SoundCloud and 1000+ more"))
                .textFieldStyle(.plain).font(.system(size: 13.5))
                .disabled(!job.isEditable)
                .focused($focused)
                .onReceive(NotificationCenter.default.publisher(for: .focusJobURLField)) { note in
                    guard (note.object as? UUID) == job.id else { return }
                    DispatchQueue.main.async { focused = true }
                }
                .onAppear {
                    // When a new card is created with a URL already set (e.g. ⌘N then paste,
                    // or programmatic addJob(url:)), onChange never fires because the value
                    // was set before this view mounted. Kick off fetch here if needed.
                    let url = job.url.trimmingCharacters(in: .whitespaces)
                    guard url.lowercased().hasPrefix("http"),
                          job.metaState == .idle, job.meta == nil else { return }
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            if DownloadJob.looksLikePlaylist(url) && !DownloadService.isSoopOrAfreecaURL(url) {
                                NotificationCenter.default.post(name: .playlistURLDetected, object: job)
                            } else {
                                DownloadService.shared.fetchMetadata(for: job)
                            }
                        }
                    }
                }
                .onChange(of: job.url) { newURL in
                    // Batch paste: if user pastes multiple newline-separated URLs, distribute them
                    let lines = newURL.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.lowercased().hasPrefix("http") }
                    if lines.count > 1 {
                        job.url = lines[0]
                        let extras = Array(lines.dropFirst())
                        DispatchQueue.main.async { queue.addBatchURLs(extras) }
                        return
                    }
                    debounceTask?.cancel()
                    job.meta = nil
                    job.metaState = .idle
                    job.thumbnailLoaded = false
                    job.endH = ""; job.endM = ""; job.endS = ""
                    urlUnsupported = false
                    guard newURL.lowercased().hasPrefix("http") else { return }
                    debounceTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            urlUnsupported = false
                            if DownloadJob.looksLikePlaylist(newURL) && !DownloadService.isSoopOrAfreecaURL(newURL) {
                                NotificationCenter.default.post(name: .playlistURLDetected, object: job)
                            } else {
                                DownloadService.shared.fetchMetadata(for: job)
                            }
                        }
                    }
                }
            if urlUnsupported {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("Unsupported site")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.orange.opacity(0.1))
                .clipShape(Capsule())
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Real Format Picker (video + audio track menus)

struct RealFormatPicker: View {
    @ObservedObject var job: DownloadJob
    let meta: VideoMeta
    /// Audio-only mode shows just the audio track menu.
    var audioOnly: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if !audioOnly { videoMenu }
            audioMenu
        }
    }

    private var videoTitle: String {
        if job.selectedVideoFormatId.isEmpty || job.selectedVideoFormatId == "audio" {
            if let h = meta.videoFormats.first?.height { return "Best · \(h)p" }
            return "Best"
        }
        if let f = meta.videoFormats.first(where: { $0.id == job.selectedVideoFormatId }) {
            var s = f.height.map { "\($0)p" } ?? f.id
            if let fps = f.fps, fps > 30 { s += "\(Int(fps))" }
            return s + " · " + f.ext.uppercased()
        }
        return "Best"
    }

    private var audioTitle: String {
        if job.selectedAudioFormatId.isEmpty {
            if let a = meta.audioFormats.first { return "Best audio · \(a.acodec.uppercased())" }
            return "Best audio"
        }
        if let f = meta.audioFormats.first(where: { $0.id == job.selectedAudioFormatId }) {
            return (f.abr.map { "\(Int($0)) kbps" } ?? f.id) + " · " + f.acodec.uppercased()
        }
        return "Best audio"
    }

    private var videoMenu: some View {
        Menu {
            Button { job.selectedVideoFormatId = "" } label: {
                checkLabel("Best Available", job.selectedVideoFormatId.isEmpty)
            }
            Divider()
            ForEach(meta.videoFormats) { fmt in
                Button { job.selectedVideoFormatId = fmt.id } label: {
                    checkLabel(fmt.label, job.selectedVideoFormatId == fmt.id)
                }
            }
        } label: {
            CompactMenuLabel(title: videoTitle, icon: "film")
        }
        .compactMenuStyle()
        .help("Video quality")
    }

    private var audioMenu: some View {
        Menu {
            Button { job.selectedAudioFormatId = "" } label: {
                checkLabel("Best Available", job.selectedAudioFormatId.isEmpty)
            }
            if !meta.audioFormats.isEmpty { Divider() }
            ForEach(meta.audioFormats) { fmt in
                Button { job.selectedAudioFormatId = fmt.id } label: {
                    checkLabel(fmt.label, job.selectedAudioFormatId == fmt.id)
                }
            }
        } label: {
            CompactMenuLabel(title: audioTitle, icon: "waveform")
        }
        .compactMenuStyle()
        .help("Audio track")
    }

    @ViewBuilder
    private func checkLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Options Panel

struct JobOptionsPanel: View {
    @ObservedObject var job: DownloadJob

    private var isAudioOnly: Bool { job.selectedVideoFormatId == "audio" || job.format.isAudio }
    private var sponsorOn: Bool { job.sponsorBlockOverride ?? SettingsManager.shared.sponsorBlock }

    private var audioBinding: Binding<Bool> {
        Binding(
            get: { isAudioOnly },
            set: { on in
                guard on != isAudioOnly else { return }
                if on {
                    if job.meta?.videoFormats.isEmpty == false {
                        job.selectedVideoFormatId = "audio"
                        job.selectedAudioFormatId = ""
                    } else {
                        job.format = .audioBest
                    }
                } else {
                    job.selectedVideoFormatId = ""
                    job.selectedAudioFormatId = ""
                    job.format = .best
                }
                Haptics.tap()
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1 — what to download
            HStack(spacing: 10) {
                Picker("", selection: audioBinding) {
                    Text("Video").tag(false)
                    Text("Audio").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)

                formatControls
                Spacer(minLength: 0)
            }

            // Row 2 — extras, off by default
            HStack(spacing: 6) {
                OptionChip(title: "Subtitles", icon: "captions.bubble", isOn: job.downloadSubs,
                           help: "Download subtitles alongside the video") {
                    job.downloadSubs.toggle()
                }
                OptionChip(title: "Skip Sponsors", icon: "forward.end", isOn: sponsorOn,
                           help: job.sponsorBlockOverride == nil
                               ? "Cut sponsor segments with SponsorBlock (following your default)"
                               : "Cut sponsor segments with SponsorBlock") {
                    job.sponsorBlockOverride = !sponsorOn
                }
                OptionChip(title: "Clip", icon: "scissors", isOn: job.useSegment,
                           help: "Download only part of the video") {
                    job.useSegment.toggle()
                }
                if job.sponsorBlockOverride != nil && job.sponsorBlockOverride != SettingsManager.shared.sponsorBlock {
                    Text("Overrides your default")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }

            if job.downloadSubs {
                subtitleRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if job.useSegment {
                SegmentEditor(job: job)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: job.downloadSubs)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: job.useSegment)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isAudioOnly)
    }

    @ViewBuilder
    private var formatControls: some View {
        if job.isTwitchURL && !job.twitchQualities.isEmpty && !isAudioOnly {
            // Twitch: real qualities fetched from the M3U8 (Source, 1080p60, 720p30…)
            Menu {
                ForEach(job.twitchQualities) { q in
                    Button { job.selectedTwitchQuality = q } label: {
                        let current = job.selectedTwitchQuality?.id ?? job.twitchQualities.first?.id
                        if current == q.id { Label(q.displayName, systemImage: "checkmark") } else { Text(q.displayName) }
                    }
                }
            } label: {
                CompactMenuLabel(title: (job.selectedTwitchQuality ?? job.twitchQualities.first)?.displayName ?? "Source",
                                 icon: "film")
            }
            .compactMenuStyle()
            .help("Stream quality")
        } else if let meta = job.meta, !meta.videoFormats.isEmpty || (isAudioOnly && !meta.audioFormats.isEmpty) {
            RealFormatPicker(job: job, meta: meta, audioOnly: isAudioOnly)
        } else {
            // No format list (still loading, or the site doesn't expose one)
            Menu {
                ForEach(DownloadFormat.allCases.filter { $0.isAudio == isAudioOnly }) { fmt in
                    Button { job.format = fmt } label: {
                        if job.format == fmt { Label(fmt.displayName, systemImage: "checkmark") } else { Text(fmt.displayName) }
                    }
                }
            } label: {
                CompactMenuLabel(title: job.format.displayName, icon: isAudioOnly ? "waveform" : "film")
            }
            .compactMenuStyle()
            .help("Format")
        }
    }

    private var subtitleRow: some View {
        HStack(spacing: 8) {
            Text("Subtitle language")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if let langs = job.meta?.availableSubLangs, !langs.isEmpty {
                Menu {
                    ForEach(langs, id: \.self) { lang in
                        Button { job.subLang = lang } label: {
                            if job.subLang == lang { Label(lang, systemImage: "checkmark") } else { Text(lang) }
                        }
                    }
                } label: {
                    CompactMenuLabel(title: job.subLang.isEmpty ? (langs.first ?? "?") : job.subLang, monospaced: true)
                }
                .compactMenuStyle()
                .onAppear { pickLanguage(langs) }
                .onChange(of: langs) { pickLanguage($0) }
                Text("\(langs.count) available")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else if job.metaState == .fetching {
                ProgressView().controlSize(.small)
            } else {
                Text("\(job.subLang.isEmpty ? "en" : job.subLang) · used if the video has it")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func pickLanguage(_ langs: [String]) {
        DispatchQueue.main.async {
            guard job.subLang.isEmpty || !langs.contains(job.subLang) else { return }
            let preferred = SettingsManager.shared.defaultSubLang
            job.subLang = langs.contains(preferred) ? preferred : (langs.first ?? "")
        }
    }
}

// MARK: - Segment Editor (clip by time or by chapter)

struct SegmentEditor: View {
    @ObservedObject var job: DownloadJob

    private var chapters: [VideoChapter] { job.meta?.chapters ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chapters.isEmpty {
                Picker("", selection: Binding(
                    get: { job.segmentMode == .chapters },
                    set: { job.segmentMode = $0 ? .chapters : .manual; Haptics.tap() }
                )) {
                    Text("Time Range").tag(false)
                    Text("Chapters").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            if job.segmentMode == .manual || chapters.isEmpty {
                manualRange
                if !chapters.isEmpty { chapterJumps }
            } else {
                chapterPicker
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private var manualRange: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Start").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                HMSInput(hours: $job.startH, minutes: $job.startM, seconds: $job.startS)
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 9)
            VStack(alignment: .leading, spacing: 5) {
                Text("End").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                HMSInput(hours: $job.endH, minutes: $job.endM, seconds: $job.endS,
                         placeholders: job.videoDurationHMS)
            }
            if let meta = job.meta, !meta.duration.isEmpty {
                Text("of \(meta.duration)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 9)
            }
            Spacer(minLength: 0)
        }
    }

    private var chapterJumps: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fill from a chapter")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(chapters) { ch in
                        Button {
                            job.startH = ch.startTime >= 3600 ? String(format: "%02d", ch.startTime/3600) : ""
                            job.startM = String(format: "%02d", (ch.startTime%3600)/60)
                            job.startS = String(format: "%02d", ch.startTime%60)
                            job.endH   = ch.endTime >= 3600   ? String(format: "%02d", ch.endTime/3600)   : ""
                            job.endM   = String(format: "%02d", (ch.endTime%3600)/60)
                            job.endS   = String(format: "%02d", ch.endTime%60)
                            Haptics.toggleOn()
                        } label: {
                            HStack(spacing: 4) {
                                Text(ch.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(ch.duration).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var chapterPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(job.selectedChapters.count) of \(chapters.count) chapters")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if chapters.count > 1 {
                    let allSel = job.selectedChapters.count == chapters.count
                    Button(allSel ? "Select None" : "Select All") {
                        if allSel { job.selectedChapters.removeAll() }
                        else { job.selectedChapters = Set(chapters.map(\.id)) }
                        Haptics.tap()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
            }
            VStack(spacing: 1) {
                ForEach(chapters) { ch in
                    let sel = job.selectedChapters.contains(ch.id)
                    Button {
                        if sel { job.selectedChapters.remove(ch.id) } else { job.selectedChapters.insert(ch.id) }
                        sel ? Haptics.toggleOff() : Haptics.toggleOn()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(sel ? Color.accentColor : Color.secondary.opacity(0.5))
                            Text(ch.title)
                                .font(.system(size: 12))
                                .foregroundStyle(sel ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(ch.startHMS)
                                .font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(.tertiary)
                            Text(ch.duration)
                                .font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Color.accentColor.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - HMS Input

struct HMSInput: View {
    @Binding var hours: String; @Binding var minutes: String; @Binding var seconds: String
    var placeholders: (h: String, m: String, s: String) = ("00","00","00")
    var body: some View {
        HStack(spacing: 2) {
            TimeBox(text: $hours,   placeholder: placeholders.h, maxVal: 99)
            colon
            TimeBox(text: $minutes, placeholder: placeholders.m, maxVal: 59)
            colon
            TimeBox(text: $seconds, placeholder: placeholders.s, maxVal: 59)
        }
    }
    var colon: some View {
        Text(":").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
    }
}

struct TimeBox: View {
    @Binding var text: String; let placeholder: String; let maxVal: Int
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.center).frame(width: 38, height: 32)
            .background(focused ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.45) : Color(.separatorColor).opacity(0.6), lineWidth: 0.5))
            .focused($focused)
            .onChange(of: text) { v in
                let d = String(v.filter(\.isNumber).prefix(2))
                if let n = Int(d), n > maxVal { text = String(maxVal) } else { text = d }
            }
            // Scroll-wheel: two-finger scroll up/down increments the value
            .background(ScrollWheelReceiver { delta in
                let cur = Int(text) ?? 0
                let next = min(maxVal, max(0, cur + (delta > 0 ? 1 : -1)))
                if next != cur {
                    text = String(format: "%02d", next)
                    Haptics.tick()
                }
            })
    }
}

// Invisible NSView that captures scroll wheel events and calls back
struct ScrollWheelReceiver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> ScrollWheelView {
        let v = ScrollWheelView(); v.onScroll = onScroll; return v
    }
    func updateNSView(_ v: ScrollWheelView, context: Context) { v.onScroll = onScroll }
    class ScrollWheelView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        override var acceptsFirstResponder: Bool { false }
        override func scrollWheel(with event: NSEvent) {
            let d = event.scrollingDeltaY
            if abs(d) > 0.5 { onScroll?(d) }
            else { super.scrollWheel(with: event) }
        }
    }
}

struct NumberBox: View {
    @Binding var text: String; let placeholder: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .multilineTextAlignment(.center).frame(width: 52, height: 32)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color(.separatorColor).opacity(0.6), lineWidth: 0.5))
            .onChange(of: text) { v in text = String(v.filter(\.isNumber).prefix(4)) }
            .background(ScrollWheelReceiver { delta in
                let cur = max(1, Int(text) ?? 1)
                let next = max(1, cur + (delta > 0 ? 1 : -1))
                if next != cur { text = String(next); Haptics.tap() }
            })
    }
}

// MARK: - Speed Sparkline

struct SpeedSparkline: View {
    let samples: [Double]   // KB/s values
    private let barCount = 20

    var trimmed: [Double] {
        let s = samples.suffix(barCount)
        return Array(s)
    }
    var peak: Double { trimmed.max() ?? 1 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(trimmed.enumerated()), id: \.offset) { _, val in
                let ratio = peak > 0 ? val / peak : 0
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.5 + ratio * 0.5))
                    .frame(width: 2.5, height: max(2, 16 * ratio))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.4), value: samples.count)
    }
}

struct SlimToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.13))
                .frame(width: 34, height: 19)
                .overlay(Circle().fill(.white).frame(width: 15).shadow(radius: 1.5, y: 0.5)
                    .offset(x: configuration.isOn ? 7.5 : -7.5)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isOn))
                .onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}

// MARK: - Auth Nudge Banner

struct AuthNudgeBanner: View {
    @ObservedObject var job: DownloadJob
    var cookiesFailed: Bool = false
    @State private var showCookies = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cookiesFailed ? "lock.trianglebadge.exclamationmark.fill" : "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(cookiesFailed ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(cookiesFailed ? "Cookies not working" : "Authentication required")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary.opacity(0.8))
                Text(cookiesFailed
                     ? "The provided cookies didn't grant access. Try updating them."
                     : "This video is private or restricted. Add cookies to continue.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(cookiesFailed ? "Update cookies" : "Add cookies") { showCookies = true }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(cookiesFailed ? .red : .orange)
                .padding(.horizontal, 10).frame(height: 26)
                .background((cookiesFailed ? Color.red : Color.orange).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((cookiesFailed ? Color.red : Color.orange).opacity(0.25), lineWidth: 0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background((cookiesFailed ? Color.red : Color.orange).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder((cookiesFailed ? Color.red : Color.orange).opacity(0.18), lineWidth: 0.5))
        .sheet(isPresented: $showCookies) {
            CookiesSheet(job: job)
                .onDisappear { DownloadService.shared.refetchMetadata(for: job) }
        }
    }
}

// MARK: - Full Log Sheet

struct FullLogSheet: View {
    let log: [LogLine]
    @Environment(\.dismiss) private var dismiss
    @State private var copyFlash = false
    @State private var search = ""

    var filtered: [LogLine] {
        guard !search.isEmpty else { return log }
        return log.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Download Log")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(log.count) lines")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Filter…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 140)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))

                Button {
                    let text = log.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copyFlash = true
                    Haptics.success()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyFlash = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copyFlash ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copyFlash ? "Copied!" : "Copy All")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(copyFlash ? .green : Color.accentColor)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(copyFlash ? Color.green.opacity(0.1) : Color.accentColor.opacity(0.09))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.15), value: copyFlash)

                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Color(.windowBackgroundColor).opacity(0.6))

            Divider().opacity(0.5)

            // Log lines
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, line in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(minWidth: 32, alignment: .trailing)
                                Text(line.text)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(fullLogColor(line.kind))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let last = filtered.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color.primary.opacity(0.03))
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }

    func fullLogColor(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .command:  return .secondary.opacity(0.5)
        case .info:     return .primary.opacity(0.75)
        case .progress: return Color.accentColor.opacity(0.9)
        case .success:  return .green
        case .warning:  return .orange
        case .error:    return Color(red: 0.85, green: 0.35, blue: 0.35)
        }
    }
}

// MARK: - Download Button with Progress Ring

struct DownloadButton: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var queue: DownloadQueue
    @State private var showMissingDepsAlert = false

    private let ringSize: CGFloat = 30
    private let ringStroke: CGFloat = 2.5

    var body: some View {
        Button {
            switch job.status {
            case .downloading, .fetching, .merging:
                job.pause()
                Haptics.tap()
            case .paused:
                job.resume()
                Haptics.tap()
            case .failed:
                Haptics.start()
                job.retryCount += 1
                job.reset(); queue.ensureOutputDir()
                DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
            case .done(let url):
                Haptics.tap()
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
            default:
                let deps = DependencyService.shared
                guard deps.ytdlp.isReady && deps.ffmpeg.isReady else {
                    showMissingDepsAlert = true
                    return
                }
                Haptics.tap()
                queue.ensureOutputDir()
                DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
            }
        } label: {
            let progress = job.status.progress
            let isActive = job.status.isActive || job.status.isPaused
            let showRing = isActive && progress > 0

                ZStack {
                    // Background pill (shown when NOT showing ring)
                    if !showRing {
                        HStack(spacing: 5) {
                            Image(systemName: btnIcon).font(.system(size: 10, weight: .semibold))
                            Text(btnLabel).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(btnFg)
                        .padding(.horizontal, 13).frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .background {
                            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                            if #available(macOS 26.0, *), !isPrimary {
                                shape.fill(btnBg)
                                    .overlay {
                                        shape.strokeBorder(btnBorder, lineWidth: 0.5)
                                    }
                                    .glassEffect(.regular.interactive(), in: shape)
                                    .allowsHitTesting(false)
                            } else {
                                shape.fill(btnBg)
                                    .overlay {
                                        shape.strokeBorder(btnBorder, lineWidth: 0.5)
                                    }
                                    .allowsHitTesting(false)
                            }
                        }
                    } else {
                    // Progress ring with icon in centre
                    ZStack {
                        // Track
                        Circle()
                            .stroke(ringTrackColor, lineWidth: ringStroke)
                            .frame(width: ringSize, height: ringSize)
                        // Fill arc
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                ringFillColor,
                                style: StrokeStyle(lineWidth: ringStroke, lineCap: .round)
                            )
                            .frame(width: ringSize, height: ringSize)
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
                        // Icon
                        Image(systemName: btnIcon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(ringFillColor)
                    }
                    .frame(width: ringSize + 8, height: ringSize + 8)
                }
            }
        }
        .buttonStyle(RingAwareButtonStyle(showingRing: job.status.progress > 0 && (job.status.isActive || job.status.isPaused)))
        .disabled(!job.hasURL && !job.status.isActive)
        .alert("Dependencies Not Ready", isPresented: $showMissingDepsAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("yt-dlp and ffmpeg are still initialising. Please wait a moment and try again.")
        }
    }

    var btnIcon: String {
        switch job.status {
        case .idle, .cancelled:         return "arrow.down"
        case .fetching:                 return "ellipsis"
        case .downloading, .merging:    return "pause.fill"
        case .paused:                   return "play.fill"
        case .done:                     return "magnifyingglass"
        case .failed:                   return "arrow.counterclockwise"
        }
    }
    var btnLabel: String {
        switch job.status {
        case .idle, .cancelled:         return "Download"
        case .fetching:                 return "Fetching…"
        case .downloading(let p):       return "\(Int(p*100))%"
        case .paused(let p):            return "\(Int(p*100))%"
        case .merging:                  return "Merging…"
        case .done:                     return "Show File"
        case .failed:                   return job.retryCount > 0 ? "Retry (\(job.retryCount))" : "Retry"
        }
    }
    /// Ready to start: the one accent-filled control on the card.
    private var isPrimary: Bool {
        (job.status == .idle || job.status == .cancelled) && job.hasURL
    }
    var btnFg: Color {
        if isPrimary { return .white }
        switch job.status {
        case .done:    return .green
        case .failed:  return .red
        case .fetching, .merging: return .secondary
        default:       return .primary.opacity(0.6)
        }
    }
    var btnBg: Color {
        if isPrimary { return .accentColor }
        switch job.status {
        case .done:   return .green.opacity(0.1)
        case .failed: return .red.opacity(0.08)
        default:      return .primary.opacity(0.06)
        }
    }
    var btnBorder: Color {
        if isPrimary { return .clear }
        switch job.status {
        case .done:   return .green.opacity(0.25)
        case .failed: return .red.opacity(0.2)
        default:      return Color(.separatorColor).opacity(0.6)
        }
    }
    var ringTrackColor: Color { Color.primary.opacity(0.08) }
    var ringFillColor: Color {
        if job.status.isPaused { return .orange }
        return Color.accentColor
    }
}

struct RingAwareButtonStyle: ButtonStyle {
    let showingRing: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? (showingRing ? 0.9 : 0.97) : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let systemImage: String; let tint: Color?; let tooltip: String
    var destructive: Bool = false; let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(fg)
                .frame(width: 30, height: 30)
                .background { buttonChrome }
                // Plain buttons only hit-test opaque pixels; make the whole square clickable,
                // not just the thin strokes of the glyph.
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.help(tooltip)
        .accessibilityLabel(tooltip)
        .modifier(IconButtonGlassOnLabel(hovered: hovered, enabled: tint == nil && !destructive))
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder
    private var buttonChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        shape
            .fill(bg)
            .overlay {
                shape.strokeBorder(
                    hovered ? Color(.separatorColor).opacity(0.9) : Color(.separatorColor).opacity(0.35),
                    lineWidth: 0.5
                )
            }
            .allowsHitTesting(false)
    }
    var fg: Color {
        if destructive { return hovered ? .red : .secondary.opacity(0.5) }
        if let tint    { return tint }
        return hovered ? .primary.opacity(0.85) : .secondary.opacity(0.55)
    }
    var bg: Color {
        if destructive && hovered { return .red.opacity(0.08) }
        if let tint               { return tint.opacity(hovered ? 0.16 : 0.10) }
        return .primary.opacity(hovered ? 0.07 : 0.04)
    }
}

private struct IconButtonGlassOnLabel: ViewModifier {
    let hovered: Bool
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), enabled {
            content.glassEffect(
                .regular.interactive(hovered),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        } else {
            content
        }
    }
}
