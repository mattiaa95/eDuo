//
//  INDSControllerMappingStore.swift
//  eDuo
//
//  Ported and adapted from iGBA's ControllerMappingStore.swift: single source
//  of truth for external-gamepad button remapping. The pure rules (defaults,
//  migration, conflicts) live in INDSControllerMappingLogic.swift.
//
//  Storage model:
//  - `activeKey` ([physicalKey: targetRawValue]) is the ACTIVE mapping —
//    `INDSGamepadManager` re-reads it on every physical button event, so
//    remapping never requires the manager to be told about a change.
//  - `profilesKey` ([profileID: mapping]) remembers one mapping per
//    controller model (vendor + productCategory); connecting a known
//    controller re-activates its profile automatically.
//  - `pendingKey`: edits made with no controller connected, merged over the
//    profile when one connects (otherwise the profile would overwrite them).
//
//  Everything is remappable, the d-pad and the Menu button included. Only the
//  left stick always moves, and a remapped Menu button still opens the pause
//  menu when held if nothing else does (`INDSMappingLogic.menuEscapeApplies`).
//

import Foundation
import GameController

extension Notification.Name {
    static let indsControllerMappingDidChange = Notification.Name("INDSControllerMappingDidChange")
}

/// Discrete app-level actions an external-input button can trigger, distinct
/// from the 12 DS buttons. Handled by `NDSRomViewController`.
enum INDSControllerAppAction {
    case pause
    case quickSave
    case quickLoad
    case cycleScreenLayout
    case swapScreens
    /// Hold state; reported through `setFastForwardActive` instead.
    case fastForward
    /// A short tap on the Fast Forward hold: step to the next rate.
    case nextFastForwardSpeed
    case fastForwardToggle
    case turboToggle
    case rewind
}

extension INDSMappingTarget {
    /// `nil` for anything that isn't one of the 12 DS buttons.
    var indsButton: INDSButton? {
        guard isDSButton else { return nil }
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
        case .fastForwardToggle: return .fastForwardToggle
        case .turboToggle: return .turboToggle
        case .rewind: return .rewind
        default: return nil
        }
    }

    var isEmulatorAction: Bool { Self.emulatorOrder.contains(self) }

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
        case .fastForward: return NSLocalizedString("Fast forward (hold)", comment: "Mapping target: fast forward while the button is held")
        case .fastForwardToggle: return NSLocalizedString("Fast forward (on/off)", comment: "Mapping target: one press turns fast forward on, the next one off")
        case .turboToggle: return NSLocalizedString("Rapid fire on/off", comment: "Mapping target: switches rapid fire (turbo buttons) on or off")
        case .rewind: return NSLocalizedString("Rewind", comment: "")
        case .none: return NSLocalizedString("Unassigned", comment: "Mapping target")
        }
    }

    /// Una línea que cuenta qué hace, para la lista de acciones.
    var detail: String? {
        switch self {
        case .fastForward: return NSLocalizedString("Hold to speed up. A quick tap picks the next speed.", comment: "Mapping target detail")
        case .fastForwardToggle: return NSLocalizedString("Press once to speed up, again to go back.", comment: "Mapping target detail")
        case .turboToggle: return NSLocalizedString("Pauses or resumes rapid fire on the buttons you chose.", comment: "Mapping target detail")
        case .rewind: return NSLocalizedString("Jump ~10 seconds back — undo that mistake", comment: "")
        case .quickSave: return NSLocalizedString("Saves to slot 1 without opening the menu.", comment: "Mapping target detail")
        case .quickLoad: return NSLocalizedString("Loads slot 1 without opening the menu.", comment: "Mapping target detail")
        default: return nil
        }
    }

    /// SF Symbol de la acción (no del botón físico).
    var symbol: String {
        switch self {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case .left: return "arrowtriangle.left.fill"
        case .right: return "arrowtriangle.right.fill"
        case .a: return "a.circle.fill"
        case .b: return "b.circle.fill"
        case .x: return "x.circle.fill"
        case .y: return "y.circle.fill"
        case .l: return "l.rectangle.roundedbottom.fill"
        case .r: return "r.rectangle.roundedbottom.fill"
        case .start: return "play.circle.fill"
        case .select: return "capsule.fill"
        case .pause: return "pause.circle.fill"
        case .fastForward: return "forward.fill"
        case .fastForwardToggle: return "forward.circle.fill"
        case .turboToggle: return "flame.fill"
        case .rewind: return "backward.end.alt.fill"
        case .quickSave: return "square.and.arrow.down.fill"
        case .quickLoad: return "square.and.arrow.up.fill"
        case .cycleScreenLayout: return "rectangle.split.1x2.fill"
        case .swapScreens: return "arrow.up.arrow.down"
        case .none: return "circle.dashed"
        }
    }

    /// Etiqueta corta para el dibujo del mando ("A", "Start"); vacía = símbolo.
    var shortLabel: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .a, .b, .x, .y, .l, .r: return displayName
        case .start: return "St"
        case .select: return "Se"
        case .none: return "—"
        default: return ""
        }
    }
}

