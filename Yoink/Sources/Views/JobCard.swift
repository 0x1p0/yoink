import SwiftUI

// MARK: - Job Card

struct JobCard: View {
    @ObservedObject var job: DownloadJob
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var theme: ThemeManager
    var onPlaylistDetected: (() -> Void)? = nil
    @State private var showCookies       = false
    @State private var hovered           = false
    @State private var dismissedDuplicate = false
    @State private var showSchedule      = false

    /// Check if this URL was already downloaded
    private var duplicateEntry: HistoryEntry? {
        guard job.hasURL && !dismissedDuplicate && job.status == .idle else { return nil }
        return HistoryStore.shared.existingEntry(for: job.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            // URL row
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovered ? 0.25 : 0.1))
                    .frame(width: 16)
                    .animation(.easeOut(duration: 0.15), value: hovered)
                StatusIndicator(job: job)
                URLInputField(job: job)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    // Save for later (only when idle and has URL)
                    if job.hasURL && job.status == .idle {
                        IconButton(systemImage: "bookmark", tint: nil, tooltip: "Save to Watch Later") {
                            WatchLaterStore.shared.add(url: job.url,
                                title: job.meta?.title ?? "",
                                thumbnail: job.meta?.thumbnail ?? "",
                                format: job.format,
                                isPlaylist: DownloadJob.looksLikePlaylist(job.url))
                            queue.remove(job)
                        }
                        IconButton(systemImage: "alarm", tint: nil, tooltip: "Schedule download") {
                            showSchedule = true
                        }
                    }
                    // Stop (cancel) button - shown when downloading or paused
                    if job.status.isActive || job.status.isPaused {
                        IconButton(systemImage: "stop.fill", tint: .red, tooltip: "Cancel download") {
                            job.cancel()
                            Haptics.tap()
                        }
                    }
                    IconButton(systemImage: job.hasCookies ? "key.fill" : "key",
                               tint: job.hasCookies ? .orange : nil,
                               tooltip: "Authentication & Cookies") { showCookies = true }
                    DownloadButton(job: job)
                    // Clear/dismiss: resets the card to blank when idle/active, removes when done/failed
                    if job.status.isDone || job.status == .cancelled || queue.jobs.count > 1 || job.hasURL {
                        IconButton(
                            systemImage: job.status.isTerminal ? "xmark.circle.fill" : "xmark",
                            tint: job.status.isTerminal ? .secondary : nil,
                            tooltip: job.status.isTerminal ? "Dismiss" : "Remove",
                            destructive: false
                        ) {
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
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            // Progress bar + size + sparkline
            if job.status.progress > 0 || job.status.isDone {
                VStack(spacing: 3) {
                    JobProgressBar(job: job)
                    HStack(spacing: 8) {
                        if let size = job.sizeLabel {
                            Text(size)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if job.status.isActive && job.speedHistory.count > 2 {
                            SpeedSparkline(samples: job.speedHistory)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Duplicate warning
            if let dup = duplicateEntry {
                Divider().opacity(0.06)
                DuplicateWarningBanner(
                    entry: dup,
                    onDismiss: { dismissedDuplicate = true },
                    onReveal:  { dismissedDuplicate = true },
                    onRemove:  { queue.remove(job) }
                )
                .padding(.horizontal, 16).padding(.vertical, 10)
            }

            // Content below URL
            if job.hasURL {
                Divider().opacity(0.07)
                Group {
                    switch job.metaState {
                    case .fetching:
                        MetadataSkeletonView()
                            .transition(.opacity)
                    case .needsAuth:
                        VStack(spacing: 0) {
                            AuthNudgeBanner(job: job, cookiesFailed: false)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                        .transition(.opacity)
                    case .needsAuthRetry:
                        VStack(spacing: 0) {
                            AuthNudgeBanner(job: job, cookiesFailed: true)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                        .transition(.opacity)
                    case .done, .idle:
                        VStack(spacing: 0) {
                            if let meta = job.meta {
                                MetadataHeaderView(meta: meta, job: job)
                                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                                Divider().opacity(0.07)
                            }
                            JobOptionsPanel(job: job)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: job.metaState)
            }

            // Log
            if !job.log.isEmpty && (job.status.isActive || job.status.isTerminal) {
                Divider().opacity(0.06)
                JobLogView(log: job.log)
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.cardFill)
                .shadow(color: theme.cardShadow.opacity(hovered ? 0.12 : 0.06),
                        radius: hovered ? 12 : 6, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(theme.cardBorder, lineWidth: 0.5))
        .onHover { hovered = $0 }
        .hoverHaptic()
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
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: job.hasURL)
    }
}

// MARK: - Metadata Header (thumbnail + title + duration)

struct MetadataHeaderView: View {
    let meta: VideoMeta
    @ObservedObject var job: DownloadJob
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if !meta.thumbnail.isEmpty {
                AsyncImage(url: URL(string: meta.thumbnail)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    default:
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                            .frame(width: 100, height: 58)
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: 100, height: 58)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.85))

                HStack(spacing: 8) {
                    if !meta.duration.isEmpty {
                        Label(meta.duration, systemImage: "clock")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if meta.hasSubs {
                        Label("Subtitles", systemImage: "captions.bubble")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
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
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var urlUnsupported: Bool = false   // true when yt-dlp doesn't know this site

    var body: some View {
        HStack(spacing: 8) {
            if let icon = siteIcon {
                Text(icon).font(.system(size: 13)).foregroundStyle(.secondary.opacity(0.6))
                    .transition(.scale.combined(with: .opacity))
                    .animation(.spring(response: 0.2), value: icon)
            }
            TextField("Paste URL - YouTube, Twitch, Twitter, SoundCloud, Vimeo…", text: $job.url)
                .textFieldStyle(.plain).font(.system(size: 13.5))
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
                            if DownloadJob.looksLikePlaylist(url) {
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
                            if DownloadJob.looksLikePlaylist(newURL) {
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
            } else if job.status != .idle, job.status != .cancelled {
                StatusBadge(job: job).transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.22), value: job.status.shortLabel)
    }

    var siteIcon: String? {
        let u = job.url.lowercased()
        if u.contains("youtube.com") || u.contains("youtu.be") { return "▶" }
        if u.contains("twitch.tv")                              { return "◉" }
        if u.contains("twitter.com") || u.contains("x.com")    { return "𝕏" }
        if u.contains("soundcloud.com")                         { return "♫" }
        if u.contains("vimeo.com")                              { return "◈" }
        if u.contains("instagram.com")                          { return "⊡" }
        if u.contains("tiktok.com")                             { return "♪" }
        if u.contains("reddit.com")                             { return "⊕" }
        if u.hasPrefix("http")                                  { return "⬡" }
        return nil
    }
}

// MARK: - Real Format Picker (video + audio independently)

struct RealFormatPicker: View {
    @ObservedObject var job: DownloadJob
    let meta: VideoMeta

    // "Best" sentinel - empty string means use yt-dlp's bestvideo/bestaudio
    private let bestVideoId = ""
    private let bestAudioId = ""

    var selectedVideo: String {
        job.selectedVideoFormatId.isEmpty ? bestVideoId : job.selectedVideoFormatId
    }
    var selectedAudio: String {
        job.selectedAudioFormatId.isEmpty ? bestAudioId : job.selectedAudioFormatId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Video track
            HStack(alignment: .center, spacing: 0) {
                OptionLabel(icon: "film", text: "Video")
                Menu {
                    Button { job.selectedVideoFormatId = "" } label: {
                        HStack {
                            Text("Best available")
                            if job.selectedVideoFormatId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(meta.videoFormats) { fmt in
                        Button { job.selectedVideoFormatId = fmt.id } label: {
                            HStack {
                                Text(fmt.label)
                                if job.selectedVideoFormatId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Divider()
                    // Audio-only modes
                    Button { job.selectedVideoFormatId = "audio"; job.selectedAudioFormatId = "" } label: {
                        HStack {
                            Text("Audio only - best")
                            if job.selectedVideoFormatId == "audio" { Spacer(); Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if job.selectedVideoFormatId == "audio" {
                            Text("Audio only").font(.system(size: 12, weight: .medium))
                        } else if job.selectedVideoFormatId.isEmpty {
                            Text("Best available").font(.system(size: 12, weight: .medium))
                            if let best = meta.videoFormats.first, let h = best.height {
                                Text("(\(h)p)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let best = meta.videoFormats.first, let fs = best.filesize {
                                Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        } else if let fmt = meta.videoFormats.first(where: { $0.id == job.selectedVideoFormatId }) {
                            Text("\(fmt.height.map { "\($0)p" } ?? fmt.id)")
                                .font(.system(size: 12, weight: .medium))
                            Text("· \(fmt.ext.uppercased())").font(.system(size: 11)).foregroundStyle(.secondary)
                            if let fs = fmt.filesize {
                                Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            // Audio track (only shown when downloading video, not audio-only mode)
            if job.selectedVideoFormatId != "audio" {
                HStack(alignment: .center, spacing: 0) {
                    OptionLabel(icon: "waveform", text: "Audio")
                    Menu {
                        Button { job.selectedAudioFormatId = "" } label: {
                            HStack {
                                Text("Best available")
                                if job.selectedAudioFormatId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        ForEach(meta.audioFormats) { fmt in
                            Button { job.selectedAudioFormatId = fmt.id } label: {
                                HStack {
                                    Text(fmt.label)
                                    if job.selectedAudioFormatId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if job.selectedAudioFormatId.isEmpty {
                                Text("Best available").font(.system(size: 12, weight: .medium))
                                if let best = meta.audioFormats.first {
                                    Text("(\(best.acodec.uppercased()))").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                if let best = meta.audioFormats.first, let fs = best.filesize {
                                    Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            } else if let fmt = meta.audioFormats.first(where: { $0.id == job.selectedAudioFormatId }) {
                                Text(fmt.abr.map { "\(Int($0))kbps" } ?? fmt.id)
                                    .font(.system(size: 12, weight: .medium))
                                Text("· \(fmt.acodec.uppercased())").font(.system(size: 11)).foregroundStyle(.secondary)
                                if let fs = fmt.filesize {
                                    Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }
}

struct StatusBadge: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        Text(job.status.shortLabel)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(job.status.accentColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(job.status.accentColor.opacity(0.1)).clipShape(Capsule())
    }
}

// MARK: - Progress Bar

struct JobProgressBar: View {
    @ObservedObject var job: DownloadJob
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.primary.opacity(0.05)
                Rectangle()
                    .fill(job.status.isDone
                          ? LinearGradient(colors: [.green.opacity(0.8), .green], startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * job.status.progress))
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: job.status.progress)
            }
        }
        .frame(height: 2)
    }
}

// MARK: - Options Panel

struct JobOptionsPanel: View {
    @ObservedObject var job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Audio quick toggle
            HStack(alignment: .center, spacing: 0) {
                OptionLabel(icon: "waveform", text: "Audio only")
                let isAudioOnly = job.selectedVideoFormatId == "audio" || job.format.isAudio
                Toggle(isOn: Binding(
                    get: { isAudioOnly },
                    set: { on in
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
                        Haptics.toggleOn()
                    }
                ).animation(.spring(response: 0.25))) {
                    Text(isAudioOnly ? "Downloading audio only" : "Download audio track only")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .toggleStyle(SlimToggleStyle())
                Spacer()
            }

            if job.isTwitchURL && !job.twitchQualities.isEmpty {
                // Twitch: show real qualities fetched from the M3U8 (Source, 1080p60, 720p30…)
                HStack(alignment: .center, spacing: 0) {
                    OptionLabel(icon: "film", text: "Quality")
                    Picker("", selection: Binding(
                        get: { job.selectedTwitchQuality?.id ?? job.twitchQualities.first?.id ?? "Source" },
                        set: { newId in
                            job.selectedTwitchQuality = job.twitchQualities.first { $0.id == newId }
                        }
                    )) {
                        ForEach(job.twitchQualities) { q in
                            Text(q.displayName).tag(q.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 230)
                    Spacer()
                }
            } else if let meta = job.meta, !meta.videoFormats.isEmpty {
                // Real format picker - separate video track + audio track
                RealFormatPicker(job: job, meta: meta)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    OptionLabel(icon: "film", text: "Format")
                    Picker("", selection: $job.format) {
                        ForEach(DownloadFormat.allCases) { fmt in
                            Label(fmt.displayName, systemImage: fmt.icon).tag(fmt)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 230)
                    Spacer()
                }
            }

            // Subtitles
            HStack(alignment: .center, spacing: 0) {
                OptionLabel(icon: "captions.bubble", text: "Subtitles")
                Toggle(isOn: $job.downloadSubs.animation(.spring(response: 0.25))) {
                    HStack(spacing: 6) {
                        Text("Download subtitles")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if job.metaState == .fetching {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                        } else if let langs = job.meta?.availableSubLangs, !langs.isEmpty {
                            Text("\(langs.count) \(langs.count == 1 ? "lang" : "langs") available")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.1)).clipShape(Capsule())
                        }
                    }
                }
                .toggleStyle(SlimToggleStyle())
                if job.downloadSubs {
                    Spacer().frame(width: 12)
                    if let langs = job.meta?.availableSubLangs, !langs.isEmpty {
                        // Real language picker from --list-subs
                        Menu {
                            ForEach(langs, id: \.self) { lang in
                                Button {
                                    job.subLang = lang
                                } label: {
                                    HStack {
                                        Text(lang)
                                        if job.subLang == lang { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(job.subLang.isEmpty ? (langs.first ?? "?") : job.subLang)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor).opacity(0.55), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if job.subLang.isEmpty || !langs.contains(job.subLang),
                               let first = langs.first { job.subLang = first }
                        }
                        .onChange(of: langs) { newLangs in
                            if job.subLang.isEmpty || !newLangs.contains(job.subLang),
                               let first = newLangs.first { job.subLang = first }
                        }
                    } else if job.metaState == .fetching {
                        Text("detecting…")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text("none found")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            // Segment
            HStack(alignment: .top, spacing: 0) {
                OptionLabel(icon: "scissors", text: "Segment").padding(.top, 1)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $job.useSegment.animation(.spring(response: 0.25))) {
                        Text("Download a specific range")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(SlimToggleStyle())

                    if job.useSegment {
                        VStack(alignment: .leading, spacing: 10) {

                            // Mode toggle: Manual vs Chapters (only if video has chapters)
                            if let chapters = job.meta?.chapters, !chapters.isEmpty {
                                HStack(spacing: 0) {
                                    ForEach([("scissors", "Start/End", DownloadJob.SegmentMode.manual),
                                             ("list.bullet", "Chapters", DownloadJob.SegmentMode.chapters)],
                                            id: \.1) { icon, label, mode in
                                        let active = job.segmentMode == mode
                                        Button {
                                            withAnimation(.easeOut(duration: 0.15)) { job.segmentMode = mode }
                                            Haptics.tap()
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: icon).font(.system(size: 9, weight: .medium))
                                                Text(label).font(.system(size: 10.5, weight: .medium))
                                            }
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .background(active ? Color.accentColor : Color.clear)
                                            .foregroundStyle(active ? .white : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                            }

                            if job.segmentMode == .manual || (job.meta?.chapters.isEmpty ?? true) {
                                // Manual start/end range
                                HStack(alignment: .bottom, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Start").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                                        HMSInput(hours: $job.startH, minutes: $job.startM, seconds: $job.startS)
                                    }
                                    Text("→").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.bottom, 7)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Text("End").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                                            if job.metaState == .fetching {
                                                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                                            }
                                        }
                                        HMSInput(hours: $job.endH, minutes: $job.endM, seconds: $job.endS,
                                                 placeholders: job.videoDurationHMS)
                                    }
                                    if let meta = job.meta {
                                        Text("/ \(meta.duration)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary).padding(.bottom, 7)
                                    }
                                    Spacer()
                                }

                                // Chapter quick-fill buttons (manual mode only)
                                if let chapters = job.meta?.chapters, !chapters.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("JUMP TO SECTION")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
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
                                                            Text(ch.title)
                                                                .font(.system(size: 10.5, weight: .medium))
                                                                .lineLimit(1)
                                                            Text(ch.duration)
                                                                .font(.system(size: 9.5, design: .monospaced))
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        .foregroundStyle(Color.accentColor)
                                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                                        .background(Color.accentColor.opacity(0.09))
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                                            .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .hoverHaptic()
                                                }
                                            }
                                        }
                                    }
                                }
                            } else if let chapters = job.meta?.chapters, !chapters.isEmpty {
                                // Chapter pick mode - multi-select list
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SELECT CHAPTERS TO DOWNLOAD")
                                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                                    VStack(spacing: 2) {
                                        ForEach(chapters) { ch in
                                            let sel = job.selectedChapters.contains(ch.id)
                                            Button {
                                                withAnimation(.easeOut(duration: 0.12)) {
                                                    if sel { job.selectedChapters.remove(ch.id) }
                                                    else   { job.selectedChapters.insert(ch.id) }
                                                }
                                                sel ? Haptics.toggleOff() : Haptics.toggleOn()
                                            } label: {
                                                HStack(spacing: 7) {
                                                    Image(systemName: sel ? "checkmark.square.fill" : "square")
                                                        .font(.system(size: 13))
                                                        .foregroundStyle(sel ? Color.accentColor : Color.secondary.opacity(0.35))
                                                    Text(ch.title)
                                                        .font(.system(size: 11, weight: sel ? .medium : .regular))
                                                        .foregroundStyle(sel ? .primary : .secondary)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    Text(ch.duration)
                                                        .font(.system(size: 10, design: .monospaced))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .padding(.horizontal, 8).padding(.vertical, 5)
                                                .background(sel ? Color.accentColor.opacity(0.08) : Color.clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(5)
                                    .background(Color.primary.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    if chapters.count > 1 {
                                        HStack {
                                            Spacer()
                                            let allSel = job.selectedChapters.count == chapters.count
                                            Button(allSel ? "Deselect all" : "Select all") {
                                                withAnimation(.easeOut(duration: 0.12)) {
                                                    if allSel { job.selectedChapters.removeAll() }
                                                    else { job.selectedChapters = Set(chapters.map(\.id)) }
                                                }
                                                Haptics.tap()
                                            }
                                            .buttonStyle(.plain)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color.accentColor.opacity(0.8))
                                        }
                                    }
                                }
                            }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
            }

            // SponsorBlock
            HStack(alignment: .center, spacing: 0) {
                OptionLabel(icon: "scissors.badge.ellipsis", text: "SponsorBlock")
                Toggle(isOn: Binding(
                    get: { job.sponsorBlockOverride ?? SettingsManager.shared.sponsorBlock },
                    set: { job.sponsorBlockOverride = $0 }
                ).animation(.spring(response: 0.25))) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Skip sponsors automatically")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if job.sponsorBlockOverride == nil {
                            Text("using global setting")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(SlimToggleStyle())
                // Reset to inherit global
                if job.sponsorBlockOverride != nil {
                    Button { job.sponsorBlockOverride = nil } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to global setting")
                    .padding(.leading, 6)
                }
                Spacer()
            }

        }
    }
}

struct OptionLabel: View {
    let icon: String; let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
            .lineLimit(1).fixedSize()
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

// MARK: - Log View

struct JobLogView: View {
    let log: [LogLine]
    @State private var showFullLog = false

    var body: some View {
        VStack(spacing: 0) {
            // Mini inline log - last 6 lines
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.suffix(40)) { line in
                            Text(line.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(logColor(line.kind))
                                .lineLimit(1).truncationMode(.tail).id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                .onChange(of: log.count) { _ in
                    if let last = log.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            // Toolbar: "View all logs" + "Copy"
            HStack(spacing: 8) {
                Button {
                    showFullLog = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 9))
                        Text("View all logs (\(log.count))")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    let text = log.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Haptics.success()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                        Text("Copy logs").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy all log output to clipboard")
            }
            .padding(.top, 5)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .sheet(isPresented: $showFullLog) {
            FullLogSheet(log: log)
        }
    }

    func logColor(_ kind: LogLine.Kind) -> Color {
        switch kind {
        case .command:  return .secondary.opacity(0.4)
        case .info:     return .secondary.opacity(0.72)
        case .progress: return Color.accentColor
        case .success:  return .green
        case .warning:  return .orange
        case .error:    return Color(red: 0.85, green: 0.35, blue: 0.35)
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(btnBg))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(btnBorder, lineWidth: 0.5))
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
        case .done:                     return "folder"
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
        case .done:                     return "Reveal"
        case .failed:                   return job.retryCount > 0 ? "Retry (\(job.retryCount))" : "Retry"
        }
    }
    var btnFg: Color {
        switch job.status {
        case .done:    return .green
        case .failed:  return .red
        case .fetching, .merging: return .secondary
        default:       return .primary.opacity(0.75)
        }
    }
    var btnBg: Color {
        switch job.status {
        case .done:   return .green.opacity(0.1)
        case .failed: return .red.opacity(0.08)
        default:      return .primary.opacity(0.06)
        }
    }
    var btnBorder: Color {
        switch job.status {
        case .done:   return .green.opacity(0.25)
        case .failed: return .red.opacity(0.2)
        default:      return Color(.separatorColor).opacity(0.8)
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
            Image(systemName: systemImage).font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(fg).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(bg))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color(.separatorColor).opacity(hovered ? 0.9 : 0.4), lineWidth: 0.5))
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.hoverHaptic().help(tooltip)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
    var fg: Color {
        if destructive { return hovered ? .red : .secondary.opacity(0.5) }
        if let tint    { return tint }
        return hovered ? .primary.opacity(0.8) : .secondary.opacity(0.55)
    }
    var bg: Color {
        if destructive && hovered { return .red.opacity(0.08) }
        if let tint               { return tint.opacity(0.1) }
        return .primary.opacity(hovered ? 0.07 : 0.04)
    }
}
