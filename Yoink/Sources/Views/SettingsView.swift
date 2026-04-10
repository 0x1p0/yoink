import SwiftUI

// MARK: - Settings Window

struct SettingsView: View {
    @EnvironmentObject var settings:   SettingsManager
    @EnvironmentObject var deps:       DependencyService
    @EnvironmentObject var theme:      ThemeManager
    @EnvironmentObject var appUpdate:  AppUpdateService
    @State private var section: SettingsSection = .appearance

    enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance  = "Appearance"
        case downloads   = "Downloads"
        case output      = "Output"
        case network     = "Network"
        case automation  = "Automation"
        case performance = "Performance"
        case advanced    = "Advanced"
        case about       = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance:  return "paintpalette"
            case .downloads:   return "arrow.down.circle"
            case .output:      return "folder"
            case .network:     return "network"
            case .automation:  return "bolt.badge.automatic"
            case .performance: return "cpu"
            case .advanced:    return "gearshape.2"
            case .about:       return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Sidebar ──────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { sec in
                    SidebarItem(label: sec.rawValue, icon: sec.icon,
                                selected: section == sec) { section = sec }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
            .frame(width: 176)
            .background(Color(.windowBackgroundColor))

            Divider()

            // ── Detail ───────────────────────────────────────────────────
            Group {
                switch section {
                case .appearance:  AppearanceSettings()
                case .downloads:   DownloadSettings()
                case .output:      OutputSettings()
                case .network:     NetworkSettings()
                case .automation:  AutomationSettings()
                case .performance: PerformanceSettings()
                case .advanced:    AdvancedSettings()
                case .about:       AboutSettings()
                }
            }
            .environmentObject(settings)
            .environmentObject(deps)
            .environmentObject(theme)
            .environmentObject(appUpdate)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.windowBackgroundColor))
        }
        .background(Color(.windowBackgroundColor))
        .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 600)
    }
}

struct SidebarItem: View {
    let label: String; let icon: String; let selected: Bool; let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12)
                                  : (hovered ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .hoverHaptic()
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Shared Helpers

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                content
            }
            // Dividers are painted as a background overlay so the last one is clipped away
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separatorColor).opacity(0.45), lineWidth: 0.5))
        }
    }
}

// Adds a hairline separator between two adjacent settings rows
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 16).opacity(0.5)
    }
}

struct SettingsRow<Content: View>: View {
    let label:  String
    let detail: String?
    let icon:   String?
    @ViewBuilder var trailing: Content

    init(_ label: String, detail: String? = nil, icon: String? = nil,
         @ViewBuilder trailing: () -> Content) {
        self.label    = label
        self.detail   = detail
        self.icon     = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

// MARK: - Color hex helper (used in ThemeCell previews)

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let val = UInt64(h, radix: 16) ?? 0
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double( val        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Theme Cell

struct ThemeCell: View {
    let appTheme: AppTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    /// Preview swatch background - matches ThemeManager.windowBackground
    var bg: Color {
        switch appTheme {
        case .system:    return Color(.windowBackgroundColor)
        case .midnight:  return Color(hex: "#121224")   // deep navy
        case .dawn:      return Color(hex: "#FCF2DC")   // warm parchment
        case .forest:    return Color(hex: "#D9F5DE")   // jade mint
        case .ocean:     return Color(hex: "#071E2E")   // deep teal-blue
        case .monoDark:  return Color(hex: "#0A0A0A")   // mono dark bg-0
        case .slate:     return Color(hex: "#231B34")   // purple-grey
        case .monoLight: return Color(hex: "#FAFAFA")   // mono light bg-0
        }
    }
    /// Accent dot - vivid, unmistakably distinct per theme
    var dot: Color {
        switch appTheme {
        case .system:    return .accentColor
        case .midnight:  return Color(hex: "#6B94FF")   // violet-blue
        case .dawn:      return Color(hex: "#F5700D")   // amber-orange
        case .forest:    return Color(hex: "#0DC74C")   // leaf green
        case .ocean:     return Color(hex: "#00D1E0")   // electric teal/cyan
        case .monoDark:  return Color(hex: "#E83B2E")   // signature red dark
        case .slate:     return Color(hex: "#AC7AFF")   // lavender-purple
        case .monoLight: return Color(hex: "#D42D1E")   // signature red light
        }
    }
    var isDark: Bool { appTheme.colorScheme == .dark }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(bg)
                        .frame(width: 56, height: 40)
                    // Accent dot preview
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle().fill(i == 0 ? dot : dot.opacity(0.4 - Double(i) * 0.1))
                                .frame(width: i == 0 ? 8 : 5)
                        }
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(dot, lineWidth: 2.5)
                            .frame(width: 56, height: 40)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(dot)
                            .background(Circle().fill(bg).frame(width: 12, height: 12))
                            .offset(x: 19, y: -14)
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(hovered ? 0.18 : 0.08), lineWidth: 1)
                            .frame(width: 56, height: 40)
                    }
                }
                Text(appTheme.rawValue)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0; if $0 { Haptics.hover() } }
    }
}

// MARK: - Appearance Settings

