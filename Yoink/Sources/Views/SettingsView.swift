import SwiftUI

// MARK: - Settings Window
//
// Laid out like System Settings: a sidebar of sections with coloured icons, and native
// grouped forms on the right. Grouped forms pick up the system's Liquid Glass styling on
// macOS 26 and stay perfectly native on earlier releases.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, downloads, files, automation, network, performance, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:     return "General"
        case .appearance:  return "Appearance"
        case .downloads:   return "Downloads"
        case .files:       return "Files & Folders"
        case .automation:  return "Clipboard & Automation"
        case .network:     return "Network"
        case .performance: return "Performance"
        case .advanced:    return "Advanced"
        case .about:       return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape.fill"
        case .appearance:  return "paintbrush.fill"
        case .downloads:   return "arrow.down.circle.fill"
        case .files:       return "folder.fill"
        case .automation:  return "doc.on.clipboard.fill"
        case .network:     return "network"
        case .performance: return "gauge.with.needle.fill"
        case .advanced:    return "wrench.and.screwdriver.fill"
        case .about:       return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general:     return .gray
        case .appearance:  return .blue
        case .downloads:   return .accentColor
        case .files:       return .cyan
        case .automation:  return .orange
        case .network:     return .indigo
        case .performance: return .pink
        case .advanced:    return .gray
        case .about:       return .purple
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings:   SettingsManager
    @EnvironmentObject var deps:       DependencyService
    @EnvironmentObject var theme:      ThemeManager
    @EnvironmentObject var appUpdate:  AppUpdateService
    @AppStorage("settingsPane") private var paneRaw: String = SettingsPane.general.rawValue

    private var pane: Binding<SettingsPane?> {
        Binding(
            get: { SettingsPane(rawValue: paneRaw) ?? .general },
            set: { if let p = $0 { paneRaw = p.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: pane) { p in
                NavigationLink(value: p) {
                    SettingsSidebarLabel(pane: p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detail(for: SettingsPane(rawValue: paneRaw) ?? .general)
                .navigationTitle((SettingsPane(rawValue: paneRaw) ?? .general).title)
        }
        .modifier(HideSidebarToggle())
        .frame(minWidth: 720, idealWidth: 800, minHeight: 500, idealHeight: 620)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:     GeneralSettings()
        case .appearance:  AppearanceSettings()
        case .downloads:   DownloadSettings()
        case .files:       OutputSettings()
        case .automation:  AutomationSettings()
        case .network:     NetworkSettings()
        case .performance: PerformanceSettings()
        case .advanced:    AdvancedSettings()
        case .about:       AboutSettings()
        }
    }
}

private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

struct SettingsSidebarLabel: View {
    let pane: SettingsPane
    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(symbol: pane.symbol, tint: pane.tint)
        }
    }
}

/// The white-glyph-on-colour rounded square used by System Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}

