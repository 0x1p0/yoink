import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class DownloadQueue: ObservableObject {
    @Published var jobs: [DownloadJob] = []
    @Published var outputDirectory: URL {
        didSet { Self.saveOutputDirectory(outputDirectory) }
    }

    // Weak back-reference set by YoinkApp so AppDelegate can call savePendingQueue
    static weak var shared: DownloadQueue?

    private static let outputDirBookmarkKey = "outputDirectoryBookmark_v2"
    private static let outputDirPathKey     = "outputDirectoryPath_v1"

    private static let pendingURLsKey = "pendingDownloadURLs_v1"

    init() {
        outputDirectory = Self.loadOutputDirectory()
        jobs = [DownloadJob()]
        restorePendingQueue()
    }

    func savePendingQueue() {
        let urls = jobs.compactMap { job -> String? in
            guard job.hasURL, !job.status.isTerminal else { return nil }
            return job.url
        }
        UserDefaults.standard.set(urls, forKey: Self.pendingURLsKey)
    }

    private func restorePendingQueue() {
        guard let urls = UserDefaults.standard.stringArray(forKey: Self.pendingURLsKey),
              !urls.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingURLsKey)
        Self.interruptedURLs = urls
    }

    static var interruptedURLs: [String] = []

    // ── Persistence ──────────────────────────────────────────────────────

    private static func loadOutputDirectory() -> URL {
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Yoink")

        if let data = UserDefaults.standard.data(forKey: outputDirBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale { saveOutputDirectory(url) }
                return url
            }
        }
        // Fallback: plain path (non-sandboxed builds)
        if let path = UserDefaults.standard.string(forKey: outputDirPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { return url }
        }
        return fallback
    }

    private static func saveOutputDirectory(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: outputDirBookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: outputDirPathKey)
    }

    /// ⌘N / "Add Another Link": reuse a blank card if one is already waiting, so repeated
    /// presses don't stack up empty cards — just move the cursor into it.
    func addJob() {
        if let blank = jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
            NotificationCenter.default.post(name: .focusJobURLField, object: blank.id)
            return
        }
        let job = DownloadJob()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { jobs.append(job) }
        // Give the new card a moment to appear before focusing its field
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .focusJobURLField, object: job.id)
        }
    }
    func addJob(url: String) {
        let job = DownloadJob(); job.url = url
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { jobs.append(job) }
        Haptics.tap()
    }
    func addJobSilent(_ job: DownloadJob) {
        jobs.append(job)
    }

    func addBatchURLs(_ urls: [String]) {
        var remaining = urls
        for job in jobs where !job.hasURL && job.status == .idle {
            guard !remaining.isEmpty else { break }
            job.url = remaining.removeFirst()
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
            for url in remaining { let j = DownloadJob(); j.url = url; jobs.append(j) }
        }
        Haptics.success()
    }

    /// Import URLs from a plain-text file (one URL per line).
    /// Returns the number of URLs successfully imported.
    @discardableResult
    func importURLsFromFile(_ fileURL: URL) -> Int {
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        let urls = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") }
        guard !urls.isEmpty else { return 0 }
        addBatchURLs(urls)
        return urls.count
    }
    func remove(_ job: DownloadJob) {
        job.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { jobs.removeAll { $0.id == job.id } }
    }
    func clearCompleted() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { jobs.removeAll { $0.status.isTerminal } }
    }

    func retryFailed() {
        let failed = jobs.filter { if case .failed = $0.status { return true }; return false }
        guard !failed.isEmpty else { return }
        ensureOutputDir()
        for job in failed {
            job.retryCount += 1
            job.reset()
        }
        downloadAll()
        Haptics.start()
    }

    func move(from source: IndexSet, to destination: Int) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            jobs.move(fromOffsets: source, toOffset: destination)
        }
    }
    func downloadAll() {
        ensureOutputDir()
        let limit = SettingsManager.shared.concurrentLimit.rawValue  // 0 = unlimited
        // Only jobs that haven't run yet (or were cancelled) — never restart finished or paused ones
        let pending = jobs.filter { $0.hasURL && ($0.status == .idle || $0.status == .cancelled) }
        let activeCount = jobs.filter { $0.status.isActive }.count
        let slotsAvailable = limit == 0 ? pending.count : max(0, limit - activeCount)
        let toStart = limit == 0 ? pending : Array(pending.prefix(slotsAvailable))
        for job in toStart {
            DownloadService.shared.start(job: job, outputDir: outputDirectory)
        }
    }
    func ensureOutputDir() {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }
}

