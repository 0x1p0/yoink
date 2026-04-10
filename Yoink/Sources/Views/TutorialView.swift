import SwiftUI

// MARK: - Tutorial Step Model

private struct TutorialStep: Identifiable {
    let id        : Int
    let icon      : String
    let iconColor : Color
    let title     : String
    let subtitle  : String
    let bullets   : [(icon: String, color: Color, text: String)]
}

private let tutorialSteps: [TutorialStep] = [
    TutorialStep(
        id: 0,
        icon: "arrow.down.circle.fill",
        iconColor: .accentColor,
        title: "Welcome to Yoink",
        subtitle: "Download videos and audio from YouTube, Twitch, Instagram, TikTok, and 1000+ other sites - fast, clean, and right on your Mac.",
        bullets: [
            ("checkmark.circle.fill", .green,   "No account or login needed"),
            ("lock.fill",             .blue,    "Everything stays on your Mac"),
            ("bolt.fill",             .orange,  "Powered by yt-dlp & ffmpeg"),
        ]
    ),
    TutorialStep(
        id: 1,
        icon: "film.fill",
        iconColor: .purple,
        title: "Downloading a Video",
        subtitle: "The main Video tab is your everyday download queue. Paste a link, choose your quality, and hit Download.",
        bullets: [
            ("link",                  .accentColor, "Paste any video URL into a card"),
            ("slider.horizontal.3",   .purple,      "Pick format: 1080p, 720p, audio-only, and more"),
            ("arrow.down.circle",     .green,       "Hit Download - or press ⌘D to start all"),
        ]
    ),
    TutorialStep(
        id: 2,
        icon: "list.number",
        iconColor: .orange,
        title: "Playlists & Advanced Mode",
        subtitle: "Switch to Playlist mode to fetch an entire playlist or channel, cherry-pick videos, and download them in one go.",
        bullets: [
            ("arrow.right.circle",    .orange,  "Paste a playlist or channel URL and tap Load"),
            ("checkmark.circle",      .green,   "Check or uncheck individual videos"),
            ("scissors",              .red,     "Optionally clip a time range per video"),
        ]
    ),
    TutorialStep(
        id: 3,
        icon: "bookmark.fill",
        iconColor: .blue,
        title: "Watch Later",
        subtitle: "Not ready to download yet? Save any video or playlist to Watch Later and come back whenever.",
        bullets: [
            ("alarm",                 .accentColor, "Schedule a download for a specific time"),
            ("scissors",              .orange,      "Toggle SponsorBlock to auto-remove sponsors"),
            ("captions.bubble",       .blue,        "Toggle Subtitles to grab them automatically"),
        ]
    ),
    TutorialStep(
        id: 4,
        icon: "menubar.rectangle",
        iconColor: .secondary,
        title: "Menu Bar Access",
        subtitle: "Yoink lives in your menu bar so you can start downloads without switching apps.",
        bullets: [
            ("doc.on.clipboard",      .accentColor, "Click the icon and paste a URL instantly"),
            ("eye",                   .green,       "See live download progress in the icon"),
            ("gearshape",             .secondary,   "Right-click to access settings quickly"),
        ]
    ),
    TutorialStep(
        id: 5,
        icon: "bell.badge.fill",
        iconColor: .red,
        title: "Clipboard Monitor",
        subtitle: "Copy a video link anywhere on your Mac and Yoink will spot it and offer to download - without you doing anything.",
        bullets: [
            ("link.badge.plus",       .accentColor, "A banner appears when a supported link is copied"),
            ("arrow.down.circle",     .green,       "Tap Download Now, Watch Later, or dismiss"),
            ("bell.slash",            .orange,      "Snooze the monitor for 5 min, 30 min, or longer"),
        ]
    ),
    TutorialStep(
        id: 6,
        icon: "clock.arrow.circlepath",
        iconColor: .green,
        title: "History",
        subtitle: "Every completed download is saved to History so you can find files, re-download, or spot duplicates.",
        bullets: [
            ("doc.viewfinder",        .accentColor, "Reveal any file in Finder with one click"),
            ("arrow.clockwise",       .orange,      "Re-queue a past download instantly"),
            ("exclamationmark.circle",.yellow,      "Yoink warns you before downloading a duplicate"),
        ]
    ),
    TutorialStep(
        id: 7,
        icon: "gearshape.2.fill",
        iconColor: .gray,
        title: "Settings & Customisation",
        subtitle: "Yoink is built to fit your workflow - tweak formats, output folders, themes, and more.",
        bullets: [
            ("folder",                .blue,        "Set a custom download folder per session or globally"),
            ("paintpalette",          .purple,      "Switch themes: light, dark, or system"),
            ("cpu",                   .orange,      "Control concurrency, speed limits, and process priority"),
        ]
    ),
]

