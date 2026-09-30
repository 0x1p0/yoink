import Foundation
import SwiftUI
import UserNotifications

// MARK: - Dep Status

enum DepStatus: Equatable {
    case unknown, checking
    case ok(version: String)
    case updating(from: String)   // silent background update in progress
    case missing                  // should never happen (bundled), shown if copy failed
    case failed(String)

    var isReady: Bool {
        switch self { case .ok, .updating: return true; default: return false }
    }
    var version: String? {
        switch self {
        case .ok(let v):       return v
        case .updating(let v): return v
        default:               return nil
        }
    }
    var dotColor: Color {
        switch self {
        case .unknown:           return Color(.systemGray)
        case .checking:          return .orange
        case .updating:          return .orange
        case .ok:                return .green
        case .missing, .failed:  return .red
        }
    }
    var statusLabel: String {
        switch self {
        case .unknown:          return "Not checked"
        case .checking:         return "Checking…"
        case .ok(let v):        return v
        case .updating(let v):  return "\(v) - updating…"
        case .missing:          return "Missing - restart app"
        case .failed(let e):    return e
        }
    }
}

// MARK: - Dependency Service (bundled universal binaries, no Homebrew / Python / Rosetta)

@MainActor
final class DependencyService: ObservableObject {
    static let shared = DependencyService()
    private init() {}

    @Published var ytdlp   : DepStatus = .unknown
    @Published var ffmpeg  : DepStatus = .unknown
    @Published var ffprobe : DepStatus = .unknown
    @Published var updateLog: [String] = []

    @AppStorage("lastEngineUpdateCheck") private var lastUpdateCheck: Double = 0

    // MARK: - Paths

