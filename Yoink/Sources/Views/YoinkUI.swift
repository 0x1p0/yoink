import SwiftUI
import AppKit

// MARK: - Shared UI building blocks
//
// Small, reusable pieces shared by the main window and the menu bar popover so both
// surfaces speak the same visual language: quiet chrome, one accent action per area,
// and options that only appear when they're relevant.

// MARK: Option chip

/// A compact toggle chip ("Subtitles", "SponsorBlock", "Clip"). Accent-tinted when on.
struct OptionChip: View {
    let title: String
    let icon: String
    let isOn: Bool
    var help: String? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.14)
                               : Color.primary.opacity(hovered ? 0.08 : 0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.35)
                                       : Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? title)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: Quiet icon button

/// Borderless icon button with a soft hover plate — for secondary row / header actions.
struct QuietIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 26
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tint ?? (hovered ? Color.primary.opacity(0.9) : Color.secondary))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: Section header

struct SectionTitle: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
    }
}

// MARK: Save location menu

/// One control for "where do downloads go": the current folder, output categories,
/// a folder picker, and a shortcut to open the folder in Finder.
struct SaveLocationMenu: View {
    @EnvironmentObject var queue: DownloadQueue
    @EnvironmentObject var settings: SettingsManager
    /// Smaller label for the menu bar popover footer.
    var compact: Bool = false
    @State private var hovered = false

    private var categories: [OutputCategory] { settings.outputCategories.filter { !$0.path.isEmpty } }
    private var activeCategory: OutputCategory? {
        categories.first { URL(fileURLWithPath: $0.path) == queue.outputDirectory }
    }
    private var title: String {
        if let cat = activeCategory { return "\(cat.emoji) \(cat.name)" }
        return queue.outputDirectory.lastPathComponent
    }

    var body: some View {
        Menu {
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories) { cat in
                        Button {
                            queue.outputDirectory = URL(fileURLWithPath: cat.path)
                            Haptics.tap()
                        } label: {
                            if activeCategory?.id == cat.id {
                                Label("\(cat.emoji) \(cat.name)", systemImage: "checkmark")
                            } else {
                                Text("\(cat.emoji) \(cat.name)")
                            }
                        }
                    }
                }
            }
            Button("Choose Folder…") { pickFolder() }
            Button("Show in Finder") {
                queue.ensureOutputDir()
                NSWorkspace.shared.open(queue.outputDirectory)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: compact ? 10.5 : 11.5))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: compact ? 150 : 170, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: compact ? 26 : 30)
            .background(
                RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.08 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .compactMenuStyle()
        .onHover { hovered = $0 }
        .help("Saving to \(queue.outputDirectory.path)")
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = queue.outputDirectory
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            queue.outputDirectory = url
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }
}

// MARK: Engine status

extension DependencyService {
    /// True when both engines can run downloads.
    var enginesReady: Bool { ytdlp.isReady && ffmpeg.isReady }

    /// True when an engine is broken (not merely still checking).
    var enginesFailed: Bool {
        func bad(_ s: DepStatus) -> Bool {
            switch s { case .missing, .failed: return true; default: return false }
        }
        return bad(ytdlp) || bad(ffmpeg)
    }

    /// The colour that best summarises both engines — green only when all is well.
    var enginesDotColor: Color {
        if enginesFailed { return .red }
        if enginesReady {
            if case .updating = ytdlp { return .orange }
            if case .updating = ffmpeg { return .orange }
            return .green
        }
        return .orange
    }

    var enginesSummary: String {
        if enginesFailed { return "Engine problem" }
        if !enginesReady { return "Preparing engines…" }
        if case .updating = ytdlp { return "Updating yt-dlp…" }
        if case .updating = ffmpeg { return "Updating ffmpeg…" }
        return "Engines ready"
    }
}

/// A single status pill replacing the two always-visible "ffmpeg / yt-dlp" pills.
/// Quiet when everything is fine; tinted when something needs attention.
struct EngineStatusMenu: View {
    @EnvironmentObject var deps: DependencyService
    let onShowYtdlp: () -> Void
    let onShowFfmpeg: () -> Void
    @State private var hovered = false
    @State private var pulse = false

    private var busy: Bool { !deps.enginesReady && !deps.enginesFailed }