/// Title + secondary description, used as the label of form rows.
struct RowLabel: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject var settings:  SettingsManager
    @EnvironmentObject var appUpdate: AppUpdateService

    var body: some View {
        Form {
            Section("App") {
                Toggle(isOn: $settings.showInDock) {
                    RowLabel(title: "Show Yoink in the Dock",
                             detail: "When off, Yoink lives only in the menu bar once its window is closed.")
                }
                .onChange(of: settings.showInDock) { show in
                    // Re-show in the Dock right away; hiding happens when the window closes
                    if show { NSApp.setActivationPolicy(.regular) }
                }
                Toggle(isOn: $settings.hapticsEnabled) {
                    RowLabel(title: "Trackpad haptics",
                             detail: "A light tap when downloads start and finish.")
                }
            }

            Section("Updates") {
                Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                    RowLabel(title: "Keep Yoink up to date automatically",
                             detail: "Checks once a day for new versions of Yoink and quietly updates yt-dlp, so downloads keep working when sites change.")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        if appUpdate.status == .checking {
                            ProgressView().controlSize(.small)
                        }
                        if case .available = appUpdate.status {
                            Button("Download Update") { appUpdate.openDownloadPage() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check Now") { appUpdate.checkForUpdates() }
                                .disabled(appUpdate.status == .checking)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(appUpdate.dotColor).frame(width: 7, height: 7)
                        RowLabel(title: "Yoink \(appVersion)", detail: appUpdate.statusLabel)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var theme:    ThemeManager

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ForEach(AppTheme.allCases) { t in
                        ThemeCell(appTheme: t, selected: theme.current == t) {
                            withAnimation(.spring(response: 0.25)) { theme.set(t) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $settings.useBlurBackground) {
                    RowLabel(title: "Translucent window",
                             detail: "Let your desktop softly show through the Yoink window. Turn off for a solid background.")
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("The accent colour follows System Settings → Appearance.")
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar Icon") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(MenuBarIcon.presets.filter { $0.kind == .sfSymbol }) { icon in
                        IconCell(icon: icon, selected: settings.menuBarIconId == icon.id) {
                            settings.menuBarIconId = icon.id
                            Haptics.tap()
                        }
                    }
                }
                .padding(.vertical, 4)

                let dyn = MenuBarIcon.presets.first { $0.kind == .dynamic }!
                Toggle(isOn: Binding(
                    get: { settings.menuBarIconId == dyn.id },
                    set: { on in settings.menuBarIconId = on ? dyn.id : MenuBarIcon.presets[0].id }
                )) {
                    RowLabel(title: "Show download percentage",
                             detail: "The icon becomes a live 0–100 counter with a progress ring while downloading.")
                }

                CustomTextMenuBarRow()
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemeCell: View {
    let appTheme: AppTheme
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    private var previewDark: Bool {
        switch appTheme {
        case .dark:   return true
        case .light:  return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topLeading) {
                    if appTheme == .system {
                        HStack(spacing: 0) {
                            Color(white: 0.96)
                            Color(white: 0.16)
                        }
                    } else {
                        (previewDark ? Color(white: 0.16) : Color(white: 0.96))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            ForEach([Color.red, .yellow, .green], id: \.self) { c in
                                Circle().fill(c.opacity(0.85)).frame(width: 5, height: 5)
                            }
                        }
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 34, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.45)).frame(width: 46, height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.3)).frame(width: 28, height: 4)
                    }
                    .padding(8)
                }
                .frame(width: 88, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: selected ? 2.5 : 0.5)
                )
                .shadow(color: .black.opacity(hovered ? 0.12 : 0.05), radius: hovered ? 5 : 2, y: 1)

                Text(appTheme.rawValue)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel("\(appTheme.rawValue) appearance")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct IconCell: View {
    let icon:     MenuBarIcon
    let selected: Bool
    let action:   () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if icon.kind == .emoji {
                        Text(icon.value).font(.system(size: 18))
                    } else {
                        Image(systemName: icon.value).font(.system(size: 16, weight: .medium))
                    }
                }
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.14)
                                       : Color.primary.opacity(hovered ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5)
                )
                Text(icon.label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(icon.label)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }
}

struct CustomTextMenuBarRow: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var customText = ""
    private var isActive: Bool { settings.menuBarIconId.hasPrefix("text_") }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: $customText, prompt: Text("YK"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(width: 64)
                    .onChange(of: customText) { v in
                        if v.count > 4 { customText = String(v.prefix(4)) }
                    }
                    .onSubmit(apply)
                Button(isActive && customText == String(settings.menuBarIconId.dropFirst(5)) ? "In Use" : "Use") {
                    apply()
                }
                .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } label: {
            RowLabel(title: "Custom text or emoji", detail: "Up to 4 characters, e.g. your initials or 🎬.")
        }
        .onAppear {
            if isActive { customText = String(settings.menuBarIconId.dropFirst(5)) }
        }
    }

    private func apply() {
        let t = customText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        settings.menuBarIconId = "text_\(t)"
        Haptics.tap()
    }
}

// MARK: - Downloads

