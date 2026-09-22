import SwiftUI

// MARK: - Themes
//
// Simplified to what macOS users actually expect: follow the system appearance,
// or force light/dark. Accent color always comes from System Settings (native).

enum AppTheme: String, CaseIterable, Identifiable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Migrates legacy multi-theme values stored by older builds.
    static func migrate(_ raw: String) -> AppTheme {
        switch raw {
        case "System": return .system
        case "Light", "Dawn", "Forest", "Mono Light": return .light
        case "Dark", "Midnight", "Ocean", "Slate", "Mono Dark": return .dark
        default: return .system
        }
    }
}

final class ThemeManager: ObservableObject {
    @Published var current: AppTheme = .system
    @AppStorage("fetchAppTheme") private var stored: String = AppTheme.system.rawValue

    init() {
        // One-shot migration of pre-simplification theme names
        if AppTheme(rawValue: stored) == nil {
            let migrated = AppTheme.migrate(stored)
            stored = migrated.rawValue
            current = migrated
        } else {
            current = AppTheme(rawValue: stored) ?? .system
        }
    }

    func set(_ theme: AppTheme) {
        current = theme
        stored = theme.rawValue
    }

    /// Always the system accent — matches every other macOS app.
    var accentColor: Color { .accentColor }

    var windowBackground: Color {
        switch current.colorScheme ?? .light {
        case .dark:  return Color(.windowBackgroundColor)
        case .light: return Color(.windowBackgroundColor)
        @unknown default: return Color(.windowBackgroundColor)
        }
    }

    func cardFill(blur: Bool) -> Color {
        if #available(macOS 26.0, *) {
            // Liquid Glass cards draw materials + glassEffect; this is only the solid fallback tint.
            return Color(.controlBackgroundColor).opacity(blur ? 0.40 : 0.92)
        }
        return Color(.controlBackgroundColor).opacity(blur ? 0.55 : 1.0)
    }

    var cardBorder: Color { Color(.separatorColor).opacity(blurEnabled ? 0.35 : 0.55) }
    var cardShadow: Color { .black }

    private var blurEnabled: Bool {
        SettingsManager.shared.useBlurBackground
    }

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.primary.opacity(0.03),
                Color.clear,
                Color.black.opacity(0.05)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    var cardFill: Color { cardFill(blur: SettingsManager.shared.useBlurBackground) }

    var blurMaterial: NSVisualEffectView.Material { .sidebar }
}