struct AppearanceSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var theme:    ThemeManager
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                // ── Background blur - top priority, always visible ─────────
                SettingsGroup(title: "Background") {
                    SettingsRow("Frosted glass / blur",
                                detail: "Main window AND menu bar both use macOS acrylic - looks best with dark themes",
                                icon: "sparkles") {
                        Toggle("", isOn: $settings.useBlurBackground)
                            .labelsHidden()
                            .onChange(of: settings.useBlurBackground) { _ in Haptics.tap() }
                    }
                }

                // ── Theme ─────────────────────────────────────────────────
                SettingsGroup(title: "Theme") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Changes both main app and menu bar instantly")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.top, 12)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                            ForEach(AppTheme.allCases) { t in
                                ThemeCell(appTheme: t, selected: theme.current == t) {
                                    withAnimation(.spring(response: 0.2)) { theme.set(t) }
                                    Haptics.toggleOn()
                                }
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
                    }
                    Divider().opacity(0)
                }

                SettingsGroup(title: "Menu Bar Icon") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Choose what appears in your menu bar")
                            .font(.system(size: 12)).foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60, maximum: 90), spacing: 0), count: 3), spacing: 10) {
                            ForEach(MenuBarIcon.presets.filter { $0.kind == .sfSymbol }) { icon in
                                IconCell(icon: icon, selected: settings.menuBarIconId == icon.id) {
                                    settings.menuBarIconId = icon.id
                                    Haptics.tap()
                                }
                            }
                        }

                        // Dynamic numeric counter option - full-width special cell
                        let dynIcon = MenuBarIcon.presets.first { $0.kind == .dynamic }!
                        let dynSelected = settings.menuBarIconId == dynIcon.id
                        Button {
                            settings.menuBarIconId = dynIcon.id
                            Haptics.tap()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().stroke(Color.accentColor.opacity(0.3), lineWidth: 1.5).frame(width: 28)
                                    Circle().trim(from: 0, to: 0.6)
                                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                        .frame(width: 28).rotationEffect(.degrees(-90))
                                    Text("60")
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Download progress  -  0 to 100")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(dynSelected ? Color.accentColor : .primary)
                                    Text("Shows live percentage with progress ring")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if dynSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(dynSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(dynSelected ? Color.accentColor.opacity(0.4) : Color(.separatorColor).opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        // Custom text label (e.g. initials, short word, up to 4 chars)
                        CustomTextMenuBarRow()
                    }
                    .padding(14)
                    Divider().opacity(0)
                }

                // ── Display ───────────────────────────────────────────
                SettingsGroup(title: "Display") {
                    SettingsRow("Show in Dock",
                                detail: "App appears in the Dock alongside menu bar",
                                icon: "square.grid.3x3.square") {
                        Toggle("", isOn: $settings.showInDock)
                            .labelsHidden()
                            .onChange(of: settings.showInDock) { show in
                                if show {
                                    // Re-show in dock immediately when turned back on
                                    NSApp.setActivationPolicy(.regular)
                                }
                                // When turned off, dock icon disappears when window is next closed
                                // (handled in AppDelegate.windowWillClose)
                            }
                    }
                    SettingsDivider()
                    SettingsRow("Compact cards",
                                detail: "Smaller job cards, less padding",
                                icon: "rectangle.compress.vertical") {
                        Toggle("", isOn: $settings.compactCards).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Show thumbnails",
                                detail: "Load and display video thumbnails (slower metadata fetch)",
                                icon: "photo") {
                        Toggle("", isOn: $settings.showThumbnails).labelsHidden()
                    }
                }

                // ── Haptics ───────────────────────────────────────────────
                SettingsGroup(title: "Haptic Feedback") {
                    SettingsRow("Enable haptics",
                                detail: "Trackpad feedback on hover, download events",
                                icon: "hand.point.up.left") {
                        Toggle("", isOn: $settings.hapticsEnabled).labelsHidden()
                            .onChange(of: settings.hapticsEnabled) { _ in
                                // Fire async so we don't publish during view update
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Haptics.tap() }
                            }
                    }
                    SettingsDivider()
                    SettingsRow("Intensity",
                                detail: "How strong the feedback feels",
                                icon: "waveform.path") {
                        Picker("", selection: $settings.hapticIntensityRaw) {
                            Text("Light").tag("light")
                            Text("Medium").tag("medium")
                            Text("Strong").tag("strong")
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 180)
                        .disabled(!settings.hapticsEnabled)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Appearance")
    }
}

struct IconCell: View {
    let icon:     MenuBarIcon
    let selected: Bool
    let action:   () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if icon.kind == .emoji {
                        Text(icon.value).font(.system(size: 22))
                    } else {
                        Image(systemName: icon.value)
                            .font(.system(size: 20))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
                    }
                }
                .frame(width: 44, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.13)
                                       : (hovered ? Color.primary.opacity(0.06) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
                )

                Text(icon.label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)  // stretch to fill grid column evenly
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .hoverHaptic()
        .help(icon.label)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

// MARK: - Download Settings