    /// ~/Library/Application Support/Yoink/bin/
    nonisolated static var appSupportBin: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Yoink/bin", isDirectory: true)
    }

    /// yt-dlp ships as PyInstaller's unpacked ("onedir") macOS build: a folder holding the
    /// `yt-dlp_macos` launcher plus its `_internal` runtime. It starts in ~0.2 s, versus ~7 s
    /// for the single-file build, which re-extracts itself to a temp folder on every run.
    nonisolated static let ytdlpFolderName = "yt-dlp_macos"

    nonisolated static var ytdlpFolder: URL {
        appSupportBin.appendingPathComponent(ytdlpFolderName, isDirectory: true)
    }

    nonisolated static func runtimePath(for binary: String) -> String {
        guard binary == "yt-dlp" else { return appSupportBin.appendingPathComponent(binary).path }
        let onedir = ytdlpFolder.appendingPathComponent(ytdlpFolderName).path
        // Fall back to a legacy single-file install until the folder build is in place
        let legacy = appSupportBin.appendingPathComponent("yt-dlp").path
        if !FileManager.default.isExecutableFile(atPath: onedir),
           FileManager.default.isExecutableFile(atPath: legacy) {
            return legacy
        }
        return onedir
    }

    var allReady: Bool { ytdlp.isReady && ffmpeg.isReady }

    // MARK: - Boot

    func checkAll() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            self.ensureBinariesCopied()
            // Drop legacy Python runtime from older installs (yt-dlp is now a standalone binary)
            self.removeLegacyPython()
            async let a: () = self.checkYtdlp()
            async let b: () = self.checkFfmpeg()
            async let c: () = self.checkFfprobe()
            _ = await (a, b, c)

            let now = Date().timeIntervalSince1970
            let lastCheck = await self.lastUpdateCheck
            if SettingsManager.shared.checkUpdatesOnLaunch, now - lastCheck > 86_400 {
                await MainActor.run { self.lastUpdateCheck = now }
                await self.silentUpdateYtdlp()
            }
        }
    }

    // MARK: - First-launch binary copy / upgrade

    nonisolated private func ensureBinariesCopied() {
        let fm = FileManager.default
        let binDir = Self.appSupportBin
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        installBundledYtdlp()

        for binary in ["ffmpeg", "ffprobe"] {
            let dest = binDir.appendingPathComponent(binary)
            guard let src = Bundle.main.url(forResource: binary, withExtension: nil,
                                             subdirectory: "bin") else {
                log("⚠️ Bundled \(binary) not found in Resources/bin/ — run ./download_binaries.sh")
                continue
            }
            // Replace when missing, when it's the old shell-script yt-dlp launcher,
            // or when the installed slice doesn't cover the host architecture
            // (e.g. a leftover evermeet.cx x86_64-only ffmpeg on Apple Silicon).
            if fm.fileExists(atPath: dest.path), !Self.needsReplace(dest) { continue }
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: src, to: dest)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                Self.removeQuarantine(at: dest)
                log("✓ Installed \(binary) → \(dest.path)")
            } catch {
                log("✗ Failed to install \(binary): \(error.localizedDescription)")
            }
        }
    }

    /// Installs the bundled yt-dlp folder into App Support when it isn't there yet, and
    /// removes the slow single-file build left behind by older versions of Yoink.
    nonisolated private func installBundledYtdlp() {
        let fm = FileManager.default
        let dest = Self.ytdlpFolder
        let destExe = dest.appendingPathComponent(Self.ytdlpFolderName)
        let legacy = Self.appSupportBin.appendingPathComponent("yt-dlp")

        if let src = Bundle.main.url(forResource: Self.ytdlpFolderName, withExtension: nil, subdirectory: "bin") {
            if !fm.isExecutableFile(atPath: destExe.path) {
                do {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: src, to: dest)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destExe.path)
                    Self.removeQuarantine(at: dest)
                    log("✓ Installed yt-dlp → \(dest.path)")
                } catch {
                    log("✗ Failed to install yt-dlp: \(error.localizedDescription)")
                    return
                }
            }
            if fm.fileExists(atPath: legacy.path) {
                try? fm.removeItem(at: legacy)
                log("✓ Removed old single-file yt-dlp")
            }
        } else if let src = Bundle.main.url(forResource: "yt-dlp", withExtension: nil, subdirectory: "bin"),
                  !fm.isExecutableFile(atPath: destExe.path),
                  !fm.fileExists(atPath: legacy.path) || Self.needsReplace(legacy) {
            // Older bundle layout (single-file yt-dlp) — keep it working
            try? fm.removeItem(at: legacy)
            do {
                try fm.copyItem(at: src, to: legacy)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path)
                Self.removeQuarantine(at: legacy)
                log("✓ Installed yt-dlp (single file) → \(legacy.path)")
            } catch {
                log("✗ Failed to install yt-dlp: \(error.localizedDescription)")
            }
        } else if !fm.isExecutableFile(atPath: destExe.path) && !fm.fileExists(atPath: legacy.path) {
            log("⚠️ Bundled yt-dlp not found in Resources/bin/ — run ./download_binaries.sh")
        }
    }

    /// True when dest should be overwritten by the bundled copy.
    nonisolated private static func needsReplace(_ dest: URL) -> Bool {
        guard let data = try? Data(contentsOf: dest, options: .mappedIfSafe) else { return true }
        // Old pipeline shipped yt-dlp as a `#!/bin/bash` launcher script
        if data.starts(with: [0x23, 0x21]) { return true } // "#!"
        // Wrong / missing architecture for this host
        if let archs = lipoArchs(dest.path) {
            return !archs.contains(macArch())
        }
        return false
    }

    nonisolated static func lipoArchs(_ path: String) -> [String]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        p.arguments = ["-archs", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        return out.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    nonisolated private func removeLegacyPython() {
        let pythonDir = Self.appSupportBin.appendingPathComponent("python")
        guard FileManager.default.fileExists(atPath: pythonDir.path) else { return }
        try? FileManager.default.removeItem(at: pythonDir)
        log("✓ Removed legacy bundled Python runtime")
    }

    // MARK: - Version checks

    nonisolated func checkYtdlp() async {
        await MainActor.run { ytdlp = .checking }
        let path = Self.runtimePath(for: "yt-dlp")
        guard let v = await run(path, args: ["--version"]) else {
            await MainActor.run { ytdlp = .missing }; return
        }
        await MainActor.run { ytdlp = .ok(version: v.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    nonisolated func checkFfmpeg() async {
        await MainActor.run { ffmpeg = .checking }
        let path = Self.runtimePath(for: "ffmpeg")
        guard let out = await run(path, args: ["-version"]) else {
            await MainActor.run { ffmpeg = .missing }; return
        }
        let parts = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let version = parts.indices.contains(2) ? String(parts[2].prefix(12)) : "installed"
        await MainActor.run { ffmpeg = .ok(version: version) }
    }

    nonisolated func checkFfprobe() async {
        await MainActor.run { ffprobe = .checking }
        let path = Self.runtimePath(for: "ffprobe")
        guard let out = await run(path, args: ["-version"]) else {
            await MainActor.run { ffprobe = .missing }; return
        }
        let parts = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let version = parts.indices.contains(2) ? String(parts[2].prefix(24)) : "installed"
        await MainActor.run { ffprobe = .ok(version: version) }
    }

    // MARK: - Force update (on-demand)

    func forceUpdateFfmpeg() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.updateFfmpegTool("ffmpeg")
            await self.checkFfmpeg()
            await self.checkFfprobe()
        }
    }

    func forceUpdateFfprobe() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.updateFfmpegTool("ffprobe")
            await self.checkFfprobe()
        }
    }

    // MARK: - ffmpeg / ffprobe update via martin-riedl.de (arch-aware)

    nonisolated private static let ffmpegMirror = "https://ffmpeg.martin-riedl.de/redirect/latest/macos"

    /// Downloads the latest release for the host arch from martin-riedl.de and
    /// lipos a universal binary when both slices are available (same as download_binaries.sh).
    nonisolated private func updateFfmpegTool(_ name: String) async {
        let prev = await MainActor.run {
            switch name {
            case "ffprobe": return ffprobe.version ?? ""
            default:        return ffmpeg.version ?? ""
            }
        }
        await MainActor.run {
            switch name {
            case "ffprobe": ffprobe = .updating(from: prev)
            default:        ffmpeg  = .updating(from: prev)
            }
        }
        log("⬆︎ \(name) → latest (martin-riedl.de)")

        do {
            let hostArch = Self.macArch()
            let dest = Self.appSupportBin.appendingPathComponent(name)
            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("yoink-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpRoot) }

            // Prefer a universal binary (both arch slices) like the install script.
            var slices: [String] = []
            for arch in ["arm64", "amd64"] {
                if let path = try? await Self.downloadFfmpegZip(tool: name, arch: arch, into: tmpRoot) {
                    slices.append(path)
                }
            }
            guard !slices.isEmpty else { throw NSError(domain: "yoink", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(name) download failed"]) }

            let out = tmpRoot.appendingPathComponent("\(name)-out")
            if slices.count == 2, Self.canLipo {
                let lipo = Process()
                lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
                lipo.arguments = ["-create"] + slices + ["-output", out.path]
                lipo.standardOutput = Pipe(); lipo.standardError = Pipe()
                guard (try? lipo.run()) != nil else { throw NSError(domain: "yoink", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "lipo failed"]) }
                lipo.waitUntilExit()
                guard lipo.terminationStatus == 0 else { throw NSError(domain: "yoink", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "lipo failed"]) }
            } else {
                // Host-arch only
                let preferred = slices.first { $0.contains(hostArch == "arm64" ? "arm64" : "amd64") }
                    ?? slices.first!
                try FileManager.default.copyItem(at: URL(fileURLWithPath: preferred), to: out)
            }

            // Verify the new binary actually runs before replacing the old one
            guard await run(out.path, args: name == "ffmpeg" ? ["-version"] : ["-version"]) != nil else {
                throw NSError(domain: "yoink", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "\(name) failed verification"])
            }

            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: out, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Self.removeQuarantine(at: dest)
            log("✓ \(name) updated (universal=\(slices.count == 2))")
        } catch {
            log("✗ \(name) update failed: \(error.localizedDescription) — restoring bundle")
            reinstallFromBundle(name)
        }
    }

    nonisolated private static var canLipo: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/lipo")
    }

    /// Fetches one arch slice from martin-riedl, unzips, returns the binary path.
    nonisolated private static func downloadFfmpegZip(tool: String, arch: String, into dir: URL) async throws -> String {
        let zipURL = URL(string: "\(ffmpegMirror)/\(arch)/release/\(tool).zip")!
        var request = URLRequest(url: zipURL)
        request.timeoutInterval = 120
        let (tmp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let zipPath = dir.appendingPathComponent("\(tool)-\(arch).zip")
        try? FileManager.default.removeItem(at: zipPath)
        try FileManager.default.moveItem(at: tmp, to: zipPath)

        let extractDir = dir.appendingPathComponent("\(tool)-\(arch)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-oq", zipPath.path, "-d", extractDir.path]
        unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
        guard (try? unzip.run()) != nil else { throw URLError(.cannotOpenFile) }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw URLError(.cannotOpenFile) }

        // Bare binary at zip root, or one level down
        let direct = extractDir.appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: direct.path) { return direct.path }
        let nested = (try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent == tool }
        guard let nested else { throw URLError(.fileDoesNotExist) }
        return nested.path
    }

    /// Latest release version string from martin-riedl (parsed from the redirect Location).
    nonisolated func fetchLatestFfmpegVersion() async -> String? {
        let arch = Self.macArch() == "arm64" ? "arm64" : "amd64"
        guard let url = URL(string: "\(Self.ffmpegMirror)/\(arch)/release/ffmpeg.zip") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "HEAD"
        // Follow redirects manually so we can read Location
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            // URLSession follows redirects by default; inspect the final URL path
            // …/1789931890_9.0.2/ffmpeg.zip → 9.0.2
            if let path = http.url?.path,
               let range = path.range(of: #"_([^/]+)/ffmpeg\.zip$"#, options: .regularExpression) {
                var version = String(path[range])
                version.removeFirst() // drop leading _
                version = String(version.dropLast("/ffmpeg.zip".count))
                return version
            }
            // Fallback: try Location header if not followed
            if let loc = http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location") {
                let part = loc.components(separatedBy: "/").dropLast().last ?? ""
                if let underscore = part.split(separator: "_").last, !underscore.isEmpty {
                    return String(underscore)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    func forceUpdateYtdlp() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.silentUpdateYtdlp(force: true)
            await self.checkYtdlp()
        }
    }

    nonisolated private func reinstallFromBundle(_ name: String) {
        if name == "yt-dlp" {
            try? FileManager.default.removeItem(at: Self.ytdlpFolder)
            installBundledYtdlp()
            return
        }
        let fm = FileManager.default
        let dest = Self.appSupportBin.appendingPathComponent(name)
        guard let src = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin") else {
            log("⚠️ No bundled \(name) to install"); return
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: src, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Self.removeQuarantine(at: dest)
            log("✓ Reinstalled \(name) from bundle")
        } catch {
            log("✗ Reinstall \(name) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Silent yt-dlp update (official universal binary)

    nonisolated private func silentUpdateYtdlp(force: Bool = false) async {
        guard let latest = await fetchLatestYtdlpTag() else { return }
        let current = await MainActor.run { ytdlp.version ?? "" }
        guard force || isNewer(latest, than: current) else { return }

        let prev = current
        await MainActor.run { ytdlp = .updating(from: prev) }
        log("⬆︎ yt-dlp \(prev) → \(latest)")

        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")!
        let fm = FileManager.default
        let staging = Self.appSupportBin.appendingPathComponent("\(Self.ytdlpFolderName).new", isDirectory: true)
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 180
            let (tmp, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            // Unpack next to the live copy, verify it runs, then swap it in
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", tmp.path, staging.path]
            unzip.standardOutput = Pipe(); unzip.standardError = Pipe()
            try unzip.run()
            unzip.waitUntilExit()
            try? fm.removeItem(at: tmp)
            guard unzip.terminationStatus == 0 else { throw URLError(.cannotDecodeContentData) }

            // The archive holds the launcher + _internal at its root (or one folder down)
            var root = staging
            if !fm.fileExists(atPath: root.appendingPathComponent(Self.ytdlpFolderName).path),
               let sub = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                   .first(where: { fm.fileExists(atPath: $0.appendingPathComponent(Self.ytdlpFolderName).path) }) {
                root = sub
            }
            let exe = root.appendingPathComponent(Self.ytdlpFolderName)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            Self.removeQuarantine(at: root)
            guard await run(exe.path, args: ["--version"]) != nil else {
                throw NSError(domain: "yoink", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "new yt-dlp failed verification"])
            }

            try? fm.removeItem(at: Self.ytdlpFolder)
            try fm.moveItem(at: root, to: Self.ytdlpFolder)
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: Self.appSupportBin.appendingPathComponent("yt-dlp")) // legacy single file
            log("✓ yt-dlp updated to \(latest)")
            await MainActor.run { ytdlp = .ok(version: latest) }
        } catch {
            try? fm.removeItem(at: staging)
            log("✗ yt-dlp update failed: \(error.localizedDescription)")
            if !fm.isExecutableFile(atPath: Self.runtimePath(for: "yt-dlp")) {
                reinstallFromBundle("yt-dlp")
            }
            await MainActor.run { ytdlp = .ok(version: prev.isEmpty ? "bundled" : prev) }
        }
    }

    /// Removes com.apple.quarantine (recursively for folders) so Gatekeeper doesn't block bundled tools.
    nonisolated static func removeQuarantine(at url: URL) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", url.path]
        xattr.standardOutput = Pipe()
        xattr.standardError  = Pipe()
        try? xattr.run()
        xattr.waitUntilExit()
    }

    nonisolated static func macArch() -> String {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { ptr in
            String(bytes: ptr.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "x86_64"
        }.contains("arm") ? "arm64" : "x86_64"
    }

    // MARK: - Path resolution (always use binary in App Support)

    nonisolated func resolvePath(for binary: String) async -> String? {
        let path = Self.runtimePath(for: binary)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Helpers

    nonisolated private func run(_ path: String, args: [String]) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: proc.terminationStatus == 0
                    ? String(data: data, encoding: .utf8) : nil)
            }
            do { try p.run() } catch { cont.resume(returning: nil) }
        }
    }

    private func fetchLatestYtdlpTag() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag  = json["tag_name"] as? String
        else { return nil }
        return tag
    }

    nonisolated private func isNewer(_ a: String, than b: String) -> Bool {
        Self.isNewer(a, than: b)
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    nonisolated private func log(_ line: String, error: Bool = false) {
        print("[BinMgr] \(line)")
        Task { _ = await MainActor.run { self.updateLog.append(line) } }
    }
}

