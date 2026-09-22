import Foundation
import SwiftUI
import UserNotifications

// MARK: - App Update Service

enum AppUpdateStatus: Equatable {
    case unknown
    case checking
    case upToDate(version: String)
    case available(current: String, latest: String, downloadURL: String)
    case failed(String)
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    private init() {}

    @Published var status: AppUpdateStatus = .unknown
    @Published var showUpdateAlert = false

    // Replace these with your real GitHub release URL when you have the repo
    private let releasesAPIURL = "https://api.github.com/repos/0x1p0/yoink/releases/latest"
    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // MARK: - Check

    /// Called from Settings "Check Now" button or on launch.
    func checkForUpdates() {
        status = .checking
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.performCheck()
        }
    }

    /// Daily automatic check - skips if checked recently.
    func checkIfNeeded() {
        let sm = SettingsManager.shared
        guard sm.checkUpdatesOnLaunch else { return }
        let now = Date().timeIntervalSince1970
        guard now - sm.lastAppUpdateCheck > 86_400 else { return }
        sm.lastAppUpdateCheck = now
        checkForUpdates()
    }

    private func performCheck() async {
        guard let url = URL(string: releasesAPIURL) else {
            await MainActor.run { status = .failed("Invalid release URL") }
            return
        }
        do {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String
            else {
                await MainActor.run { status = .failed("Could not parse release info") }
                return
            }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let downloadURL: String
            if let assets = json["assets"] as? [[String: Any]],
               let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
               let browserURL = dmg["browser_download_url"] as? String {
                downloadURL = browserURL
            } else {
                downloadURL = (json["html_url"] as? String) ?? "https://github.com/0x1p0/yoink/releases"
            }

            let current = currentVersion
            let skipped = await MainActor.run { SettingsManager.shared.skippedAppVersion }
            let isNewer = latestVersion.compare(current, options: .numeric) == .orderedDescending

            await MainActor.run {
                if isNewer && latestVersion != skipped {
                    self.status = .available(current: current, latest: latestVersion, downloadURL: downloadURL)
                    self.showUpdateAlert = true
                } else {
                    self.status = .upToDate(version: current)
                }
            }
        } catch {
            await MainActor.run { status = .failed(error.localizedDescription) }
        }
    }

    func openDownloadPage() {
        if case .available(_, _, let urlStr) = status, let u = URL(string: urlStr) {
            NSWorkspace.shared.open(u)
        }
    }

    func skipThisVersion() {
        if case .available(_, let latest, _) = status {
            SettingsManager.shared.skippedAppVersion = latest
        }
        status = .upToDate(version: currentVersion)
        showUpdateAlert = false
    }

    func remindLater() {
        showUpdateAlert = false
    }

    var statusLabel: String {
        switch status {
        case .unknown:                return "Not checked"
        case .checking:               return "Checking…"
        case .upToDate(let v):        return "Up to date (v\(v))"
        case .available(_, let l, _): return "v\(l) available ↑"
        case .failed(let e):          return "Error: \(e)"
        }
    }

    var dotColor: Color {
        switch status {
        case .unknown, .checking: return Color(.systemGray)
        case .upToDate:           return .green
        case .available:          return .orange
        case .failed:             return .red
        }
    }
}
