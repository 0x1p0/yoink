import SwiftUI
import UniformTypeIdentifiers

// MARK: - History View

struct HistoryView: View {
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var store = HistoryStore.shared
    @State private var search = ""
    @State private var confirmClear = false
    @State private var missingIDs: Set<UUID> = []
    @State private var confirmRemoveMissing = false

    // FIX #4: site/format filter
    @State private var siteFilter: String = "All"
    @State private var formatFilter: String = "All"

    /// Unique site hostnames present in history
    private var availableSites: [String] {
        var seen = Set<String>()
        var sites: [String] = []
        for entry in store.entries {
            if let host = URLComponents(string: entry.url)?.host {
                let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let site = bare.components(separatedBy: ".").first.map { $0.capitalized } ?? bare
                if seen.insert(site).inserted { sites.append(site) }
            }
        }
        return sites.sorted()
    }

    /// Format families present in history
    private var availableFormats: [String] {
        var seen = Set<String>()
        var fmts: [String] = []
        for entry in store.entries {
            let family: String
            let low = entry.format.lowercased()
            if low.contains("audio") || low.contains("mp3") || low.contains("m4a") || low.contains("opus") {
                family = "Audio"
            } else {
                family = "Video"
            }
            if seen.insert(family).inserted { fmts.append(family) }
        }
        return fmts.sorted()
    }

    var filtered: [HistoryEntry] {
        store.entries.filter { entry in
            // Text search
            let textOK = search.isEmpty ||
                entry.title.localizedCaseInsensitiveContains(search) ||
                entry.url.localizedCaseInsensitiveContains(search)
            // Site filter
            let siteOK: Bool
            if siteFilter == "All" {
                siteOK = true
            } else if let host = URLComponents(string: entry.url)?.host {
                let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                let site = bare.components(separatedBy: ".").first.map { $0.capitalized } ?? bare
                siteOK = site == siteFilter
            } else {
                siteOK = false
            }
            // Format filter
            let fmtOK: Bool
            if formatFilter == "All" {
                fmtOK = true
            } else {
                let low = entry.format.lowercased()
                let isAudio = low.contains("audio") || low.contains("mp3") || low.contains("m4a") || low.contains("opus")
                fmtOK = formatFilter == "Audio" ? isAudio : !isAudio
            }
            return textOK && siteOK && fmtOK
        }
    }

    // FIX #8: Export history as JSON
    func exportHistory() {
        struct ExportEntry: Codable {
            let title: String
            let url: String
            let format: String
            let date: String
            let path: String
            let fileSize: Int64
        }
        let iso = ISO8601DateFormatter()
        let exports = store.entries.map { e in
            ExportEntry(title: e.title, url: e.url, format: e.format,
                        date: iso.string(from: e.date), path: e.outputPath, fileSize: e.fileSize)
        }
        guard let data = try? JSONEncoder().encode(exports),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.nameFieldStringValue = "yoink-history.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? jsonStr.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func refreshMissingStatus() {
        // outputPath is the actual media file path - just check if it exists on disk
        var missing = Set<UUID>()
        for entry in store.entries {
            if !FileManager.default.fileExists(atPath: entry.outputPath) {
                missing.insert(entry.id)
            }
        }
        missingIDs = missing
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────────
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("Search history…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 13))
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))

