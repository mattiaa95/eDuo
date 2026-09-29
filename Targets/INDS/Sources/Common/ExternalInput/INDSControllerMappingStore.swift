//
//  INDSControllerMappingStore.swift
//  eDuo
//
//  Ported and adapted from iGBA's ControllerMappingStore.swift:
//  single source of truth for external-gamepad button remapping. Same shape
//  (active mapping + per-controller-model profiles in UserDefaults, healed on
//  every read), rescoped to the DS button set.
//
//  Storage model:
//  - `activeKey` ([physicalKey: targetRawValue]) is the ACTIVE mapping —
//    `INDSGamepadManager` re-reads it on every physical button event, so
//    remapping never requires the manager to be told about a change.
//  - `profilesKey` ([profileID: mapping]) remembers one mapping per
//    controller model (vendor + productCategory); connecting a known
//    controller re-activates its profile automatically
//    (`INDSGamepadManager` calls `activateProfile` on connect).
//
//  Deliberately NOT remappable: the d-pad and left thumbstick (movement stays
//  fixed — see `INDSGamepadManager`) and the system Menu button (always
//  pause, guaranteeing a way into the pause menu even with a blank mapping).
//  Keyboard input is a separate, fixed (non-remappable) scheme — see
//  `INDSKeyboardManager` — this store only covers gamepads ("per-mando").
//

import Foundation
import GameController

/// Discrete app-level actions an external-input button can trigger, distinct
/// from the 12 DS buttons. `fastForward` is a hold (start/stop), the rest
/// fire once per press. Handled by `NDSRomViewController`.
enum INDSControllerAppAction {
    case pause
    case quickSave
    case quickLoad
    case cycleScreenLayout
    case swapScreens
    case fastForward
}

/// What a physical gamepad button can be assigned to: one of the 12 DS
/// buttons, or an app action. DS-button raw values are IDENTICAL to
/// `INDSButton`'s own raw values (A=0, B=1, Select=2, Start=3, Right=4,
/// Left=5, Up=6, Down=7, R=8, L=9, X=10, Y=11), so resolving a target that is
/// a DS button is a plain `INDSButton(rawValue:)` round trip. App actions use
/// raw values ≥ 50 so they can never collide with a DS button's raw value.
enum INDSMappingTarget: Int, CaseIterable, Identifiable, Codable {
    case a = 0
    case b = 1
    case select = 2
    case start = 3
    case right = 4
    case left = 5
    case up = 6
    case down = 7
    case r = 8
    case l = 9
    case x = 10
    case y = 11

    case pause = 50
    case quickSave = 51
    case quickLoad = 52
    case cycleScreenLayout = 53
    case swapScreens = 54
    case fastForward = 55

    case none = 99

    var id: Int { rawValue }

    /// `nil` for anything that isn't one of the 12 DS buttons.
    var indsButton: INDSButton? {
        guard (0...11).contains(rawValue) else { return nil }
        return INDSButton(rawValue: rawValue)
    }

    /// `nil` for anything that isn't an app action (a DS button, or `.none`).
    var appAction: INDSControllerAppAction? {
        switch self {
        case .pause: return .pause
        case .quickSave: return .quickSave
        case .quickLoad: return .quickLoad
        case .cycleScreenLayout: return .cycleScreenLayout
        case .swapScreens: return .swapScreens
        case .fastForward: return .fastForward
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .start: return NSLocalizedString("Start", comment: "Mapping target")
        case .select: return NSLocalizedString("Select", comment: "Mapping target")
        case .up: return NSLocalizedString("Up", comment: "Mapping target")
        case .down: return NSLocalizedString("Down", comment: "Mapping target")
        case .left: return NSLocalizedString("Left", comment: "Mapping target")
        case .right: return NSLocalizedString("Right", comment: "Mapping target")
        case .pause: return NSLocalizedString("Pause", comment: "Mapping target")
        case .quickSave: return NSLocalizedString("Quick Save", comment: "Mapping target")
        case .quickLoad: return NSLocalizedString("Quick Load", comment: "Mapping target")
        case .cycleScreenLayout: return NSLocalizedString("Cycle Screen Layout", comment: "Mapping target")
        case .swapScreens: return NSLocalizedString("Swap Screens", comment: "Mapping target")
        case .fastForward: return NSLocalizedString("Fast Forward (Hold)", comment: "Mapping target")
        case .none: return NSLocalizedString("Unassigned", comment: "Mapping target")
        }
    }

    /// Picker order: DS face/shoulder/start-select buttons first, D-pad
    /// directions (rarely retargeted, but valid targets per spec), then app
    /// actions, then "Unassigned" last.
    static let pickerOrder: [INDSMappingTarget] = [
        .a, .b, .x, .y, .l, .r, .start, .select,
        .up, .down, .left, .right,
        .pause, .quickSave, .quickLoad, .cycleScreenLayout, .swapScreens, .fastForward,
        .none,
    ]
}