// MARK: - Tutorial View

struct TutorialView: View {
    var onDismiss: () -> Void = {}

    @State private var currentStep = 0
    @State private var dragOffset : CGFloat = 0
    @State private var direction  : Int     = 1   // +1 forward, -1 back

    private var step: TutorialStep { tutorialSteps[currentStep] }
    private var isLast:  Bool { currentStep == tutorialSteps.count - 1 }
    private var isFirst: Bool { currentStep == 0 }

    var body: some View {
        VStack(spacing: 0) {

            // ── Progress dots ─────────────────────────────────────────
            HStack(spacing: 6) {
                ForEach(tutorialSteps) { s in
                    Capsule()
                        .fill(s.id == currentStep ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: s.id == currentStep ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: currentStep)
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)

            // ── Slide content ─────────────────────────────────────────
            ZStack {
                ForEach(tutorialSteps) { s in
                    if s.id == currentStep {
                        StepCard(step: s)
                            .transition(
                                .asymmetric(
                                    insertion:  .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                                    removal:    .move(edge: direction > 0 ? .leading  : .trailing).combined(with: .opacity)
                                )
                            )
                    }
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: currentStep)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { val in
                        if val.translation.width < -30 { advance() }
                        else if val.translation.width > 30 { back() }
                    }
            )

            // ── Navigation ─────────────────────────────────────────────
            HStack(spacing: 12) {
                // Back
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFirst ? Color.primary.opacity(0.2) : Color.primary.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(isFirst ? 0.03 : 0.07))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isFirst)

                Spacer()

                // Skip / done
                if !isLast {
                    Button("Skip") {
                        finish()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                // Next / Get Started
                Button {
                    if isLast { finish() } else { advance() }
                } label: {
                    HStack(spacing: 6) {
                        Text(isLast ? "Get Started" : "Next")
                            .font(.system(size: 13, weight: .semibold))
                        if !isLast {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28).padding(.bottom, 24)
        }
        .frame(width: 480, height: 420)
        .background(.background)
    }

    private func advance() {
        guard !isLast else { return }
        direction = 1
        withAnimation { currentStep += 1 }
        Haptics.tap()
    }

    private func back() {
        guard !isFirst else { return }
        direction = -1
        withAnimation { currentStep -= 1 }
        Haptics.tap()
    }

    private func finish() {
        SettingsManager.shared.hasSeenTutorial = true
        onDismiss()
        Haptics.success()
    }
}

// MARK: - Step Card

private struct StepCard: View {
    let step: TutorialStep

    var body: some View {
        VStack(spacing: 0) {
            // Icon
            ZStack {
                Circle()
                    .fill(step.iconColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: step.icon)
                    .font(.system(size: 34))
                    .foregroundStyle(step.iconColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding(.top, 28).padding(.bottom, 16)

            // Title
            Text(step.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            // Subtitle
            Text(step.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.top, 8)

            Spacer(minLength: 12)

            // Bullet points
            VStack(alignment: .leading, spacing: 10) {
                ForEach(step.bullets.indices, id: \.self) { i in
                    let b = step.bullets[i]
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: b.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(b.color)
                            .frame(width: 18)
                        Text(b.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.bottom, 24)
        }
    }
}
