import SwiftUI

// MARK: - Advanced Mode View

struct AdvancedView: View {
    @EnvironmentObject var queue    : DownloadQueue
    @EnvironmentObject var deps     : DependencyService
    @EnvironmentObject var theme    : ThemeManager
    @EnvironmentObject var settings : SettingsManager

    @State private var playlistURL   = ""
    @State private var playlistItems : [PlaylistItem] = []
    @State private var fetchState    : AdvFetchState  = .idle
    @State private var errorMsg      = ""
    @State private var globalFormat  : DownloadFormat = .best
    @State private var useCookies    = false
    @State private var manualCookies : String = ""
    @State private var extraArgs     = ""
    @State private var writeSubs     = false
    @State private var subLang       = "en"
    @State private var writeDesc     = false
    @State private var saveThumbnail = false
    @State private var sponsorBlock  = false
    @State private var noPlaylistShuffle = false
    @State private var downloadRunning   = false
    @State private var selectionTick      = 0   // forces re-render on item.selected changes

    enum AdvFetchState { case idle, fetching, ready, error }

    var selectedItems: [PlaylistItem] { let _ = selectionTick; return playlistItems.filter(\.selected) }

    var body: some View {
        VStack(spacing: 0) {
            // ── URL bar ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Paste playlist or channel URL…", text: $playlistURL)
                        .textFieldStyle(.plain).font(.system(size: 13.5))
                        .onSubmit { fetchPlaylist() }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))

