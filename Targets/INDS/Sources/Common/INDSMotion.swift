//
//  INDSMotion.swift
//  eDuo
//
//  Shared motion tokens + Reduce-Motion-aware helpers for the UX/animation
//  pass. Every *new* animation introduced by that pass routes through this
//  file instead of hand-rolling its own `Animation`/`UIView.animate` call —
//  keeps the whole app feeling like one system, and keeps "does this respect
//  Reduce Motion" a one-file question instead of an every-call-site one.
//
//  Two call shapes cover almost everything:
//   - `withMotion { ... }` — imperative state changes (mirrors `withAnimation`).
//   - `.motionAnimation(_:value:)` — implicit per-value view animations
//     (mirrors `.animation(_:value:)`), used for the same index-based stagger
//     idiom `WelcomeView` already established (`.animation(...).delay(x),
//     value: someSet)`).
//  A couple of small, reusable primitives (`pressableScale`,
//  `PressableScaleStyle`, `motionBounceSymbolEffect`) live here too since
//  they're pure motion concerns shared by several unrelated screens.
//
//  UIKit call sites (`NDSHUDView`, `NDSRomViewController` — SwiftUI's
//  `Animation` doesn't reach them) get the parallel `INDSMotion.fadeUIKit`
//  helper below instead.
//

import SwiftUI
import UIKit

enum INDSMotion {
    // MARK: - SwiftUI tokens

    /// Quick, springy feedback for direct-manipulation UI: button/cell press
    /// releases, favorite bounces, small state pops.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// Softer, slightly slower spring for larger/less-frequent transitions:
    /// page/state reveals, staggered rows, hero moments.
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.9)

    /// Plain crossfade — both a token in its own right (toasts, simple
    /// show/hide) and the default Reduce Motion fallback for the two above.
    static let fade = Animation.easeInOut(duration: 0.22)

    /// Slow, continuous "breathing" loop for ambient glows (empty-state
    /// icon, hero glow). `nil` under Reduce Motion — gate the `withAnimation`
    /// call on this being non-nil so the bound state simply never flips and
    /// the view settles at its static rest value instead of looping.
    static var pulse: Animation? {
        reduceMotionEnabled ? nil : Animation.easeInOut(duration: 1.8).repeatForever(autoreverses: true)
    }

    // MARK: - Reduce Motion

    /// Read live (not cached) — Settings > Accessibility can flip this while
    /// the app is running.
    static var reduceMotionEnabled: Bool { UIAccessibility.isReduceMotionEnabled }

    /// `preferred` normally, `reducedFallback` (a plain crossfade by default,
    /// or `nil` for no animation at all) when Reduce Motion is on.
    // @_optimize(none): same optimizer-crash dodge as `withMotion` below —
    // the conditional `Animation?` here is the shared shape every crashing
    // call site inlined. Keeping it un-inlined keeps callers' SIL clean.
    @_optimize(none)
    static func animation(_ preferred: Animation, reducedFallback: Animation? = fade) -> Animation? {
        reduceMotionEnabled ? reducedFallback : preferred
    }

    // MARK: - UIKit

    /// UIKit counterpart of the SwiftUI tokens above, for the handful of
    /// animations that live in UIKit code. Reduce Motion shortens (rather
    /// than removes) the duration — a cross-fade is the HIG-recommended
    /// *replacement* for motion, not something to strip out too.
    static func fadeUIKit(
        duration: TimeInterval = 0.3,
        delay: TimeInterval = 0,
        options: UIView.AnimationOptions = [.curveEaseInOut],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        let effectiveDuration = reduceMotionEnabled ? min(duration, 0.15) : duration
        UIView.animate(withDuration: effectiveDuration, delay: delay, options: options, animations: animations, completion: completion)
    }
}

/// Runs `body` inside `withAnimation`, substituting a short crossfade (or no
/// animation) for the requested animation when Reduce Motion is enabled. Use
/// this instead of calling `withAnimation` directly for any *new* imperative
/// state change introduced during the motion pass.
// Non-generic and never inlined on purpose: the generic `rethrows` version
// of this wrapper crashed the Swift optimizer (SIL "OwnershipModelEliminator"
// verification failure) when archiving Release — triggered from
// PurchaseView's plan-selection closure. Nothing here needs a return value
// or throwing support, so the simplest shape that dodges the compiler bug
// wins.
@inline(never)
@_optimize(none)
func withMotion(
    _ animation: Animation = INDSMotion.snappy,
    reducedFallback: Animation? = INDSMotion.fade,
    _ body: () -> Void
) {
    withAnimation(INDSMotion.animation(animation, reducedFallback: reducedFallback), body)
}

extension View {
    /// Reduce-Motion-aware equivalent of `.animation(_:value:)`, for the
    /// implicit per-value-change animations used throughout this pass (e.g.
    /// `WelcomeView`'s per-row stagger: same animation, a different `.delay`
    /// baked in per row, all keyed off one shared trigger value).
    @_optimize(none)
    func motionAnimation<V: Equatable>(_ animation: Animation, reducedFallback: Animation? = INDSMotion.fade, value: V) -> some View {
        self.animation(INDSMotion.animation(animation, reducedFallback: reducedFallback), value: value)
    }

    /// Adds a press-down scale (spring release on lift) to any tappable view
    /// without taking over its own tap handling or chrome — a
    /// `simultaneousGesture` press detector layered on top, instead of a
    /// custom `ButtonStyle`. Use this where the view needs to keep a native
    /// style (e.g. `.borderedProminent`) for its background/tint.
    ///
    /// Always animates, even under Reduce Motion: this is direct
    /// touch-down/touch-up feedback (the same category as a native button's
    /// own press dimming, which iOS itself doesn't gate on Reduce Motion),
    /// not an ambient or automatic motion effect.
    func pressableScale(_ scale: CGFloat = 0.97) -> some View {
        modifier(INDSPressableScaleModifier(scale: scale))
    }

    /// Applies `.symbolEffect(.bounce, value:)`, skipped entirely under
    /// Reduce Motion (the icon still updates — no bounce, no substitute
    /// animation needed for a symbol swap this small).
    @ViewBuilder
    func motionBounceSymbolEffect<V: Equatable>(value: V) -> some View {
        if INDSMotion.reduceMotionEnabled {
            self
        } else {
            self.symbolEffect(.bounce, value: value)
        }
    }
}

/// Shared press-down interaction for custom-chrome buttons/cards (library
/// grid/classic cells, paywall plan cards): scales to `scale` while pressed,
/// springs back via `INDSMotion.snappy` on release. Same Reduce-Motion
/// reasoning as `pressableScale(_:)` above — always animates.
struct PressableScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(INDSMotion.snappy, value: configuration.isPressed)
    }
}

private struct INDSPressableScaleModifier: ViewModifier {
    let scale: CGFloat
    @State private var isPressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1)
            .animation(INDSMotion.snappy, value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}