struct DownloadSettings: View {
    @EnvironmentObject var settings: SettingsManager
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                SettingsGroup(title: "Defaults") {
                    SettingsRow("Default format", icon: "film") {
                        Picker("", selection: $settings.defaultFormatRaw) {
                            ForEach(DownloadFormat.allCases) { f in
                                Label(f.displayName, systemImage: f.icon).tag(f.rawValue)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 180)
                    }
                    SettingsDivider()
                    SettingsRow("After download", icon: "checkmark.circle") {
                        Picker("", selection: $settings.postDownloadRaw) {
                            ForEach(PostDownloadAction.allCases) { a in
                                Label(a.label, systemImage: a.icon).tag(a.rawValue)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 180)
                    }
                    SettingsDivider()
                    SettingsRow("Convert after download", detail: "Uses bundled ffmpeg - runs after every download", icon: "arrow.triangle.2.circlepath") {
                        Picker("", selection: $settings.postConvertRaw) {
                            ForEach(PostConvertAction.allCases) { a in
                                Label(a.label, systemImage: a.icon).tag(a.rawValue)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 200)
                    }
                    SettingsDivider()
                    SettingsRow("Concurrent downloads", icon: "arrow.down.to.line.alt") {
                        Picker("", selection: $settings.concurrentLimitRaw) {
                            ForEach(ConcurrentLimit.allCases) { l in Text(l.label).tag(l.rawValue) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 180)
                    }
                }

                SettingsGroup(title: "Subtitles") {
                    SettingsRow("Default language", detail: "Prefilled when subtitle toggle is on", icon: "captions.bubble") {
                        TextField("en", text: $settings.defaultSubLang)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 44).multilineTextAlignment(.center)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    SettingsDivider()
                    SettingsRow("Sync subs with SponsorBlock", detail: "Embeds subtitles so timestamps stay aligned after cuts", icon: "scissors") {
                        Text("Auto").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                SettingsGroup(title: "Post-processing") {
                    SettingsRow("Embed thumbnail", icon: "photo.badge.plus") {
                        Toggle("", isOn: $settings.embedThumbnail).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Write metadata tags", icon: "tag") {
                        Toggle("", isOn: $settings.addMetadata).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("SponsorBlock", detail: "Skip sponsored segments automatically", icon: "scissors") {
                        Toggle("", isOn: $settings.sponsorBlock).labelsHidden()
                    }
                }

                SettingsGroup(title: "Notifications") {
                    SettingsRow(
                        "Notify when queue finishes",
                        detail: "One notification when all downloads complete, instead of one per file",
                        icon: "bell.badge"
                    ) {
                        Toggle("", isOn: $settings.notifyOnQueueComplete).labelsHidden()
                    }
                }

                SiteFormatOverridesEditor()
                    .environmentObject(settings)
            }
            .padding(20)
        }
    }
}

// MARK: - Per-site format override editor

struct SiteFormatOverridesEditor: View {
    @EnvironmentObject var settings: SettingsManager

    // Suggested sites shown as quick-add chips
    private let suggestedSites: [(domain: String, label: String)] = [
        ("youtube.com",    "YouTube"),
        ("soundcloud.com", "SoundCloud"),
        ("twitch.tv",      "Twitch"),
        ("instagram.com",  "Instagram"),
        ("tiktok.com",     "TikTok"),
        ("twitter.com",    "Twitter / X"),
        ("vimeo.com",      "Vimeo"),
        ("reddit.com",     "Reddit"),
    ]

    @State private var customDomain = ""
    @State private var addingCustom  = false

    var body: some View {
        SettingsGroup(title: "Per-site default format") {
            VStack(alignment: .leading, spacing: 0) {

                // Header hint
                Text("Override the default format for specific sites. Only applied when you haven't manually chosen a format for that download.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                // Existing overrides
                let overrides = settings.siteFormatOverrides
                if !overrides.isEmpty {
                    Divider().opacity(0.07)
                    VStack(spacing: 0) {
                        ForEach(Array(overrides.keys.sorted().enumerated()), id: \.element) { idx, domain in
                            let formatRaw = overrides[domain] ?? DownloadFormat.best.rawValue
                            HStack(spacing: 10) {
                                // Domain label
                                Text(displayLabel(for: domain))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .frame(minWidth: 120, alignment: .leading)

                                Spacer()

                                // Format picker for this site
                                Picker("", selection: Binding(
                                    get: { formatRaw },
                                    set: { newVal in
                                        var dict = settings.siteFormatOverrides
                                        dict[domain] = newVal
                                        settings.siteFormatOverrides = dict
                                    }
                                )) {
                                    ForEach(DownloadFormat.allCases) { f in
                                        Label(f.displayName, systemImage: f.icon).tag(f.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 180)

                                // Remove button
                                Button {
                                    var dict = settings.siteFormatOverrides
                                    dict.removeValue(forKey: domain)
                                    settings.siteFormatOverrides = dict
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .help("Remove override for \(domain)")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))

                            if idx < overrides.count - 1 {
                                Divider().opacity(0.06).padding(.horizontal, 14)
                            }
                        }
                    }
                }

                // Add-site section
                Divider().opacity(0.07)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ADD SITE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    // Quick-add chips for common sites
                    let existing = settings.siteFormatOverrides
                    FlowLayout(spacing: 6) {
                        ForEach(suggestedSites.filter { existing[$0.domain] == nil }, id: \.domain) { site in
                            Button {
                                var dict = settings.siteFormatOverrides
                                dict[site.domain] = settings.defaultFormatRaw
                                settings.siteFormatOverrides = dict
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(site.label)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }

                        // Custom domain input
                        if addingCustom {
                            HStack(spacing: 5) {
                                TextField("e.g. bilibili.com", text: $customDomain)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 130)
                                    .onSubmit { commitCustomDomain() }

                                Button { commitCustomDomain() } label: {
                                    Image(systemName: "return")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                }
                                .buttonStyle(.plain)

                                Button { addingCustom = false; customDomain = "" } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                        } else {
                            Button {
                                addingCustom = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Custom…")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private func displayLabel(for domain: String) -> String {
        suggestedSites.first { $0.domain == domain }?.label ?? domain
    }

    private func commitCustomDomain() {
        let d = customDomain
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !d.isEmpty else { addingCustom = false; return }
        var dict = settings.siteFormatOverrides
        dict[d] = settings.defaultFormatRaw
        settings.siteFormatOverrides = dict
        customDomain = ""
        addingCustom = false
    }
}

// MARK: - Output Settings

struct OutputSettings: View {
    @EnvironmentObject var settings: SettingsManager
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                SettingsGroup(title: "File Naming") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Output filename template").font(.system(size: 13))
                        TextField("%(title)s.%(ext)s", text: $settings.outputTemplate)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                        TemplateTokens(template: $settings.outputTemplate)
                    }
                    .padding(14)
                    Divider().opacity(0)
                }

                SettingsGroup(title: "File Handling") {
                    SettingsRow("Avoid overwriting files",
                                detail: "Adds a number suffix if file exists",
                                icon: "doc.badge.plus") {
                        Toggle("", isOn: $settings.avoidOverwrite).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Keep partial downloads",
                                detail: "Useful for resuming interrupted downloads",
                                icon: "stop.circle") {
                        Toggle("", isOn: $settings.keepPartialFiles).labelsHidden()
                    }
                }

                OutputCategoryEditor()
            }
            .padding(20)
        }
    }
}

// MARK: - Output Category Editor

struct OutputCategoryEditor: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var categories: [OutputCategory] = []

    var body: some View {
        SettingsGroup(title: "Save Location Categories") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set a dedicated folder for each content type. Pick a category when downloading to auto-route files.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    ForEach(categories.indices, id: \.self) { i in
                        OutputCategoryRow(
                            category: $categories[i],
                            onPickFolder: { pickFolder(for: i) },
                            onDelete: {
                                withAnimation { _ = categories.remove(at: i) }
                                settings.outputCategories = categories
                            }
                        )
                        .environmentObject(settings)
                    }
                }

                Button {
                    withAnimation { categories.append(OutputCategory(name: "New Category", emoji: "📁", path: "")) }
                    settings.outputCategories = categories
                    Haptics.tap()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 12))
                        Text("Add Category").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).hoverHaptic()
            }
            .padding(14)
            Divider().opacity(0)
        }
        .onAppear { categories = settings.outputCategories }
    }

    // Use NSOpenPanel directly - avoids the NSRendezvousSheetDelegate crash
    // that occurs when SwiftUI's .fileImporter tries to attach a sheet to
    // the Settings panel window (which has a different delegate chain).
    private func pickFolder(for index: Int) {
        let panel = NSOpenPanel()
        panel.title          = "Choose folder for \(categories[index].name)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        // Run as a free-floating panel, not attached to any window
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            _ = url.startAccessingSecurityScopedResource()
            categories[index].path = url.path
            settings.outputCategories = categories
        }
    }
}

struct OutputCategoryRow: View {
    @Binding var category: OutputCategory
    let onPickFolder: () -> Void
    let onDelete: () -> Void
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $category.emoji)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .frame(width: 36, height: 32)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                .onChange(of: category.emoji) { v in
                    guard !v.isEmpty else { return }
                    var idx = v.startIndex; v.formIndex(after: &idx)
                    let first = String(v[v.startIndex..<idx])
                    if category.emoji != first { category.emoji = first }
                    settings.outputCategories = settings.outputCategories.map {
                        $0.id == category.id ? category : $0
                    }
                }

