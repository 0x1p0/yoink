import Foundation
import SwiftUI
import UserNotifications

// MARK: - Global Thumbnail Cache

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private init() {}

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func image(for url: String) -> NSImage? { images[url] }

    func prefetch(_ urls: [String]) {
        for url in urls { load(url) }
    }

    func load(_ urlStr: String) {
        guard !urlStr.isEmpty, images[urlStr] == nil, !inFlight.contains(urlStr),
              let url = URL(string: urlStr) else { return }
        inFlight.insert(urlStr)
        Task.detached(priority: .background) {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let img = NSImage(data: data) {
                await MainActor.run {
                    self.images[urlStr] = img
                    self.inFlight.remove(urlStr)
                    return
                }
            } else {
                await MainActor.run { self.inFlight.remove(urlStr); return }
            }
        }
    }
}