struct DownloadSettings: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Defaults for New Downloads") {
                Picker(selection: $settings.defaultFormatRaw) {
                    ForEach(DownloadFormat.allCases) { f in
                        Text(f.displayName).tag(f.rawValue)
                    }
                } label: {
                    RowLabel(title: "Format", detail: "You can still change it for each download.")
                }
                Picker("Download at the same time", selection: $settings.concurrentLimitRaw) {
                    ForEach(ConcurrentLimit.allCases) { l in Text(l.label).tag(l.rawValue) }
                }
                Picker("When a download finishes", selection: $settings.postDownloadRaw) {
                    ForEach(PostDownloadAction.allCases) { a in Text(a.label).tag(a.rawValue) }
                }
                Toggle(isOn: $settings.notifyOnQueueComplete) {
                    RowLabel(title: "Notify once when everything is done",
                             detail: "One notification when the whole queue finishes, instead of one per file.")
                }
            }

            Section("Subtitles") {
                Toggle("Download subtitles by default", isOn: $settings.autoDownloadSubs)
                LabeledContent {
                    TextField("", text: $settings.defaultSubLang, prompt: Text("en"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                } label: {
                    RowLabel(title: "Preferred language",
                             detail: "Language code such as en, es or ja. Used whenever the video has it.")
                }
            }

            Section {
                Toggle(isOn: $settings.sponsorBlock) {
                    RowLabel(title: "Skip sponsor segments",
                             detail: "Cuts sponsors, self-promotion and \"like & subscribe\" reminders using SponsorBlock.")
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Subtitles are re-timed automatically so they stay in sync after cuts.")
                    .foregroundStyle(.secondary)
            }

            SiteFormatOverridesSection()
        }
        .formStyle(.grouped)
    }
}

