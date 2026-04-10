import AppKit
import SwiftUI

// MARK: - Haptic Feedback

enum Haptics {

    static func hover() { fire(.generic, after: 0) }

    static func tap() { fire(.generic, after: 0) }

    static func toggleOn() {
        fire(.generic,   after: 0)
        fire(.alignment, after: 0.055)
    }

    static func toggleOff() { fire(.generic, after: 0) }

    static func start() {
        fire(.alignment,   after: 0)
        fire(.levelChange, after: 0.065)
    }

    static func success() {
        fire(.alignment,   after: 0)
        fire(.alignment,   after: 0.075)
        fire(.levelChange, after: 0.17)
    }

    static func error() {
        fire(.generic, after: 0)
        fire(.generic, after: 0.11)
    }

    static func tick() { fire(.generic, after: 0) }

    // MARK: Private

    private static func fire(_ p: NSHapticFeedbackManager.FeedbackPattern, after delay: Double) {
        guard SettingsManager.shared.hapticsEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
        }
    }
}

extension View {
    func hoverHaptic() -> some View {
        self.onHover { if $0 { Haptics.hover() } }
    }
}
