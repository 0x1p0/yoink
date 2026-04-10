import Foundation
import SwiftUI
import UserNotifications

extension Notification.Name {
    /// Posted by YoinkApp once DownloadQueue.shared has been set (inside ContentView.onAppear).
    static let downloadQueueReady = Notification.Name("downloadQueueReady")
}

// MARK: - Scheduled Download

struct ScheduledDownload: Codable, Identifiable {
    let id          : UUID
    var url         : String
    var title       : String
    var thumbnail   : String
    var formatRaw   : String
    var scheduledAt : Date
    var fired       : Bool
    var sponsorBlock: Bool   // captured at schedule time from Watch Later toggles
    var subtitles   : Bool   // captured at schedule time from Watch Later toggles

    init(url: String, title: String = "", thumbnail: String = "",
         format: DownloadFormat = .best, scheduledAt: Date,
         sponsorBlock: Bool = false, subtitles: Bool = false) {
        self.id           = UUID()
        self.url          = url
        self.title        = title
        self.thumbnail    = thumbnail
        self.formatRaw    = format.rawValue
        self.scheduledAt  = scheduledAt
        self.fired        = false
        self.sponsorBlock = sponsorBlock
        self.subtitles    = subtitles
    }

    var format: DownloadFormat { DownloadFormat(rawValue: formatRaw) ?? .best }
    var displayTitle: String { title.isEmpty ? url : title }
    var timeDescription: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        if Calendar.current.isDateInToday(scheduledAt) {
            return "Today at \(f.string(from: scheduledAt))"
        } else if Calendar.current.isDateInTomorrow(scheduledAt) {
            return "Tomorrow at \(f.string(from: scheduledAt))"
        }
        f.dateStyle = .short
        return f.string(from: scheduledAt)
    }
    var isPast: Bool { scheduledAt < Date() }
}

// MARK: - Scheduled Download Store

@MainActor
final class ScheduledDownloadStore: ObservableObject {
    static let shared = ScheduledDownloadStore()
    private init() { load(); startTimer() }

    @Published var items: [ScheduledDownload] = []
    private let key = "scheduledDownloads_v1"
    private var timer: Timer?

    func schedule(url: String, title: String, thumbnail: String, format: DownloadFormat, at date: Date,
                  sponsorBlock: Bool = false, subtitles: Bool = false) {
        let item = ScheduledDownload(url: url, title: title, thumbnail: thumbnail,
                                     format: format, scheduledAt: date,
                                     sponsorBlock: sponsorBlock, subtitles: subtitles)
        items.append(item)
        items.sort { $0.scheduledAt < $1.scheduledAt }
        save()
        Haptics.success()
    }

    func remove(_ item: ScheduledDownload) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeAll() { items = []; save() }

    // MARK: - Timer tick - fire pending items

    private func startTimer() {
        // Register for the notification in case it fires after we initialise.
        NotificationCenter.default.addObserver(forName: .downloadQueueReady, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Only start the timer once - guard against duplicate notifications.
            guard self.timer == nil else { return }
            self.firePending()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.firePending() }
            }
        }

        // Fallback poll in case the notification was already posted before this observer registered.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] pollTimer in
            guard let self else { pollTimer.invalidate(); return }
            if self.timer != nil { pollTimer.invalidate(); return }
            if DownloadQueue.shared != nil {
                pollTimer.invalidate()
                Task { @MainActor in
                    guard self.timer == nil else { return }
                    self.firePending()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.firePending() }
                    }
                }
            }
        }
    }

    private func firePending() {
        let now = Date()
        for i in items.indices where !items[i].fired && items[i].scheduledAt <= now {
            items[i].fired = true
            let item = items[i]

            WatchLaterStore.shared.items.removeAll { $0.url == item.url }
            // Queue it for download
            if let queue = DownloadQueue.shared {
                let job = DownloadJob()
                job.url    = item.url
                job.format = item.format

                job.sponsorBlockOverride = item.sponsorBlock ? true : nil
                job.downloadSubs         = item.subtitles
                job.subLang              = SettingsManager.shared.defaultSubLang

                if !item.title.isEmpty || !item.thumbnail.isEmpty {
                    job.meta = VideoMeta(
                        title: item.title,
                        thumbnail: item.thumbnail,
                        duration: "", durationH: "", durationM: "", durationS: "",
                        hasSubs: false
                    )
                    job.metaState = .done
                }
                queue.jobs.append(job)
                queue.ensureOutputDir()
                DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
                sendScheduledNotification(title: item.displayTitle)
            }
        }

        items.removeAll { $0.fired && Date().timeIntervalSince($0.scheduledAt) > 86400 }
        save()
    }

    private func sendScheduledNotification(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Scheduled Download Started"
        content.body  = title
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScheduledDownload].self, from: data)
        else { return }
        items = decoded
    }
}