/// Per-site default formats — e.g. always grab audio from SoundCloud.
struct SiteFormatOverridesSection: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var customDomain = ""
    @State private var addingCustom = false

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

    var body: some View {
        let overrides = settings.siteFormatOverrides
        Section {
            if overrides.isEmpty {
                Text("No site rules yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(overrides.keys.sorted(), id: \.self) { domain in
                HStack(spacing: 8) {
                    Picker(displayLabel(for: domain), selection: Binding(
                        get: { overrides[domain] ?? DownloadFormat.best.rawValue },
                        set: { newVal in
                            var dict = settings.siteFormatOverrides
                            dict[domain] = newVal
                            settings.siteFormatOverrides = dict
                        }
                    )) {
                        ForEach(DownloadFormat.allCases) { f in Text(f.displayName).tag(f.rawValue) }
                    }
                    Button {
                        var dict = settings.siteFormatOverrides
                        dict.removeValue(forKey: domain)
                        settings.siteFormatOverrides = dict
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the rule for \(domain)")
                }
            }

            if addingCustom {
                HStack(spacing: 8) {
                    TextField("", text: $customDomain, prompt: Text("e.g. bilibili.com"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                        .onSubmit(commitCustomDomain)
                    Button("Add", action: commitCustomDomain)
                        .disabled(customDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { addingCustom = false; customDomain = "" }
                }
            } else {
                Menu("Add Site") {
                    ForEach(suggestedSites.filter { overrides[$0.domain] == nil }, id: \.domain) { site in
                        Button(site.label) { add(site.domain) }
                    }
                    Divider()
                    Button("Other Site…") { addingCustom = true }
                }
                .fixedSize()
            }
        } header: {
            Text("Per-Site Formats")
        } footer: {
            Text("Used instead of the default format for these sites, unless you pick a format yourself.")
                .foregroundStyle(.secondary)
        }
    }

    private func displayLabel(for domain: String) -> String {
        suggestedSites.first { $0.domain == domain }?.label ?? domain
    }

    private func add(_ domain: String) {
        var dict = settings.siteFormatOverrides
        dict[domain] = settings.defaultFormatRaw
        settings.siteFormatOverrides = dict
    }

    private func commitCustomDomain() {
        let d = customDomain
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/").first ?? ""
        guard !d.isEmpty else { addingCustom = false; return }
        add(d)
        customDomain = ""
        addingCustom = false
    }
}

// MARK: - Files & Folders

struct OutputSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var queue: DownloadQueue

    var body: some View {
        Form {
            Section("Download Folder") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Show in Finder") {
                            queue.ensureOutputDir()
                            NSWorkspace.shared.open(queue.outputDirectory)
                        }
                        Button("Change…") { pickFolder() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: queue.outputDirectory.path))
                            .resizable().frame(width: 20, height: 20)
                        RowLabel(title: queue.outputDirectory.lastPathComponent,
                                 detail: (queue.outputDirectory.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
                Toggle(isOn: $settings.autoOrganizeBySite) {
                    RowLabel(title: "Sort into site folders",
                             detail: "Saves into subfolders such as YouTube/ and Twitch/.")
                }
            }

            OutputCategoriesSection()

            Section("File Names") {
                TextField(text: $settings.outputTemplate, prompt: Text("%(title)s.%(ext)s")) {
                    Text("Template")
                }
                .font(.system(.body, design: .monospaced))
                TemplateTokens(template: $settings.outputTemplate)
            }

            Section("After Downloading") {
                Toggle("Embed thumbnail as cover art", isOn: $settings.embedThumbnail)
                Toggle("Write title, artist and chapter tags", isOn: $settings.addMetadata)
                Picker(selection: $settings.postConvertRaw) {
                    ForEach(PostConvertAction.allCases) { a in Text(a.label).tag(a.rawValue) }
                } label: {
                    RowLabel(title: "Convert", detail: "Runs with the bundled ffmpeg after every download.")
                }
                Toggle(isOn: $settings.avoidOverwrite) {
                    RowLabel(title: "Never overwrite existing files",
                             detail: "Skips a download when a file with the same name already exists.")
                }
                Toggle(isOn: $settings.keepPartialFiles) {
                    RowLabel(title: "Keep partial downloads",
                             detail: "Leaves unfinished pieces on disk so an interrupted download can resume.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = queue.outputDirectory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            queue.outputDirectory = url
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
    }
}

/// Named folders ("🎵 Music", "🎓 Educational") you can switch to from the save-location menu.
struct OutputCategoriesSection: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var categories: [OutputCategory] = []

    var body: some View {
        Section {
            ForEach($categories) { $category in
                OutputCategoryRow(
                    category: $category,
                    onPickFolder: { pickFolder(for: category.id) },
                    onDelete: {
                        categories.removeAll { $0.id == category.id }
                        save()
                    },
                    onCommit: save
                )
            }
            Button {
                categories.append(OutputCategory(name: "New Category", emoji: "📁", path: ""))
                save()
                Haptics.tap()
            } label: {
                Label("Add Category", systemImage: "plus")
            }
        } header: {
            Text("Save Categories")
        } footer: {
            Text("Categories with a folder appear in the save-location menu in the main window and menu bar.")
                .foregroundStyle(.secondary)
        }
        .onAppear { categories = settings.outputCategories }
    }

    private func save() { settings.outputCategories = categories }

    // NSOpenPanel directly — .fileImporter can crash when attached to the Settings window.
    private func pickFolder(for id: UUID) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose folder for \(categories[index].name)"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let i = categories.firstIndex(where: { $0.id == id }) else { return }
            _ = url.startAccessingSecurityScopedResource()
            categories[i].path = url.path
            save()
        }
    }
}

struct OutputCategoryRow: View {
    @Binding var category: OutputCategory
    let onPickFolder: () -> Void
    let onDelete: () -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $category.emoji)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 42)
                .onChange(of: category.emoji) { v in
                    guard !v.isEmpty else { return }
                    var idx = v.startIndex; v.formIndex(after: &idx)
                    let first = String(v[v.startIndex..<idx])
                    if category.emoji != first { category.emoji = first }
                    onCommit()
                }
            TextField("", text: $category.name, prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 140)
                .onChange(of: category.name) { _ in onCommit() }
            Button(action: onPickFolder) {
                Label(category.path.isEmpty ? "Choose Folder…" : URL(fileURLWithPath: category.path).lastPathComponent,
                      systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .help(category.path.isEmpty ? "Choose a folder" : category.path)
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove category")
        }
        .labelsHidden()
    }
}

struct TemplateTokens: View {
    @Binding var template: String

    private let tokens: [(token: String, label: String)] = [
        ("%(title)s", "Title"), ("%(uploader)s", "Channel"), ("%(upload_date)s", "Upload Date"),
        ("%(id)s", "Video ID"), ("%(resolution)s", "Resolution"), ("%(duration_string)s", "Duration"),
        ("%(playlist_index)s", "Playlist #"), ("%(ext)s", "Extension"),
    ]

    private let presets: [(label: String, value: String)] = [
        ("Title", "%(title)s.%(ext)s"),
        ("Date – Title", "%(upload_date)s - %(title)s.%(ext)s"),
        ("Channel/Date – Title", "%(uploader)s/%(upload_date)s - %(title)s.%(ext)s"),
        ("ID – Title", "%(id)s - %(title)s.%(ext)s"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(preview)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Menu("Presets") {
                    ForEach(presets, id: \.label) { p in
                        Button(p.label) { template = p.value }
                    }
                }
                .fixedSize()
            }
            FlowLayout(spacing: 6) {
                ForEach(tokens, id: \.token) { t in
                    Button {
                        insert(t.token)
                    } label: {
                        Label(t.label, systemImage: "plus")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Insert \(t.token)")
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Adds a token before the extension so the name stays valid.
    private func insert(_ token: String) {
        if token == "%(ext)s" || !template.hasSuffix(".%(ext)s") {
            template += token
        } else {
            template = String(template.dropLast(".%(ext)s".count)) + " " + token + ".%(ext)s"
        }
        Haptics.tap()
    }

    private var preview: String {
        (template.isEmpty ? "%(title)s.%(ext)s" : template)
            .replacingOccurrences(of: "%(title)s",           with: "My Video")
            .replacingOccurrences(of: "%(id)s",              with: "dQw4w9WgXcQ")
            .replacingOccurrences(of: "%(ext)s",             with: "mp4")
            .replacingOccurrences(of: "%(uploader)s",        with: "Channel")
            .replacingOccurrences(of: "%(upload_date)s",     with: "20260930")
            .replacingOccurrences(of: "%(resolution)s",      with: "1920x1080")
            .replacingOccurrences(of: "%(duration_string)s", with: "3:33")
            .replacingOccurrences(of: "%(playlist_index)s",  with: "03")
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

// MARK: - Clipboard & Automation

struct AutomationSettings: View {
    @EnvironmentObject var settings: SettingsManager
    @ObservedObject private var clipboard = ClipboardMonitor.shared
    @StateObject private var scheduled = ScheduledDownloadStore.shared
    @State private var newDomain = ""
    @State private var confirmResetDomains = false

    private var domains: [String] { settings.clipboardDomains }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.clipboardMonitor },
                    set: { on in
                        settings.clipboardMonitor = on
                        if on { clipboard.start() } else { clipboard.stop() }
                    }
                )) {
                    RowLabel(title: "Offer links I copy",
                             detail: "Copy a video link anywhere on your Mac and Yoink offers to download it.")
                }
                if let label = clipboard.snoozeLabel {
                    LabeledContent {
                        Button("Resume Now") { clipboard.clearSnooze() }
                    } label: {
                        Label(label, systemImage: "bell.slash.fill")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Clipboard")
            }

            Section("When I Choose \"Download Now\" from a Notification") {
                Toggle("Skip sponsor segments", isOn: $settings.notifSponsorBlock)
                Toggle("Download subtitles", isOn: $settings.notifSubtitles)
            }

            Section("Watch Later Downloads") {
                Toggle("Skip sponsor segments", isOn: $settings.watchLaterSponsorBlock)
                Toggle("Download subtitles", isOn: $settings.watchLaterSubtitles)
            }

            Section {
                FlowLayout(spacing: 6) {
                    ForEach(domains, id: \.self) { domain in
                        HStack(spacing: 5) {
                            Text(domain)
                                .font(.system(size: 12, design: .monospaced))
                            if domains.count > 1 {
                                Button {
                                    var d = settings.clipboardDomains
                                    d.removeAll { $0 == domain }
                                    settings.clipboardDomains = d
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Stop watching \(domain)")
                            }
                        }
                        .padding(.leading, 9).padding(.trailing, domains.count > 1 ? 7 : 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .padding(.vertical, 2)
                HStack(spacing: 8) {
                    TextField("", text: $newDomain, prompt: Text("Add a site, e.g. peertube.social"))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .labelsHidden()
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                HStack {
                    Text("Sites to Watch")
                    Spacer()
                    Button("Reset to Defaults") { confirmResetDomains = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            .confirmationDialog("Reset the list of watched sites?", isPresented: $confirmResetDomains) {
                Button("Reset", role: .destructive) { settings.clipboardDomainsRaw = "" }
                Button("Cancel", role: .cancel) {}
            }

            Section {
                LabeledContent {
                    Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
                } label: {
                    RowLabel(title: "Run a Shortcut after each download",
                             detail: "The finished file is passed to the Shortcut as input.")
                }
                TextField(text: $settings.shortcutOnComplete, prompt: Text("Shortcut name — leave empty to turn off")) {
                    Text("Shortcut")
                }
            } header: {
                Text("Apple Shortcuts")
            }

            if !scheduled.items.isEmpty {
                Section("Scheduled Downloads") {
                    ForEach(scheduled.items) { item in
                        ScheduledItemRow(item: item)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        let trimmed = newDomain
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: "/").first ?? ""
        guard !trimmed.isEmpty, !domains.contains(trimmed) else { newDomain = ""; return }
        var d = settings.clipboardDomains
        d.append(trimmed)
        settings.clipboardDomains = d
        newDomain = ""
    }
}

struct ScheduledItemRow: View {
    let item: ScheduledDownload
    @StateObject private var clock = RowClock()

    private var secondsUntil: Int { max(0, Int(item.scheduledAt.timeIntervalSince(clock.now))) }

    private var countdownText: String {
        let s = secondsUntil
        guard s > 0 else { return item.fired ? "Started" : "Starting…" }
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        if h > 0 { return "in \(h)h \(m)m" }
        if m > 0 { return "in \(m)m \(sec)s" }
        return "in \(sec)s"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.fired ? "checkmark.circle.fill" : "clock.fill")
                .foregroundStyle(item.fired ? .green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).lineLimit(1)
                Text(item.scheduledAt.formatted(date: .abbreviated, time: .shortened) + (item.fired ? "" : " · " + countdownText))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { ScheduledDownloadStore.shared.remove(item) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel this scheduled download")
        }
    }
}

// MARK: - Network

struct NetworkSettings: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Speed") {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.rateLimitKbps, format: .number, prompt: Text("Unlimited"))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                } label: {
                    RowLabel(title: "Limit download speed",
                             detail: settings.rateLimitKbps > 0
                                ? "About \(String(format: "%.1f", Double(settings.rateLimitKbps) / 1024)) MB/s per download."
                                : "0 means no limit.")
                }
                Stepper(value: $settings.retryCount, in: 0...10) {
                    RowLabel(title: "Retry failed connections",
                             detail: settings.retryCount == 0 ? "Don't retry." : "Up to \(settings.retryCount) \(settings.retryCount == 1 ? "time" : "times").")
                }
            }

            Section {
                Toggle("Use a proxy", isOn: $settings.useProxy)
                if settings.useProxy {
                    TextField(text: $settings.proxyURL, prompt: Text("http://127.0.0.1:8080 or socks5://…")) {
                        Text("Proxy address")
                    }
                    .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Proxy")
            } footer: {
                Text("Routes every download through this proxy. Supports http, https and socks5.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Performance

struct PerformanceSettings: View {
    @EnvironmentObject var settings: SettingsManager

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.processPriorityRaw) {
                    ForEach(ProcessQoS.allCases) { qos in Text(qos.label).tag(qos.rawValue) }
                } label: {
                    RowLabel(title: "Priority", detail: "Lower priority keeps your Mac cool and quiet.")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(settings.ffmpegThreads) },
                            set: { settings.ffmpegThreads = Int($0) }
                        ), in: 0...16, step: 1)
                        .frame(width: 170)
                        Text(settings.ffmpegThreads == 0 ? "Auto" : "\(settings.ffmpegThreads)")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                } label: {
                    RowLabel(title: "Processing threads", detail: threadHint)
                }
            } header: {
                Text("CPU")
            } footer: {
                Text("Downloading is limited by your connection. Priority and threads matter when Yoink merges video and audio, cuts clips or removes sponsors.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var threadHint: String {
        switch settings.ffmpegThreads {
        case 0:     return "All cores — fastest, warmest."
        case 1...2: return "Very cool, a little slower."
        case 3...4: return "Balanced — recommended."
        case 5...8: return "Fast, a bit warmer."
        default:    return "Fastest, runs warm."
        }
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var settings:  SettingsManager
    @EnvironmentObject var deps:      DependencyService
    @State private var confirmReset = false
    @State private var showYtdlp = false
    @State private var showFfmpeg = false

    var body: some View {
        Form {
            Section("Download Engines") {
                engineRow(name: "yt-dlp", detail: "Finds and downloads videos from 1000+ sites",
                          status: deps.ytdlp, update: { deps.forceUpdateYtdlp() }, details: { showYtdlp = true })
                engineRow(name: "ffmpeg", detail: "Merges, cuts and converts media",
                          status: deps.ffmpeg, update: { deps.forceUpdateFfmpeg() }, details: { showFfmpeg = true })
            }

            Section {
                TextField(text: $settings.ytdlpExtraArgs, prompt: Text("e.g. --no-mtime --geo-bypass")) {
                    Text("Extra arguments")
                }
                .font(.system(.body, design: .monospaced))
            } header: {
                Text("yt-dlp")
            } footer: {
                Text("Added to every download. For options Yoink doesn't have a setting for — use with care.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                } label: {
                    RowLabel(title: "Reset all settings",
                             detail: "Restores every preference to its default. Your downloaded files, history and Watch Later list aren't touched.")
                }
            }
            .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset Settings", role: .destructive) { resetSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Downloaded files, history and Watch Later stay as they are.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showYtdlp) { DepSheet(tool: "yt-dlp").environmentObject(deps) }
        .sheet(isPresented: $showFfmpeg) { DepSheet(tool: "ffmpeg").environmentObject(deps) }
    }

    private func engineRow(name: String, detail: String, status: DepStatus,
                           update: @escaping () -> Void, details: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if case .updating = status {
                    ProgressView().controlSize(.small)
                    Text("Updating…").foregroundStyle(.secondary)
                } else {
                    Button("Update") { update() }
                        .disabled(!status.isReady)
                }
                Button("Details…", action: details)
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(status.dotColor).frame(width: 7, height: 7)
                RowLabel(title: "\(name)  \(status.version ?? "")", detail: status.isReady ? detail : status.statusLabel)
            }
        }
    }

    /// Clears preferences but keeps user data (history, Watch Later, schedule, folder).
    private func resetSettings() {
        let keep: Set<String> = [
            "downloadHistory_v1", "watchLater_v1", "scheduledDownloads_v1",
            "outputDirectoryBookmark_v2", "outputDirectoryPath_v1",
            "pendingDownloadURLs_v1", "hasSeenTutorial",
        ]
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier,
              let all = defaults.persistentDomain(forName: domain) else { return }
        for key in all.keys where !keep.contains(key) {
            defaults.removeObject(forKey: key)
        }
        SettingsManager.shared.objectWillChange.send()
        Haptics.success()
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject var deps:      DependencyService
    @EnvironmentObject var appUpdate: AppUpdateService
    @State private var showTutorial = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 88, height: 88)
                    Text("Yoink")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .foregroundStyle(.secondary)
                    Text("Download video and audio from 1000+ sites — right from your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        if case .available = appUpdate.status {
                            Button("Download Update") { appUpdate.openDownloadPage() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(appUpdate.status == .checking ? "Checking…" : "Check for Updates") {
                                appUpdate.checkForUpdates()
                            }
                            .disabled(appUpdate.status == .checking)
                        }
                        Button("Show Tutorial") { showTutorial = true }
                    }
                    .padding(.top, 4)
                    Text(appUpdate.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section("Powered By") {
                LabeledContent("yt-dlp", value: deps.ytdlp.statusLabel)
                LabeledContent("ffmpeg", value: deps.ffmpeg.statusLabel)
                LabeledContent("SponsorBlock", value: "sponsor.ajay.app")
            }

            Section {
                Link(destination: URL(string: "https://github.com/0x1p0/yoink")!) {
                    Label("Yoink on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/0x1p0/yoink/issues")!) {
                    Label("Report a Problem", systemImage: "exclamationmark.bubble")
                }
                Link(destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!) {
                    Label("yt-dlp on GitHub", systemImage: "arrow.down.circle")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showTutorial) {
            TutorialView { showTutorial = false }
        }
    }
}
