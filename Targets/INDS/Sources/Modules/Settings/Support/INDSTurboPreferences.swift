//
//  INDSTurboPreferences.swift
//  eDuo
//
//  Which buttons auto-fire while held. This is a preference, not a property
//  of the controller layout: it applies equally to the touch overlay, to a
//  game controller and to a keyboard, and the layout only knows about the
//  first of the three. Rate and hold/latch mode are configurable (iGBA has
//  the same ladder); a controller's «Rapid fire on/off» pauses all of it.
//

import Foundation

enum INDSTurboPreferences {
    /// Action buttons only. Turbo on the d-pad or on Start does nothing
    /// useful and does open the door to menus flickering on their own.
    static let eligible: [INDSButton] = [.A, .B, .X, .Y, .L, .R]

    private static let key = "eNDSTurboButtons"

    static var buttons: Set<INDSButton> {
        get {
            let raw = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
            return Set(raw.compactMap(INDSButton.init(rawValue:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: key)
        }
    }

    static func isTurbo(_ button: INDSButton) -> Bool { buttons.contains(button) }

    static func setTurbo(_ on: Bool, for button: INDSButton) {
        var set = buttons
        if on { set.insert(button) } else { set.remove(button) }
        buttons = set
    }

    static var isAnyEnabled: Bool { !buttons.isEmpty }

    private static let rateKey = "eNDSTurboRateHz"
    private static let toggleModeKey = "eNDSTurboToggleMode"

    /// Pulsaciones por segundo (`INDSTurboPattern.rates`).
    static var rateHz: Int {
        get { INDSTurboPattern.clampedRate(UserDefaults.standard.integer(forKey: rateKey)) }
        set { UserDefaults.standard.set(INDSTurboPattern.clampedRate(newValue), forKey: rateKey) }
    }

    /// false = dispara mientras se mantiene; true = un toque lo engancha y
    /// otro lo suelta.
    static var toggleMode: Bool {
        get { UserDefaults.standard.bool(forKey: toggleModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: toggleModeKey) }
    }

    static func displayName(_ button: INDSButton) -> String {
        switch button {
        case .A: return "A"
        case .B: return "B"
        case .X: return "X"
        case .Y: return "Y"
        case .L: return "L"
        case .R: return "R"
        default: return ""
        }
    }
}
