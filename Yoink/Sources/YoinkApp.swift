import SwiftUI
import AppKit
import UserNotifications

// MARK: - AppDelegate

enum YoinkWindowID {
    static let main = NSUserInterfaceItemIdentifier("YoinkMainWindow")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {

    private func isMainContentWindow(_ win: NSWindow) -> Bool {
        !(win is NSPanel) && win.identifier == YoinkWindowID.main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        ClipboardMonitor.shared.registerNotificationCategory()

        // Check existing permission first - requestAuthorization only prompts once
        // but we need to start the monitor even on subsequent launches
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                DispatchQueue.main.async {
                    if SettingsManager.shared.clipboardMonitor {
                        ClipboardMonitor.shared.start()
                    } else {
                    }
                }
            } else {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if granted {
                        DispatchQueue.main.async {
                            if SettingsManager.shared.clipboardMonitor {
                                ClipboardMonitor.shared.start()
                            }
                        }
                    }
                }
            }
        }

        NSApp.setActivationPolicy(.regular)
        makeWindowsTransparent()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] notif in
            guard let self, let win = notif.object as? NSWindow else { return }
            // Only the main content window is transparent — never Settings or panels.
            if self.isMainContentWindow(win) {
                win.isOpaque = false
                win.backgroundColor = .clear
                win.delegate = self
            } else if !(win is NSPanel) {
                win.isOpaque = true
                if win.backgroundColor == .clear {
                    win.backgroundColor = .windowBackgroundColor
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in DownloadQueue.shared?.savePendingQueue() }
    }

    func makeWindowsTransparent() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for win in NSApp.windows where self.isMainContentWindow(win) {
                win.isOpaque = false
                win.backgroundColor = .clear
                win.delegate = self
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for win in NSApp.windows where win.canBecomeMain {
                win.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Only intercept the main content window (not panels, settings, etc.)
        guard isMainContentWindow(sender) else { return true }
        // Hide the window instead of closing it
        sender.orderOut(nil)
        // Only remove from dock if the user hasn't opted to keep it there
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        guard isMainContentWindow(win) else { return }
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        if !showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo

        // Handle clipboard monitor notification actions
        if let clipURL = userInfo["clipboardURL"] as? String, !clipURL.isEmpty {
            switch response.actionIdentifier {

            case ClipboardMonitor.actionDownload:
                Task { @MainActor in
                    let job = DownloadJob()
                    job.url    = clipURL
                    job.format = .best   // bestvideo+bestaudio/best
                    // Inherit global SponsorBlock and subtitle settings
                    job.sponsorBlockOverride = SettingsManager.shared.notifSponsorBlock ? true : nil
                    job.downloadSubs = SettingsManager.shared.notifSubtitles

                    let queue: DownloadQueue
                    if let existing = DownloadQueue.shared {
                        queue = existing
                    } else {

                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard let q = DownloadQueue.shared else { completionHandler(); return }
                        queue = q
                    }
                    queue.jobs.append(job)
                    queue.ensureOutputDir()
                    DownloadService.shared.start(job: job, outputDir: queue.outputDirectory)
                }

            case UNNotificationDefaultActionIdentifier:
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    for win in NSApp.windows where win.canBecomeMain { win.makeKeyAndOrderFront(nil) }
                    SettingsManager.shared.appModeRaw = AppMode.video.rawValue
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let empty = DownloadQueue.shared?.jobs.first(where: { !$0.hasURL && $0.status == .idle }) {
                            empty.url = clipURL
                        } else {
                            DownloadQueue.shared?.addJob(url: clipURL)
                        }
                        DownloadQueue.shared?.downloadAll()
                    }
                }

            case ClipboardMonitor.actionWatchLater:
                Task { @MainActor in
                    WatchLaterStore.shared.add(
                        url: clipURL,
                        isPlaylist: DownloadJob.looksLikePlaylist(clipURL) && !DownloadService.isSoopOrAfreecaURL(clipURL)
                    )
                }

            case "CLIPBOARD_SNOOZE":
                Task { @MainActor in ClipboardMonitor.shared.snooze(.thirtyMinutes) }

            default: break
            }
            completionHandler()
            return
        }

        // Handle download-complete notification - open app and reveal file
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for win in NSApp.windows where win.canBecomeMain { win.makeKeyAndOrderFront(nil) }
            SettingsManager.shared.appModeRaw = AppMode.history.rawValue
            if let exactPath = userInfo["exactFilePath"] as? String,
               !exactPath.isEmpty,
               FileManager.default.fileExists(atPath: exactPath) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exactPath)])
                }
            } else if let folderPath = userInfo["outputPath"] as? String {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: folderPath))
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