    var body: some View {
        Menu {
            Button("yt-dlp — \(deps.ytdlp.statusLabel)") { onShowYtdlp() }
            Button("ffmpeg — \(deps.ffmpeg.statusLabel)") { onShowFfmpeg() }
            Divider()
            Button("Check for Engine Updates") {
                deps.forceUpdateYtdlp()
            }
            .disabled(!deps.ytdlp.isReady)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(deps.enginesDotColor)
                    .frame(width: 7, height: 7)
                    .opacity(busy && pulse ? 0.25 : 1)
                    .animation(busy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                               value: pulse)
                if !deps.enginesReady || deps.enginesFailed {
                    Text(deps.enginesSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(deps.enginesFailed ? Color.red : Color.primary.opacity(0.8))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.08 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .compactMenuStyle()
        .onHover { hovered = $0 }
        .onAppear { pulse = true }
        .help("\(deps.enginesSummary) — yt-dlp \(deps.ytdlp.statusLabel), ffmpeg \(deps.ffmpeg.statusLabel)")
    }
}

// MARK: Formatting helpers

enum YoinkFormat {
    /// Strips a leading "NN%" from a progress log line so rows don't repeat the percentage.
    static func progressDetail(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^\d{1,3}(\.\d+)?%\s*"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.replacingOccurrences(of: "  ", with: " · ")
    }

    /// "youtube.com" style host with the www. prefix removed.
    static func host(_ url: String) -> String {
        guard let h = URLComponents(string: url)?.host else { return url }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: Thin progress bar

struct ThinProgressBar: View {
    let progress: Double
    var tint: Color = .accentColor
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(height, geo.size.width * min(max(progress, 0), 1)))
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: progress)
            }
        }
        .frame(height: height)
    }
}

// MARK: Site symbol

extension YoinkFormat {
    /// SF Symbol that hints at which site a link belongs to.
    static func siteSymbol(_ url: String) -> String {
        let u = url.lowercased()
        if u.contains("youtube.com") || u.contains("youtu.be") { return "play.rectangle.fill" }
        if u.contains("twitch.tv")      { return "tv.fill" }
        if u.contains("twitter.com") || u.contains("x.com") { return "bubble.left.fill" }
        if u.contains("soundcloud.com") { return "waveform" }
        if u.contains("vimeo.com")      { return "film.fill" }
        if u.contains("instagram.com")  { return "camera.fill" }
        if u.contains("tiktok.com")     { return "music.note" }
        if u.contains("reddit.com")     { return "bubble.left.and.bubble.right.fill" }
        return "link"
    }
}

// MARK: Job status copy

extension DownloadJob {
    /// One line describing where this job is at — used under progress bars.
    var statusDetail: String {
        switch status {
        case .idle:
            return "Waiting to start"
        case .fetching:
            return "Starting…"
        case .downloading(let p):
            let pct = p > 0 ? "\(Int(p * 100))%" : "Downloading"
            if let line = log.last(where: { $0.kind == .progress })?.text {
                let rest = YoinkFormat.progressDetail(line)
                return rest.isEmpty ? pct : "\(pct) · \(rest)"
            }
            return pct
        case .paused(let p):
            return "Paused at \(Int(p * 100))%"
        case .merging:
            return "Finishing up…"
        case .done:
            if totalBytes > 0 { return "Done · \(YoinkFormat.bytes(totalBytes))" }
            return "Done"
        case .failed(let msg):
            let m = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "Failed" : "Failed · \(m)"
        case .cancelled:
            return "Cancelled"
        }
    }

    var isFailed: Bool { if case .failed = status { return true }; return false }

    /// Options can be edited until a download starts (and again after it fails or is cancelled).
    var isEditable: Bool {
        switch status {
        case .idle, .cancelled, .failed: return true
        default: return false
        }
    }
}

// MARK: Search field

struct YoinkSearchField: View {
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(minWidth: 180, maxWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                              lineWidth: focused ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: Compact menu label

/// The look of a small pop-up menu control ("1080p ⌃⌄").
struct CompactMenuLabel: View {
    let title: String
    var icon: String? = nil
    var monospaced = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

extension View {
    /// Applies the borderless, indicator-free style used by every compact menu.
    func compactMenuStyle() -> some View {
        // Button-style menus keep the full SwiftUI label (borderless ones flatten it
        // to a single image + text, dropping backgrounds, chevrons and shapes).
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}
