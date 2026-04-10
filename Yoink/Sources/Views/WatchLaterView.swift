import SwiftUI

// MARK: - Watch Later View

struct WatchLaterView: View {
    @EnvironmentObject var watchLater : WatchLaterStore
    @EnvironmentObject var queue      : DownloadQueue
    @EnvironmentObject var settings   : SettingsManager
    @EnvironmentObject var theme      : ThemeManager
    @StateObject private var scheduled = ScheduledDownloadStore.shared
    @State private var search         = ""
    @State private var confirmClear   = false
    @State private var showAddSheet   = false
    @State private var addURLText     = ""
    @State private var schedulingItem : WatchLaterItem? = nil
    @State private var playlistPromptURL   : String = ""
    @State private var showPlaylistPrompt  : Bool   = false
    @State private var playlistPickerItem  : WatchLaterItem? = nil
    @State private var draggedItemID        : UUID?            = nil

    // FIX #7: Bulk select
    @State private var selectionMode   : Bool      = false
    @State private var selectedIDs     : Set<UUID> = []

    // FIX #2: Tag filter
    @State private var activeTag: String? = nil

    var filtered: [WatchLaterItem] {
        watchLater.items.filter { item in
            let textOK = search.isEmpty ||
                item.displayTitle.localizedCaseInsensitiveContains(search) ||
                item.url.localizedCaseInsensitiveContains(search)
            let tagOK = activeTag == nil || item.tags.contains(activeTag!)
            return textOK && tagOK
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search saved…", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))

                Text("\(filtered.count) saved").font(.system(size: 11)).foregroundStyle(.secondary)

                Spacer()

                // ── Global toggles ──────────────────────────────────────
                HStack(spacing: 6) {
                    WLToggleChip(
                        label: "SponsorBlock",
                        icon: "scissors",
                        active: settings.watchLaterSponsorBlock,
                        activeColor: .orange
                    ) { settings.watchLaterSponsorBlock.toggle() }

                    WLToggleChip(
                        label: "Subtitles",
                        icon: "captions.bubble",
                        active: settings.watchLaterSubtitles,
                        activeColor: .blue
                    ) { settings.watchLaterSubtitles.toggle() }
                }

                // Download all button
                if !watchLater.items.isEmpty {
                    // FIX #7: Select / bulk download toggle
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectionMode.toggle()
                            if !selectionMode { selectedIDs.removeAll() }
                        }
                    } label: {
                        Text(selectionMode ? "Cancel" : "Select")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selectionMode ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background((selectionMode ? Color.primary : Color.accentColor).opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)

                    if selectionMode {
                        // Download selected
                        Button {
                            let toDownload = filtered.filter { selectedIDs.contains($0.id) }
                            for item in toDownload { downloadItem(item) }
                            selectionMode = false; selectedIDs.removeAll()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11))
                                Text(selectedIDs.isEmpty ? "Download Selected" : "Download \(selectedIDs.count)")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selectedIDs.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedIDs.isEmpty)
                    } else {
                        Button {
                            downloadAll()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 11))
                                Text("Download All").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).hoverHaptic()
                    }
                }

                // Clear all
                if !watchLater.items.isEmpty {
                    Button {
                        confirmClear = true
                    } label: {
                        Text("Clear All").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Clear Watch Later list?", isPresented: $confirmClear) {
                        Button("Clear All", role: .destructive) { watchLater.removeAll() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider().opacity(0.08)

            // FIX #2: Tag filter pills
            let allTags = watchLater.allTags
            if !allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterPill(label: "All", selected: activeTag == nil) {
                            withAnimation(.easeOut(duration: 0.15)) { activeTag = nil }
                        }
                        ForEach(allTags, id: \.self) { tag in
                            FilterPill(label: tag, selected: activeTag == tag) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    activeTag = activeTag == tag ? nil : tag
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                Divider().opacity(0.08)
            }

            // List
            let pendingScheduled = scheduled.items.filter { !$0.fired }
            if filtered.isEmpty && pendingScheduled.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bookmark.circle")
                        .font(.system(size: 44)).foregroundStyle(.secondary.opacity(0.35))
                    Text(search.isEmpty ? "Nothing saved yet" : "No results")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    if search.isEmpty {
                        Text("Paste a URL to save it for later. Download when you're ready.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)

                        // Quick add
                        HStack(spacing: 8) {
                            TextField("Paste a URL to save…", text: $addURLText)
                                .textFieldStyle(.plain).font(.system(size: 13))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                                .frame(maxWidth: 340)
                            Button("Save") {
                                guard addURLText.lowercased().hasPrefix("http") else { return }
                                if DownloadJob.looksLikePlaylist(addURLText) {
                                    playlistPromptURL = addURLText
                                    addURLText = ""
                                    showPlaylistPrompt = true
                                } else {
                                    watchLater.add(url: addURLText)
                                    addURLText = ""
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(addURLText.lowercased().hasPrefix("http") ? Color.accentColor : Color.secondary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        // Scheduled downloads - shown inline above saved items
                        if !pendingScheduled.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("SCHEDULED")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                ForEach(pendingScheduled) { item in
                                    WatchLaterScheduledRow(item: item)
                                }
                            }
                            .padding(.horizontal, 12).padding(.top, 8)
                            Divider().opacity(0.08).padding(.horizontal, 12)
                        }
                        ForEach(filtered) { item in
                            // FIX #7: Bulk select overlay
                            HStack(spacing: 8) {
                                if selectionMode {
                                    let sel = selectedIDs.contains(item.id)
                                    Button {
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            if sel { selectedIDs.remove(item.id) }
                                            else   { selectedIDs.insert(item.id) }
                                        }
                                        sel ? Haptics.toggleOff() : Haptics.toggleOn()
                                    } label: {
                                        Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 18))
                                            .foregroundStyle(sel ? Color.accentColor : Color.secondary.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                }
                                WatchLaterRow(item: item,
                                              onSchedule: { schedulingItem = item },
                                              onPlaylistPick: { playlistPickerItem = item })
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectionMode {
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
                                            else { selectedIDs.insert(item.id) }
                                        }
                                    }
                                }
                            }
                            // Drag source: encode the item's ID as a string
                            .onDrag {
                                draggedItemID = item.id
                                return NSItemProvider(object: item.id.uuidString as NSString)
                            }
                            // Drop target: reorder when another row is dropped here
                            .onDrop(of: [.plainText], delegate: WatchLaterDropDelegate(
                                targetItem: item,
                                store: watchLater,
                                draggedID: $draggedItemID
                            ))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }

            // Quick add bar at bottom
            if !watchLater.items.isEmpty {
                Divider().opacity(0.08)
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Save another URL for later…", text: $addURLText)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .onSubmit { quickAdd() }
                    if addURLText.lowercased().hasPrefix("http") {
                        Button("Save") { quickAdd() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        // Sheet lives here - stable, never recreated by ForEach ticks
        .sheet(item: $schedulingItem) { item in
            ScheduleSheet(url: item.url, title: item.displayTitle,
                          thumbnail: item.thumbnail, format: item.format)
        }
        // Playlist picker - fetches and shows items for a saved playlist
        .sheet(item: $playlistPickerItem) { item in
            PlaylistPickerSheet(watchLaterItem: item)
                .environmentObject(queue)
                .environmentObject(watchLater)
        }
        // Prompt shown when a playlist URL is pasted into the quick-add bar
        .alert("Save as Playlist or Single Video?", isPresented: $showPlaylistPrompt) {
            Button("Full Playlist") {
                watchLater.add(url: playlistPromptURL, isPlaylist: true)
                playlistPromptURL = ""
            }
            Button("Just This Video") {
                watchLater.add(url: playlistPromptURL, isPlaylist: false)
                playlistPromptURL = ""
            }
            Button("Cancel", role: .cancel) { playlistPromptURL = "" }
        } message: {
            Text("This looks like a playlist link. Do you want to save the full playlist (choose videos later) or treat it as a single video?")
        }
    }

    private func quickAdd() {
        guard addURLText.lowercased().hasPrefix("http") else { return }
        if DownloadJob.looksLikePlaylist(addURLText) {
            playlistPromptURL = addURLText
            addURLText = ""
            showPlaylistPrompt = true
        } else {
            watchLater.add(url: addURLText)
            addURLText = ""
        }
    }

    // FIX #7: Download a single Watch Later item (used by bulk select)
    private func downloadItem(_ item: WatchLaterItem) {
        let job = DownloadJob()
        job.url    = item.url
        job.format = item.format
        job.sponsorBlockOverride = settings.watchLaterSponsorBlock ? true : nil
        job.downloadSubs         = settings.watchLaterSubtitles
        job.subLang              = settings.defaultSubLang
        if !item.title.isEmpty || !item.thumbnail.isEmpty {
            job.meta = VideoMeta(
                title: item.title,
                thumbnail: item.thumbnail,
                duration: "", durationH: "", durationM: "", durationS: "",
                hasSubs: false
            )
            job.metaState = .done
        }
        queue.addJobSilent(job)
        watchLater.remove(item)
    }

    private func downloadAll() {
        for item in watchLater.items {
            let job = DownloadJob()
            job.url    = item.url
            job.format = item.format
            // Apply Watch Later global toggles
            job.sponsorBlockOverride = settings.watchLaterSponsorBlock ? true : nil
            job.downloadSubs         = settings.watchLaterSubtitles
            job.subLang              = settings.defaultSubLang
            // Pre-populate meta so history shows the saved title + thumbnail
            if !item.title.isEmpty || !item.thumbnail.isEmpty {
                job.meta = VideoMeta(
                    title: item.title,
                    thumbnail: item.thumbnail,
                    duration: "", durationH: "", durationM: "", durationS: "",
                    hasSubs: false
                )
                job.metaState = .done
            }
            queue.addJobSilent(job)
        }
        watchLater.removeAll()
        withAnimation { settings.appModeRaw = AppMode.video.rawValue }
        queue.ensureOutputDir()
        queue.downloadAll()
        Haptics.success()
    }
}

// MARK: - Watch Later Toggle Chip

struct WLToggleChip: View {
    let label      : String
    let icon       : String
    let active     : Bool
    var activeColor: Color = .accentColor
    let action     : () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: {
            action()
            active ? Haptics.toggleOff() : Haptics.toggleOn()
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(active ? activeColor : Color.primary.opacity(0.5))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? activeColor.opacity(0.12) : Color.primary.opacity(hovered ? 0.06 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? activeColor.opacity(0.35) : Color(.separatorColor).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: active)
        .help(active ? "\(label) ON - click to disable" : "\(label) OFF - click to enable")
    }
}

// MARK: - Scheduled Item Row (shown inline in Watch Later tab)

struct WatchLaterScheduledRow: View {
    let item: ScheduledDownload
    @StateObject private var clock = RowClock()

    private var secondsUntil: Int { max(0, Int(item.scheduledAt.timeIntervalSince(clock.now))) }
    private var isImminent: Bool { secondsUntil < 60 }

    private var countdown: String {
        let s = secondsUntil
        guard s > 0 else { return "Starting…" }
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        if h > 0 { return "\(h)h \(m)m \(sec)s" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 46, height: 46)
                Image(systemName: "clock.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.scheduledAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(countdown)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isImminent ? Color.orange : Color.accentColor)
                }
            }

            Spacer(minLength: 0)

            Button {
                ScheduledDownloadStore.shared.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.2))
            }
            .buttonStyle(.plain)
            .help("Cancel scheduled download")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5))
    }
}

