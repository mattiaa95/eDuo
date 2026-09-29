//
//  WelcomeView.swift
//  eDuo
//
//  Ported and adapted from iGBA's WelcomeView.swift: same
//  first-launch onboarding shape — a 4-page `TabView` with a custom capsule
//  page indicator, a top-right Skip button (hidden on the last page), and a
//  bottom action that morphs from "Continue" into a primary/secondary button
//  pair on the last page. Adaptations vs. iGBA:
//   - Content is eDuo's own (DS-specific): hero welcome, adding games,
//     what the emulator supports, and controls — instead of iGBA's
//     hero/features/Watch-beta/get-started set.
//   - Hero icon is "SplashIcon" (same imageset the splash screen uses) and
//     the glow is eDuo's crimson brand color instead of iGBA's purple.
//   - `featureCard` takes an explicit `page` index (iGBA only ever used it
//     from one page, so didn't need to parameterize which page's
//     `animatedPages` membership drives its reveal animation).
//   - Haptics go through `INDSHaptics` (Common/Controller) so onboarding
//     respects the same "eNDSHapticsEnabled" toggle as the rest of the app,
//     instead of firing `UIImpactFeedbackGenerator` unconditionally.
//   - Plain string literals (no `NSLocalizedString` wrapping), matching
//     every other View in eDuo (ROMListView, SettingsView, etc.); the
//     string catalog picks these up as keys.
//
//  Gate: first-launch presentation is driven by `INDSWelcomeGate` below
//  ("eNDSHasSeenWelcome" in UserDefaults), read/written from `ROMListView`
//  after the splash screen completes. Reopening later (Settings > About >
//  "Welcome Guide") does not touch the gate — it just re-presents this view.
//

import SwiftUI

/// Persisted "has the user seen onboarding" flag, mirroring the shape of
/// this codebase's other small UserDefaults-backed namespaces
/// (`INDSHaptics`, `INDSSavingPreferences`, `DSScreenLayoutPreferences`).
enum INDSWelcomeGate {
    private static let hasSeenWelcomeKey = "eNDSHasSeenWelcome"

    static var hasSeenWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: hasSeenWelcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasSeenWelcomeKey) }
    }
}

extension Notification.Name {
    /// Posted by the "Welcome Guide" row (Settings > About) to reopen
    /// `WelcomeView` on demand, outside the normal first-launch gate.
    static let welcomeGuideRequested = Notification.Name("eNDSWelcomeGuideRequested")
}

struct WelcomeView: View {

    @Environment(\.dismiss) private var dismiss
    var onGetStarted: () -> Void

    @State private var currentPage = 0
    @State private var animatedPages: Set<Int> = []
    /// Continuous "breathing" pulse for page 1's hero glow — independent of
    /// `animatedPages`'s one-time reveal (a separate `scaleEffect`, so the
    /// two compose instead of fighting over the same property). `nil`/static
    /// under Reduce Motion, per `INDSMotion.pulse`.
    @State private var heroGlowPulse = false

    private let totalPages = 4

    // Fixed point sizes that still follow Dynamic Type. Each value is the
    // default-size look, so nothing changes at the standard setting.
    @ScaledMetric(relativeTo: .largeTitle) private var welcomeTitleSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var pageTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var cardBadgeSize: CGFloat = 9
    @ScaledMetric(relativeTo: .subheadline) private var formatBadgeSize: CGFloat = 14