/// Per-controller button remapping store. Namespace-only, like this
/// codebase's other UserDefaults-backed stores.
enum INDSControllerMappingStore {

    static let activeKey = "eNDSExternalControllerButtons"
    static let profilesKey = "eNDSExternalControllerProfiles"
    static let pendingKey = "eNDSExternalControllerPendingMapping"

    static var defaultMapping: [String: Int] { INDSMappingLogic.defaultMapping }

    // MARK: - Active mapping

    static func activeMapping() -> [String: Int] {
        let stored = UserDefaults.standard.dictionary(forKey: activeKey) as? [String: Int] ?? [:]
        let repaired = INDSMappingLogic.migrate(stored)
        if repaired != stored {
            UserDefaults.standard.set(repaired, forKey: activeKey)
        }
        return repaired
    }

    /// Resolves the live target for one physical input.
    static func target(forPhysical key: String, in mapping: [String: Int]? = nil) -> INDSMappingTarget {
        let raw = (mapping ?? activeMapping())[key] ?? INDSMappingTarget.none.rawValue
        return INDSMappingTarget(rawValue: raw) ?? .none
    }

    /// Sustituye el mapeo activo entero (deshacer, restablecer).
    static func setMapping(_ mapping: [String: Int], controller: GCController?) {
        let clean = INDSMappingLogic.migrate(mapping)
        UserDefaults.standard.set(clean, forKey: activeKey)
        if controller != nil { saveProfile(clean, for: controller) } else { rememberPending(clean) }
        NotificationCenter.default.post(name: .indsControllerMappingDidChange, object: nil)
    }

    /// Asigna una acción a un botón físico. Devuelve lo que se ha quedado sin
    /// ningún botón por culpa de esta asignación, para ofrecer deshacer.
    @discardableResult
    static func assign(_ target: INDSMappingTarget, toPhysical key: String, controller: GCController?) -> INDSMappingTarget? {
        let result = INDSMappingLogic.assign(target, to: key, in: activeMapping())
        UserDefaults.standard.set(result.mapping, forKey: activeKey)
        if controller != nil { saveProfile(result.mapping, for: controller) } else { rememberPending([key: target.rawValue]) }
        NotificationCenter.default.post(name: .indsControllerMappingDidChange, object: nil)
        return result.displaced
    }

    static func resetToDefaults(controller: GCController?) {
        setMapping(defaultMapping, controller: controller)
    }

    /// Todos los mandos a fábrica: perfiles, pendientes y el activo.
    static func resetAllControllers() {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.removeObject(forKey: pendingKey)
        UserDefaults.standard.set(defaultMapping, forKey: activeKey)
        NotificationCenter.default.post(name: .indsControllerMappingDidChange, object: nil)
    }

    // MARK: - Per-controller profiles

    /// One profile per controller model (vendor + category) — enough to give
    /// a DualSense and an Xbox pad different mappings without pairing UUIDs.
    static func profileID(for controller: GCController) -> String {
        "\(controller.vendorName ?? "Unknown")|\(controller.productCategory)"
    }

    private static func saveProfile(_ mapping: [String: Int], for controller: GCController?) {
        guard let controller else { return }
        var profiles = UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: [String: Int]] ?? [:]
        profiles[profileID(for: controller)] = mapping
        UserDefaults.standard.set(profiles, forKey: profilesKey)
    }

    private static func rememberPending(_ edits: [String: Int]) {
        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Int] ?? [:]
        for (key, value) in edits { pending[key] = value }
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    /// Called when a controller connects: a known model re-activates its
    /// saved mapping, an unknown one adopts the active mapping. Either way,
    /// what was remapped with no controller around wins over what was saved.
    static func activateProfile(for controller: GCController) {
        let profiles = UserDefaults.standard.dictionary(forKey: profilesKey) as? [String: [String: Int]] ?? [:]
        let pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Int] ?? [:]
        if let saved = profiles[profileID(for: controller)] {
            // migrate: a 1.0 profile has no d-pad/Menu/L3… keys.
            let merged = INDSMappingLogic.migrate(saved.merging(pending) { _, new in new })
            UserDefaults.standard.set(merged, forKey: activeKey)
            if merged != saved { saveProfile(merged, for: controller) }
        } else {
            saveProfile(activeMapping(), for: controller)
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        NotificationCenter.default.post(name: .indsControllerMappingDidChange, object: nil)
    }
}