                Text("\(filtered.count) item\(filtered.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                Spacer()

                if !missingIDs.isEmpty {
                    Button {
                        confirmRemoveMissing = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text("\(missingIDs.count) missing")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("\(missingIDs.count) file(s) were moved or deleted. Click to remove from history.")
                    .confirmationDialog(
                        "Remove \(missingIDs.count) missing file(s) from history?",
                        isPresented: $confirmRemoveMissing,
                        titleVisibility: .visible
                    ) {
                        Button("Remove Missing", role: .destructive) {
                            withAnimation(.spring(response: 0.25)) {
                                for id in missingIDs { store.removeByID(id) }
                                missingIDs = []
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("These files were moved or deleted from disk. Their history entries will be removed.")
                    }
                }

                if !store.entries.isEmpty {
                    // FIX #8: Export history to JSON/CSV
                    Button {
                        exportHistory()
                    } label: {
                        Text("Export…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Export history as JSON")
                }

                if !store.entries.isEmpty {
                    Button {
                        confirmClear = true
                    } label: {
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red.opacity(0.8))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Clear all download history?", isPresented: $confirmClear) {
                        Button("Clear All", role: .destructive) { store.clearAll() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider().opacity(0.08)

            // FIX #4: Site + Format filter pills
            if availableSites.count > 1 || availableFormats.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Format pills
                        if availableFormats.count > 1 {
                            ForEach(["All"] + availableFormats, id: \.self) { fmt in
                                FilterPill(label: fmt, selected: formatFilter == fmt) {
                                    withAnimation(.easeOut(duration: 0.15)) { formatFilter = fmt }
                                }
                            }
                            if availableSites.count > 1 {
                                Divider().frame(height: 16).opacity(0.4)
                            }
                        }
                        // Site pills
                        if availableSites.count > 1 {
                            ForEach(["All"] + availableSites, id: \.self) { site in
                                FilterPill(label: site, selected: siteFilter == site) {
                                    withAnimation(.easeOut(duration: 0.15)) { siteFilter = site }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                Divider().opacity(0.08)
            }

            // ── List ─────────────────────────────────────────────────────
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.4))
                    Text(search.isEmpty ? "No downloads yet" : "No results for \"\(search)\"")
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    if search.isEmpty {
                        Text("Completed downloads will appear here")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { entry in
                            HistoryRow(entry: entry, isMissing: missingIDs.contains(entry.id))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .onAppear { refreshMissingStatus() }
        // Re-check when entries are added/removed (new download, manual delete from history)
        .onReceive(store.$entries) { _ in refreshMissingStatus() }
        // Poll every 3 seconds to catch external file deletions from Finder
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshMissingStatus()
        }
        // Also re-check when app comes back to foreground
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMissingStatus()
        }
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let entry: HistoryEntry
    var isMissing: Bool = false
    @ObservedObject private var store = HistoryStore.shared
    @State private var hovered = false

    /// The actual video/audio file for this entry - outputPath IS the file path directly.
    private var mediaFile: URL? {
        let url = URL(fileURLWithPath: entry.outputPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Live size of the media file from disk.
    private var liveFileSize: Int64 {
        guard let file = mediaFile else { return 0 }
        let sz = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(sz)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail - dimmed if file is missing
            CachedThumb(urlString: entry.thumbnail, width: 64, height: 38, radius: 5,
                        placeholder: AnyView(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.07))
                                .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                        ))
            .opacity(isMissing ? 0.45 : 1.0)
            .overlay(
                Group {
                    if isMissing {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
                    }
                }
            )

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isMissing ? Color.secondary : Color.primary)
                    if isMissing {
                        Label("Moved or deleted", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .labelStyle(.iconOnly)
                            .help("File was moved or deleted from disk")
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    let size = liveFileSize
                    if size > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(entry.format)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if isMissing {
                        Text("·").foregroundStyle(.tertiary)
                        Text("File not found")
                            .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }

            Spacer(minLength: 0)

            // Actions
            HStack(spacing: 6) {
                // Copy URL to clipboard
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.url, forType: .string)
                    Haptics.tap()
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Copy URL")

                // Re-download - pre-fills a new card with same URL
                Button {
                    NotificationCenter.default.post(
                        name: .redownloadEntry,
                        object: entry.url
                    )
                    Haptics.start()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Re-download")

                // Show in Finder (disabled if missing)
                Button {
                    if let file = mediaFile {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: entry.outputPath).deletingLastPathComponent())
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(!isMissing ? Color.accentColor : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help(!isMissing ? "Show in Finder" : "File was moved or deleted")
                .disabled(isMissing)

                // Remove from history
                Button {
                    withAnimation(.spring(response: 0.25)) { store.remove(entry) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(hovered ? Color.primary.opacity(0.5) : Color.primary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isMissing
                    ? Color.orange.opacity(hovered ? 0.07 : 0.04)
                    : Color.primary.opacity(hovered ? 0.05 : 0))
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// MARK: - FIX #4: Filter Pill

struct FilterPill: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    Capsule().fill(selected
                        ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(hovered ? 0.07 : 0.05))
                )
                .overlay(Capsule().strokeBorder(
                    selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}
