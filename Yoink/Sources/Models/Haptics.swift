import AppKit
import SwiftUI

// MARK: - Haptic Feedback
//
// Native macOS apps do not fire trackpad haptics on hover or every micro-interaction.
// Hover haptics are disabled entirely. Event haptics (tap/success) remain available
// as an opt-in preference for users who want them, defaulting to off.

enum Haptics {

    static func tap() { fire(.generic) }

    static func toggleOn() {
        fire(.generic)
        fire(.alignment, after: 0.055)
    }

    static func toggleOff() { fire(.generic) }

    static func start() {
        fire(.alignment)
        fire(.levelChange, after: 0.065)
    }

    static func success() {
        fire(.alignment)
        fire(.alignment, after: 0.075)
        fire(.levelChange, after: 0.17)
    }

    static func error() {
        fire(.generic)
        fire(.generic, after: 0.11)
    }

    static func tick() { fire(.generic) }

    // MARK: Private

    private static func fire(_ p: NSHapticFeedbackManager.FeedbackPattern, after delay: Double = 0) {
        guard SettingsManager.shared.hapticsEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now)
        }
    }
}