/// Per-controller button remapping store. Namespace-only (no instances),
/// matching this codebase's other UserDefaults-backed stores (`INDSHaptics`,
/// `INDSPerGameProfileStore`).
enum INDSControllerMappingStore {

    static let activeKey = "eNDSExternalControllerButtons"
    static let profilesKey = "eNDSExternalControllerProfiles"

    /// Physical inputs the user can remap, in UI display order. Keys match
    /// `INDSGamepadManager`'s handler wiring — the d-pad and left thumbstick
    /// are intentionally absent (movement stays fixed).
    static let remappablePhysicalInputs: [String] = ["A", "B", "X", "Y", "L1", "R1", "L2", "R2", "Options"]

    /// Positional "DS layout" default (see `INDSGamepadManager`'s doc
    /// comment for the south/east/west/north reasoning) plus L2/R2/Options
    /// covering the two DS buttons a standard 8-button-plus-bumpers pad has
    /// no face button left for: L2→Select, R2→Start, Options→Pause (a
    /// second, remappable way into the pause menu alongside the always-on
    /// system Menu button).
    static let defaultMapping: [String: Int] = [
        "A": INDSMappingTarget.b.rawValue,
        "B": INDSMappingTarget.a.rawValue,
        "X": INDSMappingTarget.y.rawValue,
        "Y": INDSMappingTarget.x.rawValue,
        "L1": INDSMappingTarget.l.rawValue,
        "R1": INDSMappingTarget.r.rawValue,
        "L2": INDSMappingTarget.select.rawValue,
        "R2": INDSMappingTarget.start.rawValue,
        "Options": INDSMappingTarget.pause.rawValue,
    ]

    private static let validTargets: Set<Int> = Set(INDSMappingTarget.allCases.map(\.rawValue))

    // MARK: - Active mapping

    /// Heals whatever is stored: every expected physical key present, every
    /// value a valid target, anything else (a stale key from a future
    /// version, or a corrupted value) dropped. Safe to call repeatedly;
    /// writes only when something actually changed.
    @discardableResult
    static func repairActiveMapping() -> [String: Int] {
        let stored = UserDefaults.standard.dictionary(forKey: activeKey) as? [String: Int] ?? [:]
        var repaired = defaultMapping
        for (key, value) in stored where defaultMapping[key] != nil && validTargets.contains(value) {
            repaired[key] = value
        }
        if repaired != stored {
            UserDefaults.standard.set(repaired, forKey: activeKey)
        }
        return repaired
    }

    static func activeMapping() -> [String: Int] {
        repairActiveMapping()
    }

    /// Resolves the live target for one physical input. Falls back to the
    /// hardware default (never to raw `0`, which would silently mean "A")
    /// when the key is missing from a stored mapping.
    static func target(forPhysical key: String) -> INDSMappingTarget {
        let raw = activeMapping()[key] ?? defaultMapping[key] ?? INDSMappingTarget.none.rawValue
        return INDSMappingTarget(rawValue: raw) ?? .none
    }

    static func setTarget(_ target: INDSMappingTarget, forPhysical key: String, controller: GCController?) {
        var mapping = activeMapping()
        mapping[key] = target.rawValue
        UserDefaults.standard.set(mapping, forKey: activeKey)
        saveProfile(mapping, for: controller)
    }

    static func resetToDefaults(controller: GCController?) {
        UserDefaults.standard.set(defaultMapping, forKey: activeKey)
        saveProfile(defaultMapping, for: controller)
    }

    // MARK: - Per-controller profiles

    /// One profile per controller model (vendor + category) — enough to give
    /// e.g. a DualSense and an Xbox pad different mappings without needing a
    /// per-device pairing UUID.
    static func profileID(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? "Unknown"
        return "\(vendor)|\(controller.productCategory)"
    }

    private static func saveProfile(_ mapping: [String: Int], for controller: GCController?) {
        guard let controller else { return }
        var profiles = UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: [String: Int]] ?? [:]
        profiles[profileID(for: controller)] = mapping
        UserDefaults.standard.set(profiles, forKey: profilesKey)
    }

    /// Called when a controller connects: a known controller model
    /// re-activates its saved mapping; an unknown one adopts the current
    /// active mapping as its own starting profile.
    static func activateProfile(for controller: GCController) {
        let profiles = UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: [String: Int]] ?? [:]
        if let saved = profiles[profileID(for: controller)] {
            UserDefaults.standard.set(saved, forKey: activeKey)
            repairActiveMapping()
        } else {
            saveProfile(activeMapping(), for: controller)
        }
    }
}
