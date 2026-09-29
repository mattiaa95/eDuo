//
//  INDSTurboPreferences.swift
//  eDuo
//
//  Which buttons auto-fire while held. This is a preference, not a property
//  of the controller layout: it applies equally to the touch overlay, to a
//  game controller and to a keyboard, and the layout only knows about the
//  first of the three.
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
