import Foundation
import SwiftUI
import UserNotifications

// MARK: - Post-download action executor

func sendCompletionNotification(outputDir: URL, title: String, exactFilePath: String? = nil, thumbnailURL: String? = nil) {
    let center = UNUserNotificationCenter.current()

    func buildAndSend(attachmentURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = title
        content.sound = .default
        // Store the EXACT file path so notification tap reveals the right file
        // Fall back to folder only if we somehow don't have the exact path
        content.userInfo = ["exactFilePath": exactFilePath ?? "", "outputPath": outputDir.path]
        if let att = attachmentURL,
           let attachment = try? UNNotificationAttachment(identifier: "thumb", url: att, options: nil) {
            content.attachments = [attachment]
        }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req) { err in
            if let err { print("[Yoink] Notification error: \(err)") }
        }
    }

    let send: () -> Void = {
        if let thumbStr = thumbnailURL, !thumbStr.isEmpty, let thumbURL = URL(string: thumbStr) {
            Task.detached(priority: .background) {
                let tempDir = FileManager.default.temporaryDirectory
                let ext = (thumbURL.pathExtension.isEmpty ? "jpg" : thumbURL.pathExtension)
                let dest = tempDir.appendingPathComponent("yoink_notif_thumb_\(UUID().uuidString).\(ext)")
                if let (localURL, _) = try? await URLSession.shared.download(from: thumbURL) {
                    try? FileManager.default.moveItem(at: localURL, to: dest)
                    buildAndSend(attachmentURL: dest)
                } else {
                    buildAndSend(attachmentURL: nil)
                }
            }
        } else {
            buildAndSend(attachmentURL: nil)
        }
    }
    center.getNotificationSettings { s in
        switch s.authorizationStatus {
        case .authorized, .provisional:
            send()
        case .notDetermined:
            center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                if ok { send() }
            }
        default:
            DispatchQueue.main.async {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            }
        }
    }
}

// Fires once when the entire queue drains - used when notifyOnQueueComplete is enabled.
func sendQueueCompleteNotification(title: String, count: Int, outputDir: URL) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { s in
        guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = count == 1
            ? "Your download is ready."
            : "All \(count) downloads are ready in your output folder."
        content.sound = .default
        content.userInfo = ["outputPath": outputDir.path, "exactFilePath": ""]
        let req = UNNotificationRequest(identifier: "yoink.queue.complete.\(UUID().uuidString)",
                                        content: content, trigger: nil)
        center.add(req) { err in if let err { print("[Yoink] Queue notification error: \(err)") } }
    }
}

func executePostDownloadAction(_ action: PostDownloadAction, outputDir: URL, title: String) {
    let mediaExts = Set(["mkv","mp4","webm","mov","m4a","mp3","opus","flac","ogg","wav","aac"])

    let mediaFile: URL? = (try? FileManager.default.contentsOfDirectory(
        at: outputDir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles
    ))?
    .filter { mediaExts.contains($0.pathExtension.lowercased()) }
    .max {
        let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return a < b
    }

    switch action {
    case .nothing:
        break
    case .reveal:
        if let file = mediaFile {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(outputDir)
        }
    case .openFolder:
        NSWorkspace.shared.open(outputDir)
    case .notify:
        sendCompletionNotification(outputDir: outputDir, title: title)
    case .openFile:
        // FIX #3: open file in default app (VLC, IINA, QuickTime, etc.)
        if let file = mediaFile {
            NSWorkspace.shared.open(file)
        } else {
            NSWorkspace.shared.open(outputDir)
        }
    }
}

