import SwiftUI

// MARK: - Dependency Sheet

struct DepSheet: View {
    let tool: String
    @EnvironmentObject var deps: DependencyService
    @Environment(\.dismiss) var dismiss

    // Per-binary update-available state
    @State private var ffmpegLatest: String? = nil
    @State private var ffprobeLatest: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tool)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(toolDescription)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(24)

            Divider().opacity(0.1)

            if tool == "ffmpeg" {
                // ffmpeg row
                BinaryStatusRow(
                    binary: "ffmpeg",
                    status: deps.ffmpeg,
                    latestVersion: ffmpegLatest,
                    onUpdate: { deps.forceUpdateFfmpeg() }
                )
                .padding(24)

                Divider().opacity(0.06)

                // ffprobe row
                BinaryStatusRow(
                    binary: "ffprobe",
                    status: deps.ffprobe,
                    latestVersion: ffprobeLatest,
                    onUpdate: { deps.forceUpdateFfprobe() }
                )
                .padding(24)
            } else {
                // yt-dlp (unchanged behaviour)
                BinaryStatusRow(
                    binary: "yt-dlp",
                    status: deps.ytdlp,
                    latestVersion: nil,
                    onUpdate: nil
                )
                .padding(24)
            }

            // Update log (silent updates)
            if !deps.updateLog.isEmpty {
                Divider().opacity(0.08)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(deps.updateLog.indices, id: \.self) { i in
                            Text(deps.updateLog[i])
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(logColor(deps.updateLog[i]))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 130)
                .background(.primary.opacity(0.04))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            // Footer
            Divider().opacity(0.06)
            HStack(spacing: 6) {
                Image(systemName: "cube.box")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Bundled with Yoink - updated automatically in the background")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
        .background(.background)
        .task {
            // Check versions on open (only for ffmpeg panel)
            guard tool == "ffmpeg" else { return }
            await deps.checkFfmpeg()
            await deps.checkFfprobe()
            // Fetch latest release versions from evermeet.cx
            async let fm = fetchLatestVersion("ffmpeg")
            async let fp = fetchLatestVersion("ffprobe")
            let (fmv, fpv) = await (fm, fp)
            ffmpegLatest  = fmv
            ffprobeLatest = fpv
        }
    }

    var toolDescription: String {
        tool == "ffmpeg"
            ? "Audio & video processing - required for merging streams"
            : "Universal media downloader - supports 1000+ sites"
    }

    func logColor(_ line: String) -> Color {
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("✗") || line.hasPrefix("Error") { return .red }
        if line.hasPrefix("⬆") { return Color.accentColor }
        return .secondary
    }

    private func fetchLatestVersion(_ binary: String) async -> String? {
        guard let url = URL(string: "https://evermeet.cx/ffmpeg/info/\(binary)/release"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        return version
    }
}

// MARK: - Binary Status Row

struct BinaryStatusRow: View {
    let binary: String
    let status: DepStatus
    let latestVersion: String?
    let onUpdate: (() -> Void)?

    private var currentVersion: String? { status.version }

    private var updateAvailable: Bool {
        guard let latest = latestVersion, let current = currentVersion else { return false }
        return DependencyService.isNewer(latest, than: current)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor)
                    .opacity(status == .checking ? 0.5 : 1.0)
                    .animation(status == .checking
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default, value: status == .checking)
            }
            .frame(width: 46, height: 46)

            // Labels
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(binary)
                        .font(.system(size: 13, weight: .semibold))
                    if updateAvailable, let latest = latestVersion {
                        Text(latest)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Text(statusHeadline)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action button
            if case .updating = status {
                ProgressView().scaleEffect(0.7)
            } else if updateAvailable, let onUpdate {
                Button("Update") { onUpdate() }
                    .buttonStyle(PrimaryButtonStyle())
            } else if status == .unknown || status == .missing {
                // no check button needed, .task handles it
                EmptyView()
            }
        }
    }

    var statusHeadline: String {
        switch status {
        case .unknown:          return "Checking…"
        case .checking:         return "Checking…"
        case .ok(let v):
            if updateAvailable, let latest = latestVersion {
                return "\(v)  →  \(latest) available"
            }
            return "Ready  -  \(v)"
        case .updating(let v):  return "Updating from \(v)…"
        case .missing:          return "Binary missing - please restart"
        case .failed(let e):    return "Error: \(e)"
        }
    }

    var iconName: String {
        switch status {
        case .ok:                return updateAvailable ? "arrow.up.circle.fill" : "checkmark.circle.fill"
        case .updating:          return "arrow.triangle.2.circlepath.circle.fill"
        case .missing:           return "xmark.circle.fill"
        case .checking,.unknown: return "arrow.triangle.2.circlepath.circle.fill"
        case .failed:            return "exclamationmark.circle.fill"
        }
    }

    var iconColor: Color {
        if updateAvailable { return .orange }
        switch status {
        case .ok:                return .green
        case .updating,.checking,.unknown: return Color.accentColor
        case .missing,.failed:   return .red
        }
    }
}

// MARK: - Cookies Sheet


struct CookiesSheet: View {
    @ObservedObject var job: DownloadJob
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Authentication")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("For private, members-only, or age-restricted content")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                    DownloadService.shared.refetchMetadata(for: job)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            }
            .padding(24)

            Divider().opacity(0.1)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // ── Paste cookies ───────────────────────────────────────
                    SectionHeader(icon: "doc.text", title: "Paste Netscape cookies")

                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $job.manualCookies)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 160)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
                            )

                        Text("Export using a browser extension such as \"Get cookies.txt\" in Netscape format.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    if false {  // placeholder to keep braces balanced
                        EmptyView()
                        .padding(10)
                        .background(.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 420, height: 460)
        .background(.background)
    }
}

struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
