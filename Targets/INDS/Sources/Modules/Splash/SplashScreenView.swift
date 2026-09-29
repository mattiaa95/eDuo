//
//  SplashScreenView.swift
//  eDuo
//
//  Ported and adapted from iGBA's SplashScreenView.swift: same
//  animation shape — icon spring-scale + radial glow, title fade+offset,
//  subtitle, version badge, then a fade-to-app exit — driven by
//  `onAnimationComplete`. Adaptations vs. iGBA:
//   - iGBA hosts this from a dedicated `SplashHostingViewController` (UIKit
//     root). eDuo is SwiftUI-root, so `ContentView` shows this directly as a
//     ZStack overlay over `ROMListView` instead — no hosting controller
//     needed.
//   - Icon is "SplashIcon" (a plain imageset copy of AppIcon1024.png — app
//     icons themselves can't be referenced via `Image(_:)`), not "icon".
//   - Glow/shadow use eDuo's crimson brand color (matching the app icon's
//     own gradient) instead of iGBA's purple. Background reuses the same
//     dark neutral `ROMListView` uses for its library backdrop, instead of
//     iGBA's navy, so the splash reads as part of eDuo's own dark-first UI.
//   - Timing compressed to a ~1.6s hold before the exit fade (vs iGBA's
//     ~2.2s), so returning users reach the library faster.
//   - Respects Reduce Motion: jumps straight to the final state and
//     completes quickly instead of running the spring/fade sequence.
//

import SwiftUI

/// eDuo's crimson brand color, matching the app icon's gradient
/// (`AppIcon1024.png`: #E8546A → #AC1E3E). Shared with `WelcomeView`, which
/// reuses the same hero glow for visual continuity between splash and
/// onboarding.
extension Color {
    static let indsCrimsonLight = Color(red: 0.910, green: 0.329, blue: 0.416)
    static let indsCrimsonDark = Color(red: 0.675, green: 0.118, blue: 0.243)
}

extension Notification.Name {
    /// Posted by `ContentView` once the launch splash finishes its exit
    /// fade. `ROMListView` listens for this to know when it's safe to
    /// present first-launch onboarding (`WelcomeView`).
    static let splashDidComplete = Notification.Name("eNDSSplashDidComplete")
}

struct SplashScreenView: View {

    let onAnimationComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var iconScale: CGFloat = 0.1
    @State private var iconOpacity: Double = 0.0
    @State private var glowRadius: CGFloat = 0
    @State private var titleOpacity: Double = 0.0
    @State private var titleOffset: CGFloat = 18
    @State private var subtitleOpacity: Double = 0.0
    @State private var versionOpacity: Double = 0.0
    @State private var exitOpacity: Double = 1.0

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        ZStack {
            // Background — the same dark neutral as the library's own
            // backdrop, so the splash reads as part of eDuo rather than a
            // separate screen bolted on top.
            Color(red: 0.06, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            // Subtle crimson glow behind the icon
            RadialGradient(
                colors: [
                    Color.indsCrimsonLight.opacity(0.28),
                    Color.clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: 220
            )
            .ignoresSafeArea()
            .opacity(iconOpacity)

            VStack(spacing: 0) {
                Spacer()

                // App icon
                Image("SplashIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.indsCrimsonDark.opacity(0.55), radius: glowRadius, x: 0, y: 8)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                Spacer().frame(height: 28)

                // App name
                Text("eDuo")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: titleOffset)
                    .opacity(titleOpacity)

                Spacer().frame(height: 8)

                // Subtitle
                Text("Retro Game Emulator")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .opacity(subtitleOpacity)

                Spacer()

                // Version badge
                Text("v\(appVersion)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Capsule())
                    .opacity(versionOpacity)
                    .padding(.bottom, 44)
            }
        }
        .opacity(exitOpacity)
        .onAppear { runAnimation() }
    }

    private func runAnimation() {
        guard !reduceMotion else {
            // Skip straight to the final state — no spring/fade sequence —
            // then hand off quickly.
            iconScale = 1.0
            iconOpacity = 1.0
            glowRadius = 40
            titleOffset = 0
            titleOpacity = 1.0
            subtitleOpacity = 1.0
            versionOpacity = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                onAnimationComplete()
            }
            return
        }

        // Icon springs in
        withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) {
            iconScale = 1.0
            iconOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.7)) {
            glowRadius = 40
        }

        // Title slides and fades in
        withAnimation(.easeOut(duration: 0.4).delay(0.25)) {
            titleOpacity = 1.0
            titleOffset = 0
        }

        // Subtitle
        withAnimation(.easeOut(duration: 0.35).delay(0.42)) {
            subtitleOpacity = 1.0
        }

        // Version badge
        withAnimation(.easeOut(duration: 0.3).delay(0.55)) {
            versionOpacity = 1.0
        }

        // Hold, then fade out and hand off (~1.6s before the exit fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.35)) {
                exitOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                onAnimationComplete()
            }
        }
    }
}