            TextField("Category name", text: $category.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110)
                .onSubmit {
                    settings.outputCategories = settings.outputCategories.map {
                        $0.id == category.id ? category : $0
                    }
                }

            Button(action: onPickFolder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text(category.path.isEmpty ? "Choose folder…" : URL(fileURLWithPath: category.path).lastPathComponent)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(category.path.isEmpty ? Color.secondary : Color.primary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain).hoverHaptic()
            .help(category.path.isEmpty ? "Choose a folder" : category.path)

            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.red.opacity(0.6))
            }
            .buttonStyle(.plain).hoverHaptic()
        }
    }
}

struct CategoryPicker: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var queue: DownloadQueue

    var categories: [OutputCategory] { settings.outputCategories.filter { !$0.path.isEmpty } }

    var currentName: String {
        if let cat = categories.first(where: { URL(fileURLWithPath: $0.path) == queue.outputDirectory }) {
            return "\(cat.emoji) \(cat.name)"
        }
        return queue.outputDirectory.lastPathComponent
    }

    var body: some View {
        if !categories.isEmpty {
            Menu {
                ForEach(categories) { cat in
                    Button {
                        queue.outputDirectory = URL(fileURLWithPath: cat.path)
                        Haptics.tap()
                    } label: {
                        Label("\(cat.emoji) \(cat.name)", systemImage: URL(fileURLWithPath: cat.path) == queue.outputDirectory ? "checkmark" : "folder")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 10, weight: .medium))
                    Text(currentName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hoverHaptic()
            .help("Save location category")
        }
    }
}

struct TemplateTokens: View {
    @Binding var template: String

    let tokens: [(token: String, label: String, icon: String, example: String)] = [
        ("%(title)s",       "Title",       "text.quote",             "My Awesome Video"),
        ("%(id)s",          "Video ID",    "number",                 "dQw4w9WgXcQ"),
        ("%(ext)s",         "Extension",   "doc",                    "mp4"),
        ("%(uploader)s",    "Channel",     "person",                 "Rick Astley"),
        ("%(upload_date)s", "Upload Date", "calendar",               "20231215"),
        ("%(resolution)s",  "Resolution",  "arrow.up.left.and.arrow.down.right", "1920x1080"),
        ("%(duration_string)s", "Duration","clock",                  "3:33"),
        ("%(playlist_index)s",  "Playlist #","list.number",          "03"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap a token to insert it at the cursor")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            // Live preview
            if !template.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(previewTemplate(template))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Token grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 140), spacing: 8), count: 2), spacing: 8) {
                ForEach(tokens, id: \.token) { t in
                    TokenChip(token: t.token, label: t.label, icon: t.icon, example: t.example) {
                        template += t.token
                        Haptics.tap()
                    }
                }
            }

            // Quick presets
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK PRESETS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    ForEach(presets, id: \.label) { p in
                        Button {
                            template = p.value
                            Haptics.tap()
                        } label: {
                            Text(p.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(template == p.value ? Color.accentColor : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(template == p.value
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(template == p.value
                                        ? Color.accentColor.opacity(0.3)
                                        : Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .hoverHaptic()
                        .help(p.value)
                    }
                }
            }
        }
    }

    let presets: [(label: String, value: String)] = [
        ("Default",   "%(title)s.%(ext)s"),
        ("With date", "%(upload_date)s - %(title)s.%(ext)s"),
        ("Organised", "%(uploader)s/%(upload_date)s - %(title)s.%(ext)s"),
        ("ID + title","%(id)s - %(title)s.%(ext)s"),
    ]

    func previewTemplate(_ t: String) -> String {
        t.replacingOccurrences(of: "%(title)s",           with: "My Awesome Video")
         .replacingOccurrences(of: "%(id)s",              with: "dQw4w9WgXcQ")
         .replacingOccurrences(of: "%(ext)s",             with: "mp4")
         .replacingOccurrences(of: "%(uploader)s",        with: "Rick Astley")
         .replacingOccurrences(of: "%(upload_date)s",     with: "20231215")
         .replacingOccurrences(of: "%(resolution)s",      with: "1920x1080")
         .replacingOccurrences(of: "%(duration_string)s", with: "3:33")
         .replacingOccurrences(of: "%(playlist_index)s",  with: "03")
    }
}

