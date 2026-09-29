//
//  INDSHaptics.swift
//  eDuo
//
//  Small shared helper so the controller overlay and the pause menu agree on
//  a single persisted haptics toggle ("eNDSHapticsEnabled", default ON) and
//  strength ("eNDSHapticStrength", default .medium — iGBA calls the same
//  knob "Taptic level", CustomControllerView.swift in iGBA).
//

import UIKit

/// The three-step strength the Controls settings picker exposes. `.medium`
/// is the default and reproduces exactly what `light()`/`medium()` below
/// always did before this setting existed (`.light`/`.medium` styles,
/// untouched); `.light`/`.strong` shift both call sites one tier down/up a
/// shared [.light, .medium, .heavy] ladder instead of needing a whole
/// second set of cached generators.
enum INDSHapticStrength: String, CaseIterable {
    case light
    case medium
    case strong

    var displayName: String {
        switch self {
        case .light:  return NSLocalizedString("Light", comment: "Haptic strength")
        case .medium: return NSLocalizedString("Medium", comment: "Haptic strength")
        case .strong: return NSLocalizedString("Strong", comment: "Haptic strength")
        }
    }

    fileprivate var ladderOffset: Int {
        switch self {
        case .light:  return -1
        case .medium: return 0
        case .strong: return 1
        }
    }
}

enum INDSHaptics {
    static let enabledDefaultsKey = "eNDSHapticsEnabled"
    static let strengthDefaultsKey = "eNDSHapticStrength"

    /// Defaults to `true` when never set (no explicit `register(defaults:)`
    /// needed — the key's absence itself means "on").
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledDefaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    static var strength: INDSHapticStrength {
        get {
            guard let raw = UserDefaults.standard.string(forKey: strengthDefaultsKey),
                  let value = INDSHapticStrength(rawValue: raw) else { return .medium }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: strengthDefaultsKey) }
    }

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    /// `baseIndex` 0 == `light()`'s usual `.light`, 1 == `medium()`'s usual
    /// `.medium` — `strength.ladderOffset` shifts along the same
    /// [.light, .medium, .heavy] ladder, clamped at both ends.
    private static func generator(baseIndex: Int) -> UIImpactFeedbackGenerator {
        switch max(0, min(2, baseIndex + strength.ladderOffset)) {
        case 0: return lightGenerator
        case 1: return mediumGenerator
        default: return heavyGenerator
        }
    }

    static func light() {
        guard isEnabled else { return }
        generator(baseIndex: 0).impactOccurred()
    }

    static func medium() {
        guard isEnabled else { return }
        generator(baseIndex: 1).impactOccurred()
    }

    /// "That worked" — currently the purchase confirmation. Notification-style
    /// rather than impact, and gated on the same preference as everything else:
    /// the paywall used to fire `UINotificationFeedbackGenerator` directly, so
    /// someone who had turned haptics off still got buzzed at the exact moment
    /// they'd spent money.
    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