// MARK: - App Entry Point

@main
struct YoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var deps        = DependencyService.shared
    @StateObject private var queue       = DownloadQueue()
    @StateObject private var theme       = ThemeManager()
    @StateObject private var settings    = SettingsManager.shared
    @StateObject private var appUpdate   = AppUpdateService.shared
    @StateObject private var clipMonitor = ClipboardMonitor.shared
    @StateObject private var watchLater  = WatchLaterStore.shared

    var body: some Scene {

        // Main window
        WindowGroup {
            ContentView()
                .environmentObject(deps)
                .environmentObject(queue)
                .environmentObject(theme)
                .environmentObject(settings)
                .environmentObject(appUpdate)
                .environmentObject(clipMonitor)
                .environmentObject(watchLater)
                .applyColorScheme(theme.current.colorScheme)
                .accentColor(theme.accentColor)
                .frame(minWidth: 700, idealWidth: 860, maxWidth: 1100,
                       minHeight: 480, idealHeight: 640, maxHeight: 980)
                .onAppear {
                    appUpdate.checkIfNeeded()
                    DownloadQueue.shared = queue
                    _ = ScheduledDownloadStore.shared
                    NotificationCenter.default.post(name: .downloadQueueReady, object: nil)
                    Task { await DownloadService.shared.preWarmExtractorPatterns() }

                }
                .alert("Update Available", isPresented: $appUpdate.showUpdateAlert) {
                    Button("Update Now") { appUpdate.openDownloadPage() }
                    Button("Remind Me Later", role: .cancel) { appUpdate.remindLater() }
                    Button("Skip This Version") { appUpdate.skipThisVersion() }
                } message: {
                    if case .available(let current, let latest, _) = appUpdate.status {
                        Text("Yoink \(latest) is available (you have \(current)). Download the latest version?")
                    } else {
                        Text("A new version of Yoink is available.")
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Queue") {
                Button("Add URL")         { queue.addJob() }         .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("Download All")    { queue.downloadAll() }    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Clear Completed") { queue.clearCompleted() } .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        // Settings — opaque bed so it never shows the main window through it.
        // Leave room for system Liquid Glass chrome on macOS 26+.
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(deps)
                .environmentObject(theme)
                .environmentObject(appUpdate)
                .applyColorScheme(theme.current.colorScheme)
                .accentColor(theme.accentColor)
        }

        // Menu bar
        MenuBarExtra {
            MenuBarView()
                .environmentObject(deps)
                .environmentObject(queue)
                .environmentObject(theme)
                .environmentObject(settings)
                .applyColorScheme(theme.current.colorScheme)
                .accentColor(theme.accentColor)
        } label: {
            MenuBarProgressLabel(queue: queue, settings: settings)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - URL Drop helper

extension Notification.Name {
    static let dropURLOnMenuBar = Notification.Name("dropURLOnMenuBar")
}

// MARK: - Helpers

extension View {
    @ViewBuilder
    func applyColorScheme(_ scheme: ColorScheme?) -> some View {
        if let scheme { self.preferredColorScheme(scheme) }
        else { self }
    }
}