struct TokenChip: View {
    let token: String; let label: String; let icon: String; let example: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(token)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                }
                Spacer(minLength: 0)
                if hovered {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovered ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(hovered ? Color.accentColor.opacity(0.3) : Color(.separatorColor).opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Insert \(token)  (example: \(example))")
    }
}

// Simple horizontal flow layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0; var maxY: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            rowH = max(rowH, sz.height); x += sz.width + spacing; maxY = y + rowH
        }
        return CGSize(width: width, height: maxY)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            rowH = max(rowH, sz.height); x += sz.width + spacing
        }
    }
}

// MARK: - Network Settings

struct NetworkSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var rateLimitText = ""
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                SettingsGroup(title: "Bandwidth") {
                    SettingsRow("Rate limit", detail: "0 = unlimited", icon: "speedometer") {
                        HStack(spacing: 6) {
                            TextField("0", text: $rateLimitText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .frame(width: 60).multilineTextAlignment(.trailing)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .onAppear { rateLimitText = settings.rateLimitKbps == 0 ? "" : "\(settings.rateLimitKbps)" }
                                .onChange(of: rateLimitText) { v in settings.rateLimitKbps = Int(v.filter(\.isNumber)) ?? 0 }
                            Text("KB/s").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Retry attempts", icon: "arrow.triangle.2.circlepath") {
                        Stepper("\(settings.retryCount)", value: $settings.retryCount, in: 0...10)
                            .frame(width: 110)
                    }
                }

                SettingsGroup(title: "Proxy") {
                    SettingsRow("Use proxy", icon: "network.badge.shield.half.filled") {
                        Toggle("", isOn: $settings.useProxy).labelsHidden()
                    }
                    if settings.useProxy {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Proxy URL").font(.system(size: 12)).foregroundStyle(.secondary)
                            TextField("http://127.0.0.1:8080", text: $settings.proxyURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        Divider().padding(.leading, 16).opacity(0.5)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Performance Settings

struct PerformanceSettings: View {
    @EnvironmentObject var settings: SettingsManager

    // Thread slider: 1–16 plus 0 = auto
    private let threadOptions = [0, 1, 2, 4, 6, 8, 12, 16]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                SettingsGroup(title: "CPU Usage") {
                    SettingsRow("Process priority", detail: "Controls which CPU cores macOS uses", icon: "cpu") {
                        Picker("", selection: $settings.processPriorityRaw) {
                            ForEach(ProcessQoS.allCases) { qos in
                                Text(qos.label).tag(qos.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                    }

                    SettingsDivider()

                    SettingsRow("ffmpeg threads", detail: "Threads used during merge & SponsorBlock", icon: "slider.horizontal.3") {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 10) {
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.ffmpegThreads) },
                                        set: { settings.ffmpegThreads = Int($0) }
                                    ),
                                    in: 0...16,
                                    step: 1
                                )
                                .frame(width: 160)
                                Text(settings.ffmpegThreads == 0 ? "Auto" : "\(settings.ffmpegThreads)")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .frame(width: 36, alignment: .trailing)
                            }
                            Text(settings.ffmpegThreads == 0
                                 ? "All cores - maximum speed, most heat"
                                 : settings.ffmpegThreads <= 2 ? "Very cool, slightly slower"
                                 : settings.ffmpegThreads <= 4 ? "Balanced - recommended for M-series"
                                 : settings.ffmpegThreads <= 8 ? "Fast, moderate heat"
                                 : "Very fast, high heat")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsGroup(title: "What these do") {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(icon: "arrow.down.circle", color: .blue,
                                title: "Downloading",
                                description: "Network-bound - priority has minimal effect on speed or heat.")
                        InfoRow(icon: "wand.and.stars", color: .purple,
                                title: "Merging & SponsorBlock",
                                description: "CPU-bound - this is where threads and priority matter. Fewer threads = cooler Mac.")
                        InfoRow(icon: "thermometer.medium", color: .orange,
                                title: "Recommended for M4",
                                description: "Priority: Balanced. Threads: 4. Uses efficiency cores, keeps Mac cool, still fast.")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }

            }
            .padding(20)
        }
    }
}

private struct InfoRow: View {
    let icon: String; let color: Color
    let title: String; let description: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettings: View {
    @EnvironmentObject var settings:  SettingsManager
    @EnvironmentObject var deps:      DependencyService
    @EnvironmentObject var appUpdate: AppUpdateService
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                SettingsGroup(title: "yt-dlp Extra Arguments") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Appended to every yt-dlp call. Use with care.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        TextField("e.g. --no-mtime --geo-bypass", text: $settings.ytdlpExtraArgs)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                    }
                    .padding(14)
                    Divider().opacity(0)
                }

                SettingsGroup(title: "Engine Updates (yt-dlp & ffmpeg)") {
                    SettingsRow("Check on launch", icon: "arrow.triangle.2.circlepath") {
                        Toggle("", isOn: $settings.checkUpdatesOnLaunch).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Check now", detail: "yt-dlp \(deps.ytdlp.statusLabel) · ffmpeg \(deps.ffmpeg.statusLabel)", icon: "magnifyingglass") {
                        Button("Check") { Task { await deps.checkYtdlp(); await deps.checkFfmpeg() } }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                // App self-update section
                SettingsGroup(title: "App Updates") {
                    SettingsRow("Check for Yoink updates daily", icon: "app.badge") {
                        Toggle("", isOn: $settings.checkUpdatesOnLaunch).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("Current status",
                                detail: appUpdate.statusLabel,
                                icon: "info.circle") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(appUpdate.dotColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: appUpdate.dotColor.opacity(0.5), radius: 3)
                            Button(appUpdate.status == .checking ? "Checking…" : "Check Now") {
                                appUpdate.checkForUpdates()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Color.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .disabled(appUpdate.status == .checking)
                        }
                    }
                    if case .available(_, let latest, _) = appUpdate.status {
                        SettingsDivider()
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 13)).foregroundStyle(.orange).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Yoink \(latest) is available")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.orange)
                                Text("Click to download the latest release")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Download") { appUpdate.openDownloadPage() }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Color.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                    }
                }

                SettingsGroup(title: "Danger Zone") {
                    SettingsRow("Reset all settings", detail: "Restores defaults, doesn't delete files",
                                icon: "arrow.counterclockwise") {
                        Button("Reset") {
                            if let domain = Bundle.main.bundleIdentifier {
                                UserDefaults.standard.removePersistentDomain(forName: domain)
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject var deps:      DependencyService
    @EnvironmentObject var appUpdate: AppUpdateService
    @State private var showTutorial = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            // App icon + name
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 46)).foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                }
                Text("Yoink")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")  ·  Built with SwiftUI")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            // App update status pill
            Button {
                if case .available = appUpdate.status { appUpdate.openDownloadPage() }
                else { appUpdate.checkForUpdates() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appUpdate.dotColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: appUpdate.dotColor.opacity(0.5), radius: 3)
                    Text(appUpdate.statusLabel)
                        .font(.system(size: 12, weight: .medium))
                    if case .available = appUpdate.status {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(appUpdate.status == AppUpdateStatus.unknown ? Color.secondary :
                                 (appUpdate.dotColor == .orange ? .orange : Color.primary))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hoverHaptic()

            // Dep chips
            VStack(spacing: 10) {
                DepStatusChip(label: "yt-dlp",  status: deps.ytdlp)
                DepStatusChip(label: "ffmpeg",  status: deps.ffmpeg)
            }
            .frame(maxWidth: 280)

            HStack(spacing: 14) {
                Link("yt-dlp on GitHub", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                Link("Homebrew", destination: URL(string: "https://brew.sh")!)
            }
            .font(.system(size: 13)).foregroundStyle(Color.accentColor)

            // Tutorial button
            Button {
                showTutorial = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 12))
                    Text("Show Tutorial")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .hoverHaptic()

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showTutorial) {
            TutorialView { showTutorial = false }
        }
    }
}

struct DepStatusChip: View {
    let label: String; let status: DepStatus
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(status.dotColor).frame(width: 8)
                .shadow(color: status.dotColor.opacity(0.5), radius: 3)
            Text(label).font(.system(size: 13, weight: .medium, design: .monospaced))
            Spacer()
            Text(status.statusLabel).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - Onboarding helpers (used in ContentView)

struct StatusRow: View {
    let icon: String; let color: Color; let text: String; let detail: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

struct StepRow: View {
    let number: String; let title: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white).frame(width: 22, height: 22)
                .background(Color.accentColor).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ToolRow: View {
    let name: String; let status: DepStatus
    let installing: Bool; let onInstall: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(status.dotColor).frame(width: 8, height: 8)
                .shadow(color: status.dotColor.opacity(0.5), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(status.statusLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if installing {
                ProgressView().scaleEffect(0.7)
            } else if case .failed = status {
                Button("Retry") { onInstall() }
                    .buttonStyle(PrimaryButtonStyle())
                    .font(.system(size: 12))
            } else if case .missing = status {
                Button("Re-check") { onInstall() }
                    .buttonStyle(PrimaryButtonStyle())
                    .font(.system(size: 12))
            } else if status.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 16))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
    }
}

// MARK: - Custom Text Menu Bar Row

struct CustomTextMenuBarRow: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var customText = ""
    private var isActive: Bool { settings.menuBarIconId.hasPrefix("text_") }

    var body: some View {
        HStack(spacing: 10) {
            Text("Custom text:")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("YK", text: $customText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(width: 48).multilineTextAlignment(.center)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(isActive ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                .onChange(of: customText) { v in
                    if v.count > 4 { customText = String(v.prefix(4)) }
                }
            Text("max 4 chars")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            if !customText.isEmpty {
                Button("Use this") {
                    settings.menuBarIconId = "text_\(customText)"
                    Haptics.tap()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .onAppear {
            if settings.menuBarIconId.hasPrefix("text_") {
                customText = String(settings.menuBarIconId.dropFirst(5))
            }
        }
    }
}

// MARK: - Emoji Progress Set Editor

struct EmojiProgressSetEditor: View {
    @EnvironmentObject var settings: SettingsManager
    var onActivate: (() -> Void)? = nil

    @State private var slots: [String] = []
    // "Enter your 10" bulk input mode
    @State private var bulkInput = ""
    @State private var showBulkInput = false

    private let labels = ["Idle","10%","20%","30%","40%","50%","60%","70%","80%","90%","100%"]
    private let presets: [(String, [String])] = [
        ("Numbers",   ["0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟"]),
        ("Fire",      ["🌑","🔥","🔥","🔥","🔥","🔥","🔥","🔥","🔥","🔥","💥"]),
        ("Battery",   ["🪫","🔋","🔋","🔋","🔋","🔋","🔋","🔋","🔋","🔋","✅"]),
        ("Rocket",    ["🚀","🌍","🌕","☄️","🛸","⭐","💫","🌟","🌠","🎇","🎆"]),
        ("Food",      ["🍕","🍕","🍔","🌮","🌯","🥙","🥪","🍜","🍝","🍱","🎉"]),
        ("Music",     ["🎵","🎶","🎸","🥁","🎺","🎷","🎹","🎻","🎤","🎧","🎊"]),
    ]

    // Extract grapheme clusters (emoji-safe) from a string
    private func graphemes(_ s: String) -> [String] {
        s.unicodeScalars.reduce(into: [String]()) { arr, scalar in
            let ch = String(scalar)
            // Variation selector / zero-width joiner → append to previous
            if scalar.value == 0xFE0F || scalar.value == 0x200D,
               !arr.isEmpty {
                arr[arr.count - 1] += ch
            } else {
                arr.append(ch)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack {
                Text("Progress emoji sequence")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Reset") {
                    slots = ["0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟"]
                    save(); onActivate?(); Haptics.tap()
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("Shown in the menu bar: idle state + 10%→100% steps (11 total)")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            // Preset chips - fixed width so they align in a clean row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.0) { name, emojis in
                        Button {
                            slots = emojis; save(); onActivate?(); Haptics.tap()
                        } label: {
                            HStack(spacing: 3) {
                                Text(emojis[0]).font(.system(size: 12))
                                Text("→").font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(emojis[10]).font(.system(size: 12))
                                Text(name).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain).hoverHaptic()
                    }
                }
                .padding(.vertical, 2)
            }

            // 11 individual slot cells - uniform fixed columns
            HStack(spacing: 4) {
                ForEach(0..<11, id: \.self) { i in
                    EmojiSlotCell(emoji: Binding(
                        get: { i < slots.count ? slots[i] : "❓" },
                        set: { v in
                            while slots.count <= i { slots.append("❓") }
                            slots[i] = v; save(); onActivate?()
                        }
                    ), label: labels[i])
                }
            }

            // "Enter your own 11 emojis" bulk input button + popover
            HStack(spacing: 8) {
                Button {
                    bulkInput = slots.joined()
                    showBulkInput = true
                    onActivate?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "keyboard").font(.system(size: 11))
                        Text("Enter your own 11 emojis…")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain).hoverHaptic()
                .popover(isPresented: $showBulkInput, arrowEdge: .bottom) {
                    BulkEmojiInputPopover(input: $bulkInput, onApply: { str in
                        let parsed = parseEmojis(str)
                        guard parsed.count == 11 else { return }
                        slots = parsed; save(); onActivate?()
                        showBulkInput = false
                        Haptics.success()
                    })
                }

                if showBulkInput == false && !slots.isEmpty {
                    Text("Paste or type 11 emojis side-by-side")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .onAppear { _ = parseEmojis(bulkInput) }
                }
            }
        }
        .onAppear { slots = settings.progressEmojiSet }
    }

    func save() {
        guard slots.count == 11 else { return }
        settings.progressEmojiSetRaw = slots.joined(separator: ",")
    }

    func parseEmojis(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in input.unicodeScalars {
            if scalar.value == 0xFE0F || scalar.value == 0x200D || scalar.value == 0x20E3 {
                current += String(scalar)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(scalar)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Bulk Emoji Input Popover

struct BulkEmojiInputPopover: View {
    @Binding var input: String
    let onApply: (String) -> Void
    @State private var parsed: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter 11 emojis")
                .font(.system(size: 13, weight: .semibold))
            Text("Type or paste 11 emojis in a row - one for idle + 10 for 10%→100%")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            TextField("e.g. 🌑🔥🔥🔥🔥🔥🔥🔥🔥🔥💥", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.separatorColor).opacity(0.5), lineWidth: 0.5))
                .onChange(of: input) { v in
                    parsed = parseEmojis(v)
                }

            // Live preview of parsed emojis
            if !parsed.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(parsed.prefix(11).enumerated()), id: \.offset) { _, e in
                        Text(e).font(.system(size: 18))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                    Text("\(min(parsed.count, 11))/11")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(parsed.count >= 11 ? .green : .secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { input = ""; }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                Button("Apply") { onApply(input) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(parsed.count >= 11 ? Color.accentColor : Color.secondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .disabled(parsed.count < 11)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { parsed = parseEmojis(input) }
    }

    func parseEmojis(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        for scalar in input.unicodeScalars {
            if scalar.value == 0xFE0F || scalar.value == 0x200D || scalar.value == 0x20E3 {
                current += String(scalar)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(scalar)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

// MARK: - Single emoji slot cell

struct EmojiSlotCell: View {
    @Binding var emoji: String
    let label: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 3) {
            TextField("", text: $emoji)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(focused ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.4) : Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                .focused($focused)
                .onChange(of: emoji) { v in
                    guard !v.isEmpty else { return }
                    // Keep only first grapheme cluster
                    var idx = v.startIndex
                    v.formIndex(after: &idx)
                    let first = String(v[v.startIndex..<idx])
                    if emoji != first { emoji = first }
                }
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Presets Settings

struct AutomationSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @StateObject private var scheduled = ScheduledDownloadStore.shared
    @State private var newDomain = ""
    @State private var confirmResetDomains = false

    var domains: [String] { settings.clipboardDomains }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {

                // Clipboard monitor toggle
                SettingsGroup(title: "Clipboard Monitor") {
                    SettingsRow("Watch clipboard for video links",
                                detail: "Yoink fires a system notification whenever you copy a supported URL anywhere on your Mac - in Safari, Brave, Chrome, anywhere. Hover the notification to see Download Now / Watch Later buttons.",
                                icon: "doc.on.clipboard") {
                        Toggle("", isOn: $settings.clipboardMonitor).labelsHidden()
                    }
                    if ClipboardMonitor.shared.isSnoozed, let label = ClipboardMonitor.shared.snoozeLabel {
                        SettingsDivider()
                        SettingsRow("Snoozed", detail: "Clipboard monitoring is temporarily paused", icon: "bell.slash") {
                            HStack(spacing: 8) {
                                Text(label)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.orange)
                                Button("Cancel snooze") { ClipboardMonitor.shared.clearSnooze() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow("\"Download Now\" - Remove sponsors",
                                detail: "When you tap Download Now on a clipboard notification, automatically remove sponsor segments using SponsorBlock.",
                                icon: "shield.fill") {
                        Toggle("", isOn: $settings.notifSponsorBlock).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow("\"Download Now\" - Download subtitles",
                                detail: "When you tap Download Now on a clipboard notification, automatically download subtitles if available.",
                                icon: "captions.bubble.fill") {
                        Toggle("", isOn: $settings.notifSubtitles).labelsHidden()
                    }
                }

                // Domain list
                SettingsGroup(title: "Detected Domains") {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Yoink watches for links from these domains. Add any site yt-dlp supports.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

                        ForEach(domains, id: \.self) { domain in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.2))
                                    .frame(width: 6, height: 6)
                                Text(domain)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                Spacer()
                                // Only allow removing if not the last one
                                if domains.count > 1 {
                                    Button {
                                        var d = settings.clipboardDomains
                                        d.removeAll { $0 == domain }
                                        settings.clipboardDomains = d
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            SettingsDivider()
                        }

                        // Add new domain row
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12)).foregroundStyle(Color.accentColor.opacity(0.7))
                            TextField("Add domain  e.g. peertube.social", text: $newDomain)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                .onSubmit { addDomain() }
                            if !newDomain.isEmpty {
                                Button("Add") { addDomain() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)

                        SettingsDivider()

                        // Reset to defaults
                        Button {
                            confirmResetDomains = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise").font(.system(size: 10))
                                Text("Reset to defaults").font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .confirmationDialog("Reset domain list to defaults?", isPresented: $confirmResetDomains) {
                            Button("Reset", role: .destructive) {
                                settings.clipboardDomainsRaw = ""  // empty = use defaults
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }
                    Divider().opacity(0)
                }

                // Auto-organize
                SettingsGroup(title: "Auto-Organize") {
                    SettingsRow("Sort downloads into site folders",
                                detail: "Moves files into subfolders like YouTube/, Twitch/ inside your download folder",
                                icon: "folder.badge.gearshape") {
                        Toggle("", isOn: $settings.autoOrganizeBySite).labelsHidden()
                    }
                }

                // Shortcuts
                SettingsGroup(title: "Apple Shortcuts") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Run an Apple Shortcut after every download completes. The file path is passed as input.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.purple)
                            TextField("Shortcut name (leave blank to disable)", text: $settings.shortcutOnComplete)
                                .textFieldStyle(.plain).font(.system(size: 13))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color(.separatorColor).opacity(0.4), lineWidth: 0.5))
                        Button {
                            NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                                Text("Open Shortcuts app").font(.system(size: 11))
                            }.foregroundStyle(Color.accentColor)
                        }.buttonStyle(.plain)
                    }
                    .padding(14)
                    Divider().opacity(0)
                }

                // Scheduled downloads
                if !scheduled.items.isEmpty {
                    SettingsGroup(title: "Scheduled Downloads (\(scheduled.items.count))") {
                        VStack(spacing: 0) {
                            ForEach(scheduled.items) { item in
                                ScheduledItemRow(item: item)
                                SettingsDivider()
                            }
                        }
                        Divider().opacity(0)
                    }
                }
            }
            .padding(20)
        }
    }

    private func addDomain() {
        let trimmed = newDomain
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        guard !trimmed.isEmpty, !domains.contains(trimmed) else { newDomain = ""; return }
        var d = settings.clipboardDomains
        d.append(trimmed)
        settings.clipboardDomains = d
        newDomain = ""
    }
}

// MARK: - Scheduled Item Row (live countdown)

struct ScheduledItemRow: View {
    let item: ScheduledDownload
    @StateObject private var clock = RowClock()

    private var secondsUntil: Int { max(0, Int(item.scheduledAt.timeIntervalSince(clock.now))) }

    private var countdownText: String {
        let s = secondsUntil
        guard s > 0 else { return item.fired ? "Started" : "Starting…" }
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        if h > 0 { return "In \(h)h \(m)m \(sec)s" }
        if m > 0 { return "In \(m)m \(sec)s" }
        return "In \(sec)s"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.fired ? "checkmark.circle.fill" : "clock.fill")
                .font(.system(size: 12))
                .foregroundStyle(item.fired ? .green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if !item.fired {
                        Text("·").foregroundStyle(.tertiary)
                        Text(countdownText)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(secondsUntil < 60 ? Color.orange : Color.accentColor)
                    }
                }
            }
            Spacer()
            Button { ScheduledDownloadStore.shared.remove(item) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary.opacity(0.5))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