                Button { fetchPlaylist() } label: {
                    Group {
                        if fetchState == .fetching {
                            ProgressView().scaleEffect(0.75).frame(width: 20, height: 20)
                        } else {
                            Label("Load", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(playlistURL.isEmpty || fetchState == .fetching)
                .hoverHaptic()
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .onAppear {
                // Pick up URL handed off from Video mode
                if !settings.pendingPlaylistURL.isEmpty {
                    playlistURL = settings.pendingPlaylistURL
                    settings.pendingPlaylistURL = ""
                    fetchPlaylist()
                }
            }
            .onChange(of: settings.pendingPlaylistURL) { newURL in
                // Also auto-fetch when view is already visible and a new URL arrives
                guard !newURL.isEmpty else { return }
                playlistURL = newURL
                settings.pendingPlaylistURL = ""
                fetchPlaylist()
            }
            // Also respond to runtime notifications (e.g. from menu bar)
            .onReceive(NotificationCenter.default.publisher(for: .openPlaylistURL)) { notif in
                if let url = notif.object as? String, !url.isEmpty {
                    playlistURL = url
                    fetchPlaylist()
                }
            }


            if fetchState == .error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMsg).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { fetchPlaylist() }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
            }

            if fetchState == .ready && !playlistItems.isEmpty {
                // ── Playlist header ───────────────────────────────────────
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(playlistItems.count) videos")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 6) {
                            Text("\(selectedItems.count) selected")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            // Show total known size across selected items
                            let knownBytes = selectedItems.flatMap { $0.videoFormats.isEmpty ? [] : [$0.videoFormats.first?.filesize ?? 0] }
                                .filter { $0 > 0 }
                                .reduce(Int64(0), +)
                            if knownBytes > 0 {
                                Text("· \(ByteCountFormatter.string(fromByteCount: knownBytes, countStyle: .file)) est.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.6))
                            }
                        }
                    }
                    Spacer()

                    // SponsorBlock toggle for ALL videos - right in the header where it belongs
                    let allSponsor = !playlistItems.isEmpty && playlistItems.allSatisfy(\.sponsorBlock)
                    Button {
                        let enable = !allSponsor
                        playlistItems.forEach { $0.sponsorBlock = enable }
                        enable ? Haptics.toggleOn() : Haptics.toggleOff()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: allSponsor ? "scissors.badge.ellipsis" : "scissors")
                                .font(.system(size: 10, weight: .semibold))
                            Text(allSponsor ? "SponsorBlock: ON" : "SponsorBlock")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(allSponsor ? .white : Color.purple)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(allSponsor ? Color.purple : Color.purple.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.purple.opacity(allSponsor ? 0 : 0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain).hoverHaptic()
                    .help(allSponsor ? "Disable SponsorBlock for all" : "Enable SponsorBlock for all videos")

                    Button {
                        let allSel = selectedItems.count == playlistItems.count
                        playlistItems.forEach { $0.selected = !allSel }
                        selectionTick += 1
                        allSel ? Haptics.toggleOff() : Haptics.toggleOn()
                    } label: {
                        Text(selectedItems.count == playlistItems.count ? "Deselect all" : "Select all")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).hoverHaptic()
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)

                Divider().opacity(0.08)

                // ── Playlist checklist ────────────────────────────────────
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(playlistItems) { item in
                            PlaylistItemRow(item: item, onToggle: { selectionTick += 1 })
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            } else if fetchState == .fetching {
                VStack(spacing: 14) {
                    ProgressView().scaleEffect(1.2)
                    Text("Fetching playlist…")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fetchState == .idle {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 44)).foregroundStyle(Color.secondary.opacity(0.15))
                    Text("Paste a playlist URL above")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary.opacity(0.45))
                    Text("YouTube playlists · channels · SoundCloud sets · and more")
                        .font(.system(size: 12)).foregroundStyle(.secondary.opacity(0.25))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
            Divider().opacity(0.08)

            // ── Advanced flags panel ──────────────────────────────────────
            AdvancedFlagsPanel(
                globalFormat: $globalFormat,
                useCookies: $useCookies,

                extraArgs: $extraArgs,
                writeSubs: $writeSubs,
                subLang: $subLang,
                writeDesc: $writeDesc,
                saveThumbnail: $saveThumbnail,
                sponsorBlock: $sponsorBlock,
                playlistItems: $playlistItems
            )

            Divider().opacity(0.08)

            // ── Download bar ──────────────────────────────────────────────
            HStack(spacing: 10) {
                OutputFolderButton(directory: queue.outputDirectory, action: { pickOutputFolder() })
                CategoryPicker()
                    .environmentObject(settings)
                    .environmentObject(queue)
                if !playlistItems.isEmpty {
                    Text("\(selectedItems.count) of \(playlistItems.count) selected")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    startDownloads()
                } label: {
                    Label("Download \(selectedItems.count > 0 ? "\(selectedItems.count) videos" : "selected")",
                          systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(selectedItems.isEmpty || downloadRunning)
                .hoverHaptic()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Fetch

    func fetchPlaylist() {
        guard !playlistURL.isEmpty else { return }
        guard deps.ytdlp.isReady else { return }
        fetchState = .fetching
        playlistItems = []
        Haptics.start()

        // Write manual cookies to a temp file if provided
        let authArgs: [String] = {
            guard useCookies, !manualCookies.isEmpty else { return [] }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("playlist_cookies_\(UUID().uuidString).txt")
            try? manualCookies.write(to: tmp, atomically: true, encoding: .utf8)
            return ["--cookies", tmp.path]
        }()

        Task {
            let result = await DownloadService.shared.fetchPlaylist(url: playlistURL, authArgs: authArgs)
            await MainActor.run {
                switch result {
                case .success(let items):
                    // Apply global format
                    items.forEach { $0.format = globalFormat }
                    playlistItems = items
                    fetchState = .ready
                    Haptics.success()
                case .failure(let err):
                    errorMsg = err.localizedDescription
                    fetchState = .error
                    Haptics.error()
                }
            }
        }
    }

    // MARK: - Download

    func startDownloads() {
        guard !selectedItems.isEmpty else { return }
        guard deps.ytdlp.isReady && deps.ffmpeg.isReady else { return }
        queue.ensureOutputDir()
        downloadRunning = true
        Haptics.start()

        // Create a DownloadJob per selected item and add to the queue
        for item in selectedItems where item.downloadStatus == .waiting {
            let job = DownloadJob()
            // Build the video URL
            if playlistURL.contains("youtube.com") || playlistURL.contains("youtu.be") {
                job.url = "https://www.youtube.com/watch?v=\(item.videoID)"
            } else {
                job.url = playlistURL
                job.isPlaylist = false
                // Use playlist-items flag via extraArgs
                job.extraArgs = "--playlist-items \(item.index)"
            }
            job.format = item.format

            // Apply segment if set
            switch item.segmentMode {
            case .manual:
                let hasTime = !item.startH.isEmpty || !item.startM.isEmpty || !item.startS.isEmpty
                if hasTime {
                    job.useSegment   = true
                    job.segmentMode  = .manual
                    job.startH = item.startH; job.startM = item.startM; job.startS = item.startS
                    job.endH   = item.endH;   job.endM   = item.endM;   job.endS   = item.endS
                }
            case .chapters:
                if !item.selectedChapters.isEmpty {
                    job.useSegment        = true
                    job.segmentMode       = .chapters
                    job.selectedChapters  = item.selectedChapters
                    // Give the job chapter metadata so subtitle retiming works
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

            // Apply global advanced flags
            job.downloadSubs      = writeSubs
            job.subLang           = subLang
            job.writeDescription  = writeDesc
            job.writeThumbnail    = saveThumbnail
            job.sponsorBlockOverride = sponsorBlock ? true : nil
            if !extraArgs.isEmpty { job.extraArgs += " " + extraArgs }

            queue.jobs.append(job)
            DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
            item.downloadStatus = .downloading
        }

        downloadRunning = false
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
            _ = url.startAccessingSecurityScopedResource()
            queue.outputDirectory = url
        }
    }
}

// MARK: - Playlist Item Row

struct PlaylistItemRow: View {
    @ObservedObject var item: PlaylistItem
    var onToggle: () -> Void = {}
    @State private var expanded = false
    @State private var hovered  = false

    var hasClip: Bool {
        !item.startH.isEmpty || !item.startM.isEmpty || !item.startS.isEmpty
    }
    var thumbPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(Image(systemName: "film")
                .font(.system(size: 14)).foregroundStyle(.tertiary))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Main row ──────────────────────────────────────────────
            HStack(spacing: 0) {

                // Checkbox - dedicated tap target, left side
                Button {
                    item.selected.toggle()
                    onToggle()
                    item.selected ? Haptics.toggleOn() : Haptics.toggleOff()
                } label: {
                    Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundStyle(item.selected ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Row body - tap to expand
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        expanded.toggle()
                    }
                    Haptics.tap()
                } label: {
                    HStack(spacing: 10) {
                        // Thumbnail
                        Group {
                            if !item.thumbnail.isEmpty {
                                AsyncImage(url: URL(string: item.thumbnail)) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        thumbPlaceholder
                                    }
                                }
                            } else {
                                thumbPlaceholder
                            }
                        }
                        .frame(width: 64, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                        // Title + meta
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 13, weight: item.selected ? .medium : .regular))
                                .foregroundStyle(item.selected ? .primary : .secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text(String(format: "#%d", item.index))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                if !item.duration.isEmpty && item.duration != "0:00" {
                                    Text(item.duration)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                if hasClip {
                                    Image(systemName: "scissors")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.accentColor.opacity(0.7))
                                }
                                if item.downloadStatus != .waiting {
                                    Image(systemName: item.downloadStatus.icon)
                                        .font(.system(size: 10))
                                        .foregroundStyle(item.downloadStatus.color)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Chevron
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .padding(.trailing, 4)
                    }
                    .padding(.vertical, 9)
                    .padding(.trailing, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(
                hovered && !expanded
                    ? Color.primary.opacity(0.04)
                    : Color.clear
            )

            // ── Expanded detail panel ─────────────────────────────────
            if expanded {
                Divider().opacity(0.08)

                VStack(alignment: .leading, spacing: 10) {
                    let _ = Color.clear.onAppear {
                        // Lazy: fetch formats for this item the first time it's expanded
                        if item.videoFormats.isEmpty {
                            let vid = item.videoID
                            let url = "https://www.youtube.com/watch?v=\(vid)"
                            Task.detached(priority: .userInitiated) {
                                guard let path = DependencyService.appSupportBin.appendingPathComponent("yt-dlp").path as String?,
                                      FileManager.default.fileExists(atPath: path) else { return }
                                let result = await DownloadService.shared.fetchSingleVideoMeta(url: url, ytdlpPath: path, authArgs: [])
                                if let meta = try? result.get() {
                                    await MainActor.run {
                                        item.videoFormats = meta.videoFormats
                                        item.audioFormats = meta.audioFormats
                                        if !meta.chapters.isEmpty { item.chapters = meta.chapters }
                                        if item.downloadSubs && item.subLang.isEmpty, let first = meta.availableSubLangs.first {
                                            item.subLang = first
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Row 1: Video quality picker (real formats if available, else DownloadFormat)
                    HStack(spacing: 8) {
                        Text("QUALITY")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        if !item.videoFormats.isEmpty {
                            Menu {
                                Button {
                                    item.selectedVideoFormatId = ""
                                } label: {
                                    HStack {
                                        Text("Best (auto)")
                                        if item.selectedVideoFormatId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                                Divider()
                                ForEach(item.videoFormats) { fmt in
                                    Button {
                                        item.selectedVideoFormatId = fmt.id
                                    } label: {
                                        HStack {
                                            Text(fmt.label)
                                            if item.selectedVideoFormatId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                                Divider()
                                Button {
                                    item.selectedVideoFormatId = "audio"
                                } label: {
                                    HStack {
                                        Label("Audio only", systemImage: "music.note")
                                        if item.selectedVideoFormatId == "audio" { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    let bestFmt = item.selectedVideoFormatId.isEmpty ? item.videoFormats.first : nil
                                    let selFmt  = item.videoFormats.first(where: { $0.id == item.selectedVideoFormatId })
                                    let displayFmt = selFmt ?? bestFmt
                                    let resLabel: String = {
                                        if item.selectedVideoFormatId == "audio" { return "Audio only" }
                                        if item.selectedVideoFormatId.isEmpty {
                                            if let h = bestFmt?.height { return "Best (\(h)p)" }
                                            return "Best"
                                        }
                                        if let h = selFmt?.height { return "\(h)p" }
                                        return selFmt?.label ?? item.selectedVideoFormatId
                                    }()
                                    Text(resLabel).font(.system(size: 12))
                                    if let fs = displayFmt?.filesize {
                                        Text(ByteCountFormatter.string(fromByteCount: fs, countStyle: .file))
                                            .font(.system(size: 10)).foregroundStyle(.secondary.opacity(0.7))
                                    }
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Picker("", selection: $item.format) {
                                ForEach(DownloadFormat.allCases) { f in Text(f.displayName).tag(f) }
                            }
                            .labelsHidden().pickerStyle(.menu)
                        }
                        Spacer()
                    }

                    // Audio track picker (when video format selected and audio formats available)
                    if item.selectedVideoFormatId != "audio" && !item.audioFormats.isEmpty {
                        HStack(spacing: 8) {
                            Text("AUDIO")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .leading)
                            Menu {
                                Button {
                                    item.selectedAudioFormatId = ""
                                } label: {
                                    HStack {
                                        Text("Best (auto)")
                                        if item.selectedAudioFormatId.isEmpty { Spacer(); Image(systemName: "checkmark") }
                                    }
                                }
                                Divider()
                                ForEach(item.audioFormats) { fmt in
                                    Button {
                                        item.selectedAudioFormatId = fmt.id
                                    } label: {
                                        HStack {
                                            Text(fmt.label)
                                            if item.selectedAudioFormatId == fmt.id { Spacer(); Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    let label = item.selectedAudioFormatId.isEmpty ? "Best" :
                                        (item.audioFormats.first(where: { $0.id == item.selectedAudioFormatId })?.label ?? item.selectedAudioFormatId)
                                    Text(label).font(.system(size: 12))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .medium))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                    }

                    // Subtitles row
                    HStack(spacing: 8) {
                        Text("SUBS")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        Toggle("", isOn: $item.downloadSubs.animation()).labelsHidden().toggleStyle(SlimToggleStyle())
                        Text("Download subtitles").font(.system(size: 11)).foregroundStyle(item.downloadSubs ? .primary : .secondary)
                        if item.downloadSubs && !item.subLang.isEmpty {
                            Text(item.subLang)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Spacer()
                    }

                    // SponsorBlock row
                    HStack(spacing: 8) {
                        Text("SPON.")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        Toggle("", isOn: $item.sponsorBlock.animation()).labelsHidden().toggleStyle(SlimToggleStyle())
                        Text("Skip sponsors").font(.system(size: 11)).foregroundStyle(item.sponsorBlock ? .primary : .secondary)
                        Spacer()
                    }

                    // Row 2: Clip start → end
                    HStack(spacing: 10) {
                        Text("CLIP")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("START").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                            MiniHMSInput(h: $item.startH, m: $item.startM, s: $item.startS)
                        }
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("END").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                                Text("/ \(item.duration)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            }
                            MiniHMSInput(h: $item.endH, m: $item.endM, s: $item.endS)
                        }
                        Spacer()
                    }

                    // Row 3: Chapter mode toggle + picker
                    if !item.chapters.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            // Mode toggle
                            HStack(spacing: 8) {
                                Text("CHAPTER")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                    .frame(width: 52, alignment: .leading)
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
                                                Text(label).font(.system(size: 10, weight: .medium))
                                            }
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(active ? Color.accentColor : Color.clear)
                                            .foregroundStyle(active ? .white : .secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                            }

                            if item.segmentMode == .manual {
                                // Quick-fill chapter buttons
                                HStack(spacing: 8) {
                                    Text("").frame(width: 52)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 5) {
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
                                                    HStack(spacing: 4) {
                                                        Text(ch.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                                                        Text(ch.duration).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                                    }
                                                    .foregroundStyle(Color.accentColor)
                                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                                    .background(Color.accentColor.opacity(0.09))
                                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                                }
                                                .buttonStyle(.plain).hoverHaptic()
                                            }
                                        }
                                    }
                                }
                            } else {
                                // Chapter multi-select
                                HStack(alignment: .top, spacing: 8) {
                                    Text("").frame(width: 52)
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(item.chapters) { ch in
                                            let sel = item.selectedChapters.contains(ch.id)
                                            Button {
                                                withAnimation(.easeOut(duration: 0.12)) {
                                                    if sel { item.selectedChapters.remove(ch.id) }
                                                    else   { item.selectedChapters.insert(ch.id) }
                                                }
                                                sel ? Haptics.toggleOff() : Haptics.toggleOn()
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Image(systemName: sel ? "checkmark.square.fill" : "square")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(sel ? Color.accentColor : Color.secondary.opacity(0.35))
                                                    Text(ch.title)
                                                        .font(.system(size: 10.5, weight: sel ? .medium : .regular))
                                                        .foregroundStyle(sel ? .primary : .secondary)
                                                        .lineLimit(1)
                                                    Spacer()
                                                    Text(ch.duration)
                                                        .font(.system(size: 9.5, design: .monospaced))
                                                        .foregroundStyle(.tertiary)
                                                }
                                                .padding(.horizontal, 7).padding(.vertical, 4)
                                                .background(sel ? Color.accentColor.opacity(0.08) : Color.clear)
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
                                                .font(.system(size: 9.5, weight: .medium))
                                                .foregroundStyle(Color.accentColor.opacity(0.8))
                                            }
                                        }
                                    }
                                    .padding(4)
                                    .background(Color.primary.opacity(0.03))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 36).padding(.trailing, 14).padding(.vertical, 10)
                .background(Color.primary.opacity(0.025))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(expanded ? Color.primary.opacity(0.03) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    expanded ? Color(.separatorColor).opacity(0.4) : Color.clear,
                    lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(item.selected ? 1 : 0.45)
        .onHover { h in
            hovered = h
            if h { Haptics.hover() }
        }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: expanded)
    }
}

// MARK: - Advanced Flags Panel

struct AdvancedFlagsPanel: View {
    @Binding var globalFormat  : DownloadFormat
    @Binding var useCookies    : Bool
    @Binding var extraArgs     : String
    @Binding var writeSubs     : Bool
    @Binding var subLang       : String
    @Binding var writeDesc     : Bool
    @Binding var saveThumbnail : Bool
    @Binding var sponsorBlock  : Bool
    @Binding var playlistItems : [PlaylistItem]

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28)) { expanded.toggle() }
                Haptics.tap()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Advanced Flags")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 20).padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .hoverHaptic()

            if expanded {
                Divider().opacity(0.07)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {

                        // Global format
                        HStack(spacing: 12) {
                            FlagLabel(icon: "film", text: "Default format")
                            Picker("", selection: $globalFormat) {
                                ForEach(DownloadFormat.allCases) { f in
                                    Label(f.displayName, systemImage: f.icon).tag(f)
                                }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 200)
                            Spacer()
                        }

                        // Auth
                        HStack(spacing: 12) {
                            FlagLabel(icon: "key", text: "Auth cookies")
                            Toggle("Use cookies", isOn: $useCookies)
                                .toggleStyle(SlimToggleStyle())
                                .font(.system(size: 12))
                            if useCookies {
                                Text("Paste in job auth sheet")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        // Subtitles
                        HStack(spacing: 12) {
                            FlagLabel(icon: "captions.bubble", text: "Subtitles")
                            Toggle("Download", isOn: $writeSubs).toggleStyle(SlimToggleStyle())
                                .font(.system(size: 12))
                            if writeSubs {
                                TextField("en", text: $subLang)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .frame(width: 36).multilineTextAlignment(.center)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color(.separatorColor).opacity(0.6), lineWidth: 0.5))
                            }
                            Spacer()
                        }

                        // Metadata - one option per row, same FlagLabel width as above
                        HStack(spacing: 12) {
                            FlagLabel(icon: "doc.text", text: "Description")
                            Toggle("Save to file", isOn: $writeDesc).toggleStyle(SlimToggleStyle())
                                .font(.system(size: 12))
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            FlagLabel(icon: "photo", text: "Thumbnail")
                            Toggle("Save to file", isOn: $saveThumbnail).toggleStyle(SlimToggleStyle())
                                .font(.system(size: 12))
                            Spacer()
                        }
                        // SponsorBlock - per-playlist global toggle + apply to all items button
                        HStack(spacing: 12) {
                            FlagLabel(icon: "scissors.badge.ellipsis", text: "SponsorBlock")
                            Toggle("Skip sponsors", isOn: $sponsorBlock).toggleStyle(SlimToggleStyle())
                                .font(.system(size: 12))
                            if sponsorBlock {
                                Divider().frame(height: 14).opacity(0.5)
                                Button {
                                    playlistItems.forEach { $0.sponsorBlock = true }
                                    Haptics.toggleOn()
                                } label: {
                                    Text("Apply to all items")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.09))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain).hoverHaptic()
                            }
                            Spacer()
                        }

                        // Raw flags
                        VStack(alignment: .leading, spacing: 6) {
                            FlagLabel(icon: "chevron.left.forwardslash.chevron.right", text: "Raw yt-dlp flags")
                            TextField("--no-mtime --geo-bypass --rate-limit 2M …", text: $extraArgs)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                        }

                        // Common flags reference
                        VStack(alignment: .leading, spacing: 6) {
                            Text("COMMON FLAGS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            let flags: [(String, String)] = [
                                ("--no-mtime", "Don't set file mtime"),
                                ("--geo-bypass", "Bypass geo-restriction"),
                                ("--rate-limit 2M", "Limit speed to 2 MB/s"),
                                ("--concurrent-fragments 4", "Parallel fragment download"),
                                ("--no-overwrites", "Skip existing files"),
                                ("--extract-audio", "Audio only (any format)"),
                                ("--audio-quality 0", "Best audio quality"),
                                ("--sleep-interval 2", "Wait 2s between downloads"),
                                ("--ignore-errors", "Skip failed items"),
                                ("--age-limit 18", "Max age restriction"),
                            ]
                            ForEach(flags, id: \.0) { flag, desc in
                                HStack(spacing: 10) {
                                    Button {
                                        extraArgs = (extraArgs.isEmpty ? "" : extraArgs + " ") + flag
                                        Haptics.tap()
                                    } label: {
                                        Text(flag)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.08))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                    .hoverHaptic()
                                    Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 320)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

struct FlagLabel: View {
    let icon: String; let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 120, alignment: .leading)
    }
}
