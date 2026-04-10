import Foundation
import SwiftUI
import AppKit
@preconcurrency import UserNotifications

// MARK: - Clipboard Monitor

@MainActor
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()
    private init() {}

    @Published var detectedURL : String = ""
    @Published var showBanner  : Bool   = false

    private var timer           : Timer?
    private var lastChangeCount : Int    = NSPasteboard.general.changeCount
    private var lastOfferedURL  : String = ""
    private var isEnabled       : Bool   = false

    // MARK: - Snooze
    @Published private var snoozeUntil: Date? = nil

    enum SnoozeDuration {
        case fiveMinutes, thirtyMinutes, untilTomorrow, thisApp(String), thisDomain(String)

        var label: String {
            switch self {
            case .fiveMinutes:   return "5 minutes"
            case .thirtyMinutes: return "30 minutes"
            case .untilTomorrow: return "Until tomorrow"
            case .thisApp(let n): return "While using \(n)"
            case .thisDomain(let d): return "This session for \(d)"
            }
        }
    }

    /// FIX #5: Domains snoozed for the current app session
    @Published private var snoozedDomains: Set<String> = []

    func snooze(_ duration: SnoozeDuration) {
        switch duration {
        case .fiveMinutes:
            snoozeUntil = Date().addingTimeInterval(5 * 60)
        case .thirtyMinutes:
            snoozeUntil = Date().addingTimeInterval(30 * 60)
        case .untilTomorrow:
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.day! += 1
            comps.hour = 9; comps.minute = 0
            snoozeUntil = Calendar.current.date(from: comps)
        case .thisApp(let bundleID):
            snoozedAppBundleID = bundleID
        case .thisDomain(let domain):
            snoozedDomains.insert(domain.lowercased())
        }
        dismiss()
    }

    /// Returns the host of the currently detected URL, if any
    var detectedDomain: String? {
        guard !detectedURL.isEmpty,
              let host = URLComponents(string: detectedURL)?.host else { return nil }
        // Strip "www." prefix
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func isSnoozedDomain(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return snoozedDomains.contains(bare.lowercased())
    }

    @Published private var snoozedAppBundleID: String? = nil

    var isSnoozed: Bool {
        if let until = snoozeUntil, Date() < until { return true }
        if let bid = snoozedAppBundleID,
           let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontmost == bid { return true }
        // FIX #5: Check domain snooze
        if !detectedURL.isEmpty && isSnoozedDomain(detectedURL) { return true }
        return false
    }

    /// Call periodically (e.g. from the clipboard timer) to expire timed snoozes.
    func expireSnoozeIfNeeded() {
        if let until = snoozeUntil, Date() >= until { snoozeUntil = nil }
    }

    func clearSnooze() {
        snoozeUntil = nil
        snoozedAppBundleID = nil
        snoozedDomains.removeAll()   // FIX #5
    }

    var snoozeLabel: String? {
        if let until = snoozeUntil, Date() < until {
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            return "Snoozed until \(fmt.string(from: until))"
        }
        if let bid = snoozedAppBundleID,
           let name = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == bid })?.localizedName {
            return "Snoozed while \(name) is active"
        }
        return nil
    }

    static let categoryID       = "CLIPBOARD_URL"
    static let actionDownload   = "CLIPBOARD_DOWNLOAD"
    static let actionWatchLater = "CLIPBOARD_WATCH_LATER"

    // MARK: - Notification Category

    func registerNotificationCategory() {
        let downloadAction = UNNotificationAction(
            identifier: Self.actionDownload,
            title: "⬇ Download Now",
            options: []
        )
        let watchLaterAction = UNNotificationAction(
            identifier: Self.actionWatchLater,
            title: "🔖 Watch Later",
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: "CLIPBOARD_SNOOZE",
            title: "⏰ Snooze 30 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [downloadAction, watchLaterAction, snoozeAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let categoryIDCopy = Self.categoryID
        let categoryCopy = category
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != categoryIDCopy }
            all.insert(categoryCopy)
            UNUserNotificationCenter.current().setNotificationCategories(all)
        }
    }

    // MARK: - Start / Stop

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        isEnabled = false
        timer?.invalidate()
        timer = nil
    }

    func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showBanner = false }
        lastOfferedURL = detectedURL
    }

    func acceptURL() -> String { let u = detectedURL; dismiss(); return u }

    // MARK: - Clipboard check

    private func checkClipboard() {
        expireSnoozeIfNeeded()
        guard !isSnoozed else {
            return
        }

        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let str = pb.string(forType: .string) ?? pb.string(forType: .URL),
              !str.contains("\n"),
              str.lowercased().hasPrefix("http")
        else {
            lastOfferedURL = ""
            return
        }


        guard str != lastOfferedURL else {
            return
        }

        let domains = SettingsManager.shared.clipboardDomains
        guard let host = URLComponents(string: str)?.host?.lowercased(),
              domains.contains(where: { host.contains($0) })
        else {
            return
        }

        if let q = DownloadQueue.shared, q.jobs.contains(where: { $0.url == str }) {
            return
        }

        lastOfferedURL = str
        detectedURL    = str

        fireSystemNotification(url: str, site: siteNameFor(str, domains: domains))

        if NSApp.isActive {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { showBanner = true }
            Haptics.tap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard self?.detectedURL == str else { return }
                self?.dismiss()
            }
        }
    }

    private func fireSystemNotification(url: String, site: String) {
        let content = UNMutableNotificationContent()
        content.title    = "\(site) link detected"
        content.subtitle = "Hover to see options"
        content.body     = url.count > 60
            ? String(url.prefix(57)) + "…"
            : url
        content.sound    = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["clipboardURL": url]

        let notifID = "clip-\(url.hashValue)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifID])

        let req = UNNotificationRequest(identifier: notifID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error = error {
            } else {
            }
        }
    }

    // MARK: - Helpers

    var siteName: String { siteNameFor(detectedURL, domains: SettingsManager.shared.clipboardDomains) }

    private func siteNameFor(_ url: String, domains: [String]) -> String {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return "Video" }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("twitch")     { return "Twitch" }
        if host.contains("twitter") || host.contains("x.com") { return "Twitter / X" }
        if host.contains("instagram")  { return "Instagram" }
        if host.contains("tiktok")     { return "TikTok" }
        if host.contains("vimeo")      { return "Vimeo" }
        if host.contains("soundcloud") { return "SoundCloud" }
        if host.contains("reddit")     { return "Reddit" }
        if host.contains("rumble")     { return "Rumble" }
        if host.contains("kick")       { return "Kick" }
        if host.contains("bilibili")   { return "Bilibili" }
        if host.contains("dailymotion"){ return "Dailymotion" }
        if host.contains("streamable") { return "Streamable" }
        if host.contains("medal")      { return "Medal" }
        let parts = host.components(separatedBy: ".")
        return parts.dropLast().last?.capitalized ?? "Video"
    }
}