/// A stable ObservableObject clock - survives SwiftUI struct recreation.
/// Each row owns one; the timer keeps ticking regardless of re-renders.
final class RowClock: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
    }
    deinit { timer?.invalidate() }
}

// MARK: - Watch Later Row

struct WatchLaterRow: View {
    let item: WatchLaterItem
    var onSchedule: () -> Void = {}
    var onPlaylistPick: () -> Void = {}
    @EnvironmentObject var watchLater : WatchLaterStore
    @EnvironmentObject var queue      : DownloadQueue
    @EnvironmentObject var settings   : SettingsManager
    @State private var hovered             = false
    @State private var dismissedDuplicate  = false

    private var isFetchingMeta: Bool { item.title.isEmpty && !item.isPlaylist }

    private var duplicateEntry: HistoryEntry? {
        guard !dismissedDuplicate else { return nil }
        return HistoryStore.shared.existingEntry(for: item.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Drag handle - visible on hover so user knows rows are reorderable
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovered ? 0.22 : 0.0))
                    .frame(width: 14)
                    .animation(.easeOut(duration: 0.15), value: hovered)

            // Thumbnail - larger and shows loading state
            ZStack {
                if item.isPlaylist {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            VStack(spacing: 3) {
                                Image(systemName: "list.number")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                Text("Playlist")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                            }
                        )
                } else if !item.thumbnail.isEmpty {
                    CachedThumb(urlString: item.thumbnail, width: 80, height: 46, radius: 6,
                                placeholder: AnyView(thumbPlaceholder))
                } else {
                    thumbPlaceholder
                    if isFetchingMeta {
                        ProgressView().scaleEffect(0.55)
                    }
                }
            }
            .frame(width: 80, height: 46)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                if isFetchingMeta {
                    // Skeleton placeholder while fetching
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 180, height: 12)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.05))
                        .frame(width: 100, height: 10)
                } else {
                    Text(item.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.addedAt.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        if item.isPlaylist {
                            if !item.cachedPlaylistItems.isEmpty {
                                Label("\(item.cachedPlaylistItems.count) videos", systemImage: "list.number")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                            } else {
                                HStack(spacing: 4) {
                                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                                    Text("Fetching…")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text(item.format.displayName)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    // FIX #2: Tag chips
                    WatchLaterTagEditor(item: item)
                }
            }

            Spacer(minLength: 0)

            // Actions
            HStack(spacing: 6) {
                if item.isPlaylist {
                    // Playlist: open picker to choose videos
                    Button {
                        onPlaylistPick()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.circle.fill")
                                .font(.system(size: 15))
                            Text("Pick Videos")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).help("Choose videos to download or schedule")
                } else {
                    // Single video: existing behaviour
                    Button {
                        let job = DownloadJob()
                        job.url    = item.url
                        job.format = item.format
                        // Apply Watch Later global toggles
                        let sm = SettingsManager.shared
                        job.sponsorBlockOverride = sm.watchLaterSponsorBlock ? true : nil
                        job.downloadSubs         = sm.watchLaterSubtitles
                        job.subLang              = sm.defaultSubLang
                        if !item.title.isEmpty || !item.thumbnail.isEmpty {
                            job.meta = VideoMeta(
                                title: item.title,
                                thumbnail: item.thumbnail,
                                duration: "", durationH: "", durationM: "", durationS: "",
                                hasSubs: false
                            )
                            job.metaState = .done
                        }
                        queue.addJobSilent(job)
                        queue.ensureOutputDir()
                        DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
                        watchLater.remove(item)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain).help("Download now")

                    Button { onSchedule() } label: {
                        Image(systemName: "alarm")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("Schedule download")
                }

                Button { withAnimation { watchLater.remove(item) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(hovered ? Color.primary.opacity(0.45) : Color.primary.opacity(0.12))
                }
                .buttonStyle(.plain).help("Remove")
            }
        }
            .padding(.horizontal, 14).padding(.vertical, 10)

            // Duplicate banner - shown when this URL was already downloaded
            if let dup = duplicateEntry {
                Divider().opacity(0.06).padding(.horizontal, 14)
                DuplicateWarningBanner(
                    entry: dup,
                    onDismiss: { dismissedDuplicate = true },
                    onReveal:  { dismissedDuplicate = true },
                    onRemove:  { withAnimation { watchLater.remove(item) } }
                )
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovered ? 0.05 : 0)))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    var thumbPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.07))
            .overlay(Image(systemName: "bookmark.fill").font(.system(size: 14)).foregroundStyle(.secondary.opacity(0.25)))
    }
}