    var body: some View {
        ZStack {
            // Dark gaming background (matching the splash screen)
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            // Ambient crimson glow at the top
            RadialGradient(
                colors: [Color.indsCrimsonLight.opacity(0.14), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 500
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar — Skip button
                HStack {
                    Spacer()
                    if currentPage < totalPages - 1 {
                        Button {
                            withMotion(.easeInOut(duration: 0.3)) {
                                currentPage = totalPages - 1
                            }
                            INDSHaptics.light()
                        } label: {
                            Text("Skip")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white.opacity(0.45))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .transition(.opacity)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
                .motionAnimation(.easeInOut(duration: 0.3), value: currentPage)
                .padding(.top, 8)

                // Paged content
                TabView(selection: $currentPage) {
                    welcomeHeroPage.tag(0)
                    addYourGamesPage.tag(1)
                    madeForDSPage.tag(2)
                    controlsPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Bottom section
                VStack(spacing: 16) {
                    // Custom page indicator
                    HStack(spacing: 8) {
                        ForEach(0..<totalPages, id: \.self) { i in
                            Capsule()
                                .fill(i == currentPage ? INDSAppearanceStore.shared.accentColor : Color.white.opacity(0.2))
                                .frame(width: i == currentPage ? 24 : 8, height: 8)
                                .motionAnimation(.easeInOut(duration: 0.25), value: currentPage)
                        }
                    }
                    .padding(.bottom, 4)

                    // Action buttons — animated transition between Continue and Get Started
                    Group {
                        if currentPage < totalPages - 1 {
                            Button {
                                withMotion(.easeInOut(duration: 0.3)) {
                                    currentPage += 1
                                }
                                INDSHaptics.medium()
                            } label: {
                                Text("Continue")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(INDSAppearanceStore.shared.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        } else {
                            VStack(spacing: 14) {
                                Button {
                                    INDSHaptics.medium()
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        onGetStarted()
                                    }
                                } label: {
                                    Label("Get Started", systemImage: "plus.circle.fill")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                        .background(INDSAppearanceStore.shared.accentColor)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }

                                Button {
                                    dismiss()
                                } label: {
                                    Text("I'll explore first")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }
                    .motionAnimation(.easeInOut(duration: 0.3), value: currentPage)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        // The page titles above scale with the setting, but past this point
        // a page no longer fits between the Skip bar and the buttons.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .onChange(of: currentPage) { _, newPage in
            triggerPageAnimation(newPage)
        }
        .onAppear {
            triggerPageAnimation(0)
        }
        .preferredColorScheme(.dark)
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    // MARK: - Page 1: Welcome Hero

    private var welcomeHeroPage: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                // Glow behind icon
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.indsCrimsonLight.opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 120
                        )
                    )
                    .frame(width: 250, height: 250)
                    .opacity(animatedPages.contains(0) ? 1 : 0)
                    // Slow continuous breathing, independent of the reveal
                    // above (a separate property, so the two compose rather
                    // than one overwriting the other).
                    .scaleEffect(heroGlowPulse ? 1.12 : 0.92)
                    .onAppear {
                        guard let pulse = INDSMotion.pulse else { return }
                        withAnimation(pulse) { heroGlowPulse = true }
                    }

                Image("SplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.indsCrimsonDark.opacity(0.5), radius: animatedPages.contains(0) ? 30 : 0, x: 0, y: 10)
                    .scaleEffect(animatedPages.contains(0) ? 1.0 : 0.5)
            }
            .motionAnimation(.spring(response: 0.7, dampingFraction: 0.7), value: animatedPages)

            Spacer().frame(height: 36)

            Text("Welcome to eDuo")
                .font(.system(size: welcomeTitleSize, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(animatedPages.contains(0) ? 1 : 0)
                .offset(y: animatedPages.contains(0) ? 0 : 20)
                .motionAnimation(.easeOut(duration: 0.5).delay(0.15), value: animatedPages)

            Spacer().frame(height: 12)

            Text("Your games, back in your pocket.")
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(animatedPages.contains(0) ? 1 : 0)
                .offset(y: animatedPages.contains(0) ? 0 : 15)
                .motionAnimation(.easeOut(duration: 0.45).delay(0.25), value: animatedPages)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 2: Add Your Games

    private var addYourGamesPage: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)

            ZStack {
                Circle()
                    .fill(Color.indsCrimsonLight.opacity(0.16))
                    .frame(width: 156, height: 156)
                    .blur(radius: 8)

                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color.indsCrimsonLight],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .scaleEffect(animatedPages.contains(1) ? 1.0 : 0.6)
            .opacity(animatedPages.contains(1) ? 1 : 0)
            .motionAnimation(.spring(response: 0.7, dampingFraction: 0.72), value: animatedPages)

            Spacer().frame(height: 26)

            Text("Add Your Games")
                .font(.system(size: pageTitleSize, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(animatedPages.contains(1) ? 1 : 0)
                .offset(y: animatedPages.contains(1) ? 0 : 20)
                .motionAnimation(.easeOut(duration: 0.45).delay(0.08), value: animatedPages)

            Spacer().frame(height: 10)

            Text("Import .nds files — or .zip/.7z archives containing them — straight from the Files app.")
                .font(.body)
                .foregroundColor(.white.opacity(0.64))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
                .opacity(animatedPages.contains(1) ? 1 : 0)
                .motionAnimation(.easeOut(duration: 0.45).delay(0.16), value: animatedPages)

            Spacer().frame(height: 20)

            HStack(spacing: 12) {
                formatBadge(".NDS", color: .indsCrimsonLight)
                formatBadge(".ZIP", color: .orange)
                formatBadge(".7Z", color: .teal)
                formatBadge(".GZ", color: .mint)
            }
            .opacity(animatedPages.contains(1) ? 1 : 0)
            .motionAnimation(.easeOut(duration: 0.4).delay(0.22), value: animatedPages)

            Spacer().frame(height: 20)

            benefitRow(
                icon: "photo.on.rectangle.angled",
                text: "eDuo reads each cartridge's own banner, so your library shows real game icons and titles."
            )
            .padding(.horizontal, 28)
            .opacity(animatedPages.contains(1) ? 1 : 0)
            .motionAnimation(.easeOut(duration: 0.45).delay(0.28), value: animatedPages)

            Spacer()

            Text("eDuo plays game files you legally own. No games are included.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .opacity(animatedPages.contains(1) ? 1 : 0)
                .motionAnimation(.easeOut(duration: 0.4).delay(0.34), value: animatedPages)

            Spacer().frame(height: 8)
        }
    }

    // MARK: - Page 3: Made for two screens

    private var madeForDSPage: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)

            Text("Made for two screens")
                .font(.system(size: pageTitleSize, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(animatedPages.contains(2) ? 1 : 0)
                .offset(y: animatedPages.contains(2) ? 0 : 20)
                .motionAnimation(.easeOut(duration: 0.45), value: animatedPages)

            Spacer().frame(height: 18)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    featureCard(
                        icon: "rectangle.grid.1x2.fill", color: .indsCrimsonLight,
                        title: "Dual-Screen Layouts",
                        description: "Stack both screens, place them side by side, or focus on just one — switch anytime.",
                        page: 2, delay: 0.05
                    )
                    featureCard(
                        icon: "hand.tap.fill", color: .green,
                        title: "Real Touch Screen",
                        description: "Tap and drag like a stylus on the bottom screen — menus, minigames and drawing all just work.",
                        page: 2, delay: 0.1
                    )
                    featureCard(
                        icon: "tray.full.fill", color: .orange,
                        title: "Save States & Auto-Save",
                        description: "Manual save slots plus an automatic save whenever you leave a game. Slot 1 is free; PRO adds three more.",
                        page: 2, delay: 0.15
                    )
                    featureCard(
                        icon: "checkmark.seal.fill", color: .cyan,
                        title: "No BIOS Needed",
                        description: "No BIOS files needed — just import and play. Real dumps are optional, for a few extra-compatible games.",
                        page: 2, delay: 0.2
                    )
                    featureCard(
                        icon: "mic.fill", color: .red,
                        title: "Microphone Input",
                        description: "Blow into the mic — games that listen actually hear you.",
                        page: 2, delay: 0.25
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Page 4: Controls

    private var controlsPage: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)

            Text("Your Way to Play")
                .font(.system(size: pageTitleSize, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .opacity(animatedPages.contains(3) ? 1 : 0)
                .offset(y: animatedPages.contains(3) ? 0 : 20)
                .motionAnimation(.easeOut(duration: 0.45), value: animatedPages)

            Spacer().frame(height: 28)

            // Scrollable like `madeForDSPage`: at the largest Dynamic Type sizes
            // the three cards outgrow the page, and without this there is no way
            // to reach the bottom one.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    featureCard(
                        icon: "gamecontroller.fill", color: .indsCrimsonLight,
                        title: "On-Screen Controller",
                        description: "A customizable overlay — adjust opacity and size, or hide it entirely, from Settings.",
                        page: 3, delay: 0.05
                    )
                    featureCard(
                        icon: "gamecontroller", color: .purple,
                        title: "Physical Controllers",
                        description: "Connect any MFi or Bluetooth gamepad — buttons map automatically to the original layout.",
                        page: 3, delay: 0.1
                    )
                    featureCard(
                        icon: "keyboard", color: .blue,
                        title: "Keyboard Support",
                        description: "Arrow keys move, with the rest of the pad mapped across the keys next to them.",
                        page: 3, delay: 0.15
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: - Components

    // `title`/`description` are LocalizedStringKey, not String: `Text(someString)`
    // renders verbatim, so every card on the "Made for two screens" and "Your Way to Play"
    // pages shipped in English no matter the device language. Literals at the call
    // sites keep working unchanged.
    private func featureCard(
        icon: String, color: Color, title: LocalizedStringKey, description: LocalizedStringKey,
        page: Int, delay: Double, badge: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    if let badge {
                        Text(badge.uppercased())
                            .font(.system(size: cardBadgeSize, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(animatedPages.contains(page) ? 1 : 0)
        .offset(x: animatedPages.contains(page) ? 0 : 40)
        .motionAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(delay), value: animatedPages)
    }

    private func formatBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: formatBadgeSize, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // Same reason as `featureCard`: LocalizedStringKey so the literal localizes.
    private func benefitRow(icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.indsCrimsonLight)
                .frame(width: 24)

            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Helpers

    private func triggerPageAnimation(_ page: Int) {
        guard !animatedPages.contains(page) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withMotion {
                _ = animatedPages.insert(page)
            }
        }
    }
}
