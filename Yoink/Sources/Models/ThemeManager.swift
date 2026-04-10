import SwiftUI

// MARK: - Themes

enum AppTheme: String, CaseIterable, Identifiable {
    case system    = "System"
    case midnight  = "Midnight"
    case dawn      = "Dawn"
    case forest    = "Forest"
    case ocean     = "Ocean"
    case monoDark  = "Mono Dark"
    case slate     = "Slate"
    case monoLight = "Mono Light"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system:    return "circle.lefthalf.filled"
        case .midnight:  return "moon.stars.fill"
        case .dawn:      return "sunrise.fill"
        case .forest:    return "leaf.fill"
        case .ocean:     return "drop.fill"
        case .monoDark:  return "circle.fill"
        case .slate:     return "rectangle.fill"
        case .monoLight: return "circle"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:                                return nil
        case .dawn, .forest, .monoLight:             return .light
        case .midnight, .slate, .ocean, .monoDark:   return .dark
        }
    }
}

final class ThemeManager: ObservableObject {
    @Published var current: AppTheme = .system
    @AppStorage("fetchAppTheme") private var stored: String = AppTheme.system.rawValue

    init() { if let t = AppTheme(rawValue: stored) { current = t } }
    func set(_ theme: AppTheme) { current = theme; stored = theme.rawValue }

    // MARK: - Accent - each theme has a vivid, unmistakable accent
    var accentColor: Color {
        switch current {
        case .system:    return Color.accentColor
        case .midnight:  return Color(red: 0.42, green: 0.58, blue: 1.00)   // violet-blue
        case .dawn:      return Color(red: 0.96, green: 0.44, blue: 0.05)   // deep amber-orange
        case .forest:    return Color(red: 0.05, green: 0.78, blue: 0.30)   // vivid leaf green
        case .ocean:     return Color(red: 0.00, green: 0.82, blue: 0.88)   // electric teal/cyan
        case .monoDark:  return Color(hex: "#E83B2E")                        // signature red
        case .slate:     return Color(red: 0.68, green: 0.48, blue: 1.00)   // lavender-purple
        case .monoLight: return Color(hex: "#D42D1E")                        // signature red (light)
        }
    }

    // MARK: - Window background (when blur is OFF)
    var windowBackground: Color {
        switch current {
        case .system:    return Color(.windowBackgroundColor)
        case .midnight:  return Color(red: 0.07, green: 0.08, blue: 0.14)
        case .dawn:      return Color(red: 0.99, green: 0.95, blue: 0.86)
        case .forest:    return Color(red: 0.85, green: 0.96, blue: 0.87)
        case .ocean:     return Color(red: 0.03, green: 0.12, blue: 0.18)
        case .monoDark:  return Color(hex: "#0A0A0A")                        // bg-0 dark
        case .slate:     return Color(red: 0.14, green: 0.11, blue: 0.20)
        case .monoLight: return Color(hex: "#FAFAFA")                        // bg-0 light
        }
    }

    // MARK: - Card fill
    func cardFill(blur: Bool) -> Color {
        if blur {
            switch current {
            case .system:    return Color(.controlBackgroundColor).opacity(0.50)
            case .midnight:  return Color(white: 1, opacity: 0.05)
            case .dawn:      return Color(red: 1.0, green: 0.97, blue: 0.90).opacity(0.65)
            case .forest:    return Color(red: 0.88, green: 1.00, blue: 0.90).opacity(0.62)
            case .ocean:     return Color(red: 0.00, green: 0.20, blue: 0.28).opacity(0.65)
            case .monoDark:  return Color(hex: "#121212").opacity(0.80)      // bg-1 dark
            case .slate:     return Color(red: 0.20, green: 0.15, blue: 0.30).opacity(0.60)
            case .monoLight: return Color(hex: "#F0F0F0").opacity(0.80)      // bg-1 light
            }
        } else {
            switch current {
            case .system:    return Color(.controlBackgroundColor)
            case .midnight:  return Color(white: 1, opacity: 0.07)
            case .dawn:      return Color(red: 1.00, green: 0.97, blue: 0.88)
            case .forest:    return Color(red: 0.90, green: 1.00, blue: 0.92)
            case .ocean:     return Color(red: 0.04, green: 0.18, blue: 0.26)
            case .monoDark:  return Color(hex: "#121212")                    // bg-1 dark
            case .slate:     return Color(red: 0.20, green: 0.15, blue: 0.28)
            case .monoLight: return Color(hex: "#F0F0F0")                    // bg-1 light
            }
        }
    }

    var cardBorder: Color {
        switch current {
        case .system:    return Color(.separatorColor).opacity(0.55)
        case .midnight:  return Color(white: 1, opacity: 0.10)
        case .dawn:      return Color(red: 0.85, green: 0.75, blue: 0.55).opacity(0.60)
        case .forest:    return Color(red: 0.25, green: 0.80, blue: 0.38).opacity(0.40)
        case .ocean:     return Color(red: 0.00, green: 0.65, blue: 0.80).opacity(0.40)
        case .monoDark:  return Color(hex: "#2E2E2E")                        // bg-3 dark
        case .slate:     return Color(red: 0.68, green: 0.48, blue: 1.00).opacity(0.20)
        case .monoLight: return Color(hex: "#CCCCCC")                        // bg-3 light
        }
    }

    var cardShadow: Color { .black }

    var backgroundGradient: LinearGradient {
        switch current {
        case .system, .dawn, .monoLight, .forest:
            return LinearGradient(colors: [.white.opacity(0), .black.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        case .midnight, .slate, .ocean, .monoDark:
            return LinearGradient(colors: [.white.opacity(0.02), .black.opacity(0.08)], startPoint: .top, endPoint: .bottom)
        }
    }

    var cardFill: Color { cardFill(blur: SettingsManager.shared.useBlurBackground) }

    var blurMaterial: NSVisualEffectView.Material {
        switch current {
        case .system, .dawn, .monoLight, .forest: return .sidebar
        case .midnight, .slate, .ocean, .monoDark: return .popover
        }
    }
}