// MARK: - Playlist Picker Sheet

struct PlaylistPickerSheet: View {
    let watchLaterItem: WatchLaterItem
    @EnvironmentObject var queue      : DownloadQueue
    @EnvironmentObject var watchLater : WatchLaterStore
    @Environment(\.dismiss) private var dismiss

    enum FetchState { case idle, fetching, ready, failed(String) }

    @State private var fetchState   : FetchState     = .idle
    @State private var items        : [PlaylistItem] = []
    @State private var selectionTick: Int            = 0
    @State private var scheduleDate : Date?          = nil
    @State private var showSchedulePicker = false

    var selectedItems: [PlaylistItem] {
        let _ = selectionTick
        return items.filter(\.selected)
    }

    var allSelected: Bool { items.allSatisfy(\.selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick Videos")
                        .font(.system(size: 15, weight: .semibold))
                    Text(watchLaterItem.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                    Text(watchLaterItem.url)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            Divider().opacity(0.1)

            // ── Body ─────────────────────────────────────────────────────
            switch fetchState {

            case .idle:
                // Use cache if available, otherwise fetch
                Color.clear.onAppear {
                    if !watchLaterItem.cachedPlaylistItems.isEmpty {
                        items = watchLaterItem.cachedPlaylistItems.map { $0.toPlaylistItem() }
                        fetchState = .ready
                    } else {
                        fetchPlaylist()
                    }
                }

            case .fetching:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Fetching playlist…")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32)).foregroundStyle(.orange)
                    Text("Couldn't load playlist")
                        .font(.system(size: 14, weight: .semibold))
                    Text(msg)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { fetchPlaylist() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                // Select all / count bar
                HStack(spacing: 10) {
                    Button {
                        let newValue = !allSelected
                        items.forEach { $0.selected = newValue }
                        selectionTick += 1
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(allSelected ? Color.accentColor : .secondary)
                            Text(allSelected ? "Deselect All" : "Select All")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("\(selectedItems.count) of \(items.count) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button {
                        fetchState = .idle
                        items = []
                        fetchPlaylist()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Re-fetch playlist (picks up new videos)")
                }
                .padding(.horizontal, 20).padding(.vertical, 10)

                Divider().opacity(0.08)

                // Item list
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            WLPlaylistItemRow(item: item, onToggle: { selectionTick += 1 })
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }

                Divider().opacity(0.08)

                // ── Action bar ──────────────────────────────────────────
                HStack(spacing: 10) {
                    Text(selectedItems.isEmpty ? "Select videos above" : "\(selectedItems.count) video\(selectedItems.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Schedule Selected
                    Button {
                        guard !selectedItems.isEmpty else { return }
                        showSchedulePicker = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "alarm")
                                .font(.system(size: 12))
                            Text("Schedule")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(selectedItems.isEmpty ? .secondary : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.primary.opacity(selectedItems.isEmpty ? 0.04 : 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedItems.isEmpty)

                    // Download Selected
                    Button {
                        downloadSelected()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 12))
                            Text("Download Now")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selectedItems.isEmpty ? Color.secondary : Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedItems.isEmpty)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .frame(width: 520, height: 560)
        // Schedule date picker sheet
        .sheet(isPresented: $showSchedulePicker) {
            WLPlaylistScheduleSheet(
                items: selectedItems,
                playlistURL: watchLaterItem.url,
                onScheduled: {
                    watchLater.remove(watchLaterItem)
                    dismiss()
                }
            )
        }
    }

    private func fetchPlaylist() {
        fetchState = .fetching
        Task {
            let result = await DownloadService.shared.fetchPlaylist(url: watchLaterItem.url)
            await MainActor.run {
                switch result {
                case .success(let fetched):
                    items = fetched
                    fetchState = .ready
                    // Write back to cache so next open is instant
                    let cached = fetched.map {
                        CachedPlaylistItem(index: $0.index, videoID: $0.videoID,
                                           title: $0.title, duration: $0.duration, thumbnail: $0.thumbnail)
                    }
                    watchLater.updateCache(id: watchLaterItem.id, items: cached)
                case .failure(let err):
                    fetchState = .failed(err.localizedDescription)
                }
            }
        }
    }

    private func downloadSelected() {
        guard !selectedItems.isEmpty else { return }
        let baseURL = watchLaterItem.url
        let sm = SettingsManager.shared
        queue.ensureOutputDir()
        for item in selectedItems {
            // Apply Watch Later global toggles to each playlist item
            item.sponsorBlock = sm.watchLaterSponsorBlock
            item.downloadSubs = sm.watchLaterSubtitles
            item.subLang      = sm.watchLaterSubtitles ? sm.defaultSubLang : ""
            DownloadService.shared.startPlaylistItem(
                item, baseURL: baseURL, outputDir: queue.outputDirectory)
        }
        watchLater.remove(watchLaterItem)
        dismiss()
        Haptics.success()
    }
}

// MARK: - Lightweight playlist item row (no clip/sponsorblock controls)

struct WLPlaylistItemRow: View {
    @ObservedObject var item: PlaylistItem
    var onToggle: () -> Void = {}
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Checkbox
            Button {
                item.selected.toggle()
                onToggle()
                item.selected ? Haptics.toggleOn() : Haptics.toggleOff()
            } label: {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.selected ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Thumbnail
            Group {
                if !item.thumbnail.isEmpty {
                    AsyncImage(url: URL(string: item.thumbnail)) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            wlThumbPlaceholder
                        }
                    }
                } else {
                    wlThumbPlaceholder
                }
            }
            .frame(width: 60, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))

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
                    if !item.duration.isEmpty {
                        Text(item.duration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.leading, 10)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
        .contentShape(Rectangle())
        .onTapGesture {
            item.selected.toggle()
            onToggle()
            item.selected ? Haptics.toggleOn() : Haptics.toggleOff()
        }
    }

    var wlThumbPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(0.07))
            .overlay(Image(systemName: "film").font(.system(size: 12)).foregroundStyle(.tertiary))
    }
}

// MARK: - Playlist Schedule Sheet (picks a single time, schedules all selected videos)

struct WLPlaylistScheduleSheet: View {
    let items: [PlaylistItem]
    let playlistURL: String
    var onScheduled: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ScheduleModel

    init(items: [PlaylistItem], playlistURL: String, onScheduled: @escaping () -> Void) {
        self.items = items
        self.playlistURL = playlistURL
        self.onScheduled = onScheduled
        _model = StateObject(wrappedValue: ScheduleModel(initialDate: Date().addingTimeInterval(3600)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule Downloads")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(items.count) video\(items.count == 1 ? "" : "s") will start at the same time")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(18)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 16) {
                // Quick presets
                Text("QUICK PRESETS")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    ForEach(model.quickPresets, id: \.label) { p in
                        Button { model.applyPreset(p) } label: {
                            Text(p.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(model.activePreset == p.mins ? Color.accentColor : .primary.opacity(0.7))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(model.activePreset == p.mins
                                    ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }

                Divider().opacity(0.4)

                Text("CUSTOM TIME")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                NativeDatePicker(date: $model.selectedDate).frame(height: 22)

                // Countdown
                HStack(spacing: 6) {
                    Image(systemName: model.isValid ? "clock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(model.isValid ? Color.accentColor : Color.orange)
                    Text(model.countdownText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.isValid ? Color.primary : Color.orange)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((model.isValid ? Color.accentColor : Color.orange).opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Video list summary
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "film")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                                Text(item.title)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 80)
                .padding(.horizontal, 4)

                // Confirm
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Mac's local time:")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.selectedDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    Button {
                        guard model.isValid else { model.error = "Pick a future time."; return }
                        // Schedule each selected video individually so ScheduledDownloadStore handles them normally
                        for item in items {
                            let videoURL: String
                            if playlistURL.contains("youtube.com") || playlistURL.contains("youtu.be") {
                                videoURL = "https://www.youtube.com/watch?v=\(item.videoID)"
                            } else {
                                videoURL = playlistURL
                            }
                            ScheduledDownloadStore.shared.schedule(
                                url: videoURL,
                                title: item.title,
                                thumbnail: item.thumbnail,
                                format: .best,
                                at: model.selectedDate,
                                sponsorBlock: SettingsManager.shared.watchLaterSponsorBlock,
                                subtitles: SettingsManager.shared.watchLaterSubtitles
                            )
                        }
                        onScheduled()
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                            Text("Schedule \(items.count) Video\(items.count == 1 ? "" : "s")")
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(model.isValid ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .frame(width: 420)
    }
}

// MARK: - Native Date Picker (AppKit - immune to SwiftUI re-render resets)

/// Wraps NSDatePicker so SwiftUI can never reset the selected date.
/// The binding is only written when the user actually changes the picker.
struct NativeDatePicker: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle    = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue          = date
        picker.isBezeled          = true
        picker.isBordered         = true
        picker.target             = context.coordinator
        picker.action             = #selector(Coordinator.dateChanged(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        // Only push the value in if it differs by more than 60s
        // - prevents SwiftUI from overwriting what the user is typing
        if abs(picker.dateValue.timeIntervalSince(date)) > 60 {
            picker.dateValue = date
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: NativeDatePicker
        init(_ parent: NativeDatePicker) { self.parent = parent }
        @objc func dateChanged(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
        }
    }
}

// MARK: - Schedule Sheet

struct ScheduleSheet: View {
    let url: String
    let title: String
    let thumbnail: String
    let format: DownloadFormat
    @Environment(\.dismiss) private var dismiss

    // Owned by an ObservableObject so SwiftUI struct recreation can never reset it
    @StateObject private var model: ScheduleModel

    init(url: String, title: String, thumbnail: String, format: DownloadFormat) {
        self.url       = url
        self.title     = title
        self.thumbnail = thumbnail
        self.format    = format
        let base = Date().addingTimeInterval(3600)
        _model = StateObject(wrappedValue: ScheduleModel(initialDate: base))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Schedule Download").font(.system(size: 15, weight: .semibold))
                    Text(title.isEmpty ? url : title)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(18)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 16) {

                // Quick presets
                Text("QUICK PRESETS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    ForEach(model.quickPresets, id: \.label) { p in
                        Button {
                            model.applyPreset(p)
                        } label: {
                            Text(p.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(model.activePreset == p.mins ? Color.accentColor : .primary.opacity(0.7))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(model.activePreset == p.mins
                                    ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(model.activePreset == p.mins
                                        ? Color.accentColor.opacity(0.3)
                                        : Color(.separatorColor).opacity(0.3), lineWidth: 0.5))
                        }.buttonStyle(.plain)
                    }
                }

                Divider().opacity(0.4)

                // Native AppKit date picker - SwiftUI cannot reset this
                Text("CUSTOM TIME").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                NativeDatePicker(date: $model.selectedDate)
                    .frame(height: 22)

                // Live countdown
                HStack(spacing: 6) {
                    Image(systemName: model.isValid ? "clock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(model.isValid ? Color.accentColor : Color.orange)
                    Text(model.countdownText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(model.isValid ? Color.primary : Color.orange)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background((model.isValid ? Color.accentColor : Color.orange).opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let err = model.error {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }

                // Confirm
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your Mac's local time:")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.selectedDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer()
                    Button {
                        guard model.isValid else { model.error = "Pick a future time."; return }
                        ScheduledDownloadStore.shared.schedule(
                            url: url, title: title, thumbnail: thumbnail,
                            format: format, at: model.selectedDate,
                            sponsorBlock: SettingsManager.shared.watchLaterSponsorBlock,
                            subtitles: SettingsManager.shared.watchLaterSubtitles)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle")
                            Text("Schedule")
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(model.isValid ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .frame(width: 420)
    }
}

// MARK: - Schedule Model (ObservableObject - survives SwiftUI re-renders)

final class ScheduleModel: ObservableObject {
    @Published var selectedDate: Date { didSet { activePreset = nil; error = nil } }
    @Published var activePreset: Int? = nil
    @Published var error: String? = nil
    private var ticker: Timer?

    // Tick every second to update countdown
    @Published private(set) var now: Date = Date()

    let quickPresets: [(label: String, mins: Int)] = [
        ("30 min", 30), ("1 hour", 60), ("3 hours", 180),
        ("Tonight 10pm", -1), ("Tomorrow 8am", -2)
    ]

    init(initialDate: Date) {
        // Round to nearest minute
        var comps = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: initialDate)
        comps.second = 0
        self.selectedDate = Calendar.current.date(from: comps) ?? initialDate
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            self?.now = Date()
        }
    }

    deinit { ticker?.invalidate() }

    var secondsUntil: Int { max(0, Int(selectedDate.timeIntervalSince(now))) }
    var isValid: Bool { selectedDate > now }

    var countdownText: String {
        let s = secondsUntil
        guard s > 0 else { return "That time has passed - pick a future time" }
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        if h > 0 { return "Starts in \(h)h \(m)m \(sec)s" }
        if m > 0 { return "Starts in \(m)m \(sec)s" }
        return "Starts in \(sec)s"
    }

    func applyPreset(_ p: (label: String, mins: Int)) {
        let base = Date()
        switch p.mins {
        case -1:
            var c = Calendar.current.dateComponents([.year,.month,.day], from: base)
            c.hour = 22; c.minute = 0; c.second = 0
            selectedDate = Calendar.current.date(from: c) ?? base.addingTimeInterval(3600)
        case -2:
            let tom = base.addingTimeInterval(86400)
            var c = Calendar.current.dateComponents([.year,.month,.day], from: tom)
            c.hour = 8; c.minute = 0; c.second = 0
            selectedDate = Calendar.current.date(from: c) ?? tom
        default:
            selectedDate = base.addingTimeInterval(Double(p.mins) * 60)
        }
        activePreset = p.mins
    }
}

// MARK: - Clipboard Detection Banner

struct ClipboardBanner: View {
    @EnvironmentObject var clipMonitor : ClipboardMonitor
    @EnvironmentObject var queue       : DownloadQueue
    @EnvironmentObject var settings    : SettingsManager
    @EnvironmentObject var watchLater  : WatchLaterStore

    var body: some View {
        if clipMonitor.showBanner {
            HStack(spacing: 10) {
                // Site icon area
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(clipMonitor.siteName) link detected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(clipMonitor.detectedURL)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 200)
                }

                Spacer(minLength: 8)

                // Actions
                HStack(spacing: 5) {
                    Button {
                        let url = clipMonitor.detectedURL
                        let isPlaylist = DownloadJob.looksLikePlaylist(url)
                        watchLater.add(url: url, isPlaylist: isPlaylist)
                        clipMonitor.dismiss()
                    } label: {
                        Text("Later")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.7))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Button {
                        let url = clipMonitor.acceptURL()
                        withAnimation { settings.appModeRaw = AppMode.video.rawValue }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let empty = queue.jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
                                empty.url = url
                            } else {
                                queue.addJob(url: url)
                            }
                        }
                    } label: {
                        Text("Download")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Button { clipMonitor.dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Text("Snooze clipboard monitor")
                        Divider()
                        Button("5 minutes")  { clipMonitor.snooze(.fiveMinutes);   Haptics.tap() }
                        Button("30 minutes") { clipMonitor.snooze(.thirtyMinutes); Haptics.tap() }
                        Button("Until tomorrow") { clipMonitor.snooze(.untilTomorrow); Haptics.tap() }
                        if let frontApp = NSWorkspace.shared.frontmostApplication,
                           let bid = frontApp.bundleIdentifier,
                           let name = frontApp.localizedName {
                            Divider()
                            Button("While \(name) is active") {
                                clipMonitor.snooze(.thisApp(bid)); Haptics.tap()
                            }
                        }
                        // FIX #5: Per-site domain snooze
                        if let domain = clipMonitor.detectedDomain {
                            Divider()
                            Button("This session for \(domain)") {
                                clipMonitor.snooze(.thisDomain(domain)); Haptics.tap()
                            }
                        }
                    } label: {
                        Image(systemName: clipMonitor.isSnoozed ? "bell.slash.fill" : "bell.slash")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(clipMonitor.isSnoozed ? Color.orange : .secondary.opacity(0.5))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(clipMonitor.snoozeLabel ?? "Snooze - temporarily silence clipboard detection")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 4)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Duplicate Warning Banner (shown on JobCard)

// MARK: - Drag-to-reorder drop delegate

struct WatchLaterDropDelegate: DropDelegate {
    let targetItem: WatchLaterItem
    let store: WatchLaterStore
    @Binding var draggedID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let id = draggedID,
              id != targetItem.id,
              let from = store.items.firstIndex(where: { $0.id == id }),
              let to   = store.items.firstIndex(where: { $0.id == targetItem.id })
        else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            store.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct DuplicateWarningBanner: View {
    let entry: HistoryEntry
    let onDismiss: () -> Void   // "Download anyway" - keep in queue, suppress warning
    let onReveal: () -> Void    // "Show file" - open Finder, suppress warning
    var onRemove: (() -> Void)? = nil  // "Remove" - pull the card out of the queue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Already downloaded")
                    .font(.system(size: 12, weight: .medium))
                Text(entry.date.formatted(.relative(presentation: .named)) + " · " + entry.format)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()

            // Show File - reveal in Finder
            Button("Show File") {
                let fileURL = URL(fileURLWithPath: entry.outputPath)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } else {
                    // File moved or deleted - open the folder instead
                    NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
                }
                onReveal()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            .padding(.horizontal, 9).frame(height: 26)
            .background(.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.orange.opacity(0.2), lineWidth: 0.5))

            // Remove from queue
            if let onRemove {
                Button("Remove") { onRemove() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(.red.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.red.opacity(0.18), lineWidth: 0.5))
            }

            // Download anyway - keeps the card, hides the warning
            Button("Download Anyway") { onDismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(.orange.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - FIX #2: Watch Later Tag Editor

struct WatchLaterTagEditor: View {
    let item: WatchLaterItem
    @EnvironmentObject var watchLater: WatchLaterStore
    @State private var isEditing = false
    @State private var newTag = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Existing tags
            ForEach(item.tags, id: \.self) { tag in
                HStack(spacing: 3) {
                    Text(tag)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Button {
                        var tags = item.tags
                        tags.removeAll { $0 == tag }
                        watchLater.updateTags(id: item.id, tags: tags)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            }

            // Add tag button / inline input
            if isEditing {
                HStack(spacing: 3) {
                    TextField("tag…", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9.5))
                        .frame(width: 60)
                        .focused($focused)
                        .onSubmit { commitTag() }
                    Button { commitTag() } label: {
                        Image(systemName: "return")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 0.5))
                .onAppear { focused = true }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { isEditing = true }
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add tag")
            }
        }
        .animation(.easeOut(duration: 0.12), value: isEditing)
    }

    private func commitTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        if !tag.isEmpty && !item.tags.contains(tag) {
            var tags = item.tags
            tags.append(tag)
            watchLater.updateTags(id: item.id, tags: tags)
        }
        newTag = ""
        isEditing = false
        focused = false
    }
}
