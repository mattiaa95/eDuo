//
//  INDSGamepadManager.swift
//  eDuo
//
//  Ported and adapted from iGBA's ExternalController.m: reads
//  a physical game controller (GCController) and drives the engine through a
//  delegate, the same role `NDSControllerView` plays for the on-screen
//  overlay. Adaptations vs. iGBA:
//   - Only the first controller is supported (multiple simultaneous pads are
//     out of scope for this pass).
//   - Physical-button → DS-button/app-action resolution goes through
//     `INDSControllerMappingStore` (per-controller-model remapping) instead
//     of a single flat dictionary.
//   - Everything goes through the mapping, the d-pad and the Menu button
//     included. Only the left thumbstick always moves; its directions and
//     whatever the mapped buttons hold are merged, so releasing one source
//     never lets go of a DS button another source is still holding.
//
//  Menu button: wired like any other button when the controller exposes it
//  (then `controllerPausedHandler` stays unset, or one press would do two
//  things). Remapped, holding it still opens the pause menu if no other
//  button does (`INDSMappingLogic.menuEscapeApplies`). Controllers that only
//  report pause through `controllerPausedHandler` keep that as pause.
//

import GameController
import UIKit

/// Where a controller's physical elements actually live.
///
/// iOS only gives a controller an `extendedGamepad` when it fits that profile
/// exactly; anything it cannot classify has none. An 8BitDo FlipPad wired over
/// USB-C is one of those, and code that reads only `extendedGamepad` wires
/// nothing at all for it — the pad connects, the touch controls disappear, and
/// no button does anything. (Reported against iGBA, fixed there first; this is
/// the same bug and the same fix.)
///
/// So every element is resolved twice: the typed property first, so nothing
/// changes for the pads that already worked, then by name off
/// `physicalInputProfile`, which every controller has whatever class iOS picked
/// for it. Both the gameplay path and the mapping screen resolve through here,
/// so a row that lights up is a button the game will actually read.
enum INDSControllerElements {

    /// Clave física → nombre de elemento de GameController.
    static let elementName: [String: String] = [
        "A": GCInputButtonA, "B": GCInputButtonB, "X": GCInputButtonX, "Y": GCInputButtonY,
        "L1": GCInputLeftShoulder, "R1": GCInputRightShoulder,
        "L2": GCInputLeftTrigger, "R2": GCInputRightTrigger,
        "L3": GCInputLeftThumbstickButton, "R3": GCInputRightThumbstickButton,
        "Options": GCInputButtonOptions, "Menu": GCInputButtonMenu,
        "Home": GCInputButtonHome, "Share": GCInputButtonShare,
    ]

    /// The element behind a physical key, d-pad directions included. Typed
    /// property first, then by name, so pads with no extendedGamepad work too.
    static func button(_ key: String, on controller: GCController) -> GCControllerButtonInput? {
        if let dpad = directionPad(on: controller) {
            switch key {
            case "Up": return dpad.up
            case "Down": return dpad.down
            case "Left": return dpad.left
            case "Right": return dpad.right
            default: break
            }
        }
        let gamepad = controller.extendedGamepad
        let typed: GCControllerButtonInput?
        switch key {
        case "A": typed = gamepad?.buttonA
        case "B": typed = gamepad?.buttonB
        case "X": typed = gamepad?.buttonX
        case "Y": typed = gamepad?.buttonY
        case "L1": typed = gamepad?.leftShoulder
        case "R1": typed = gamepad?.rightShoulder
        case "L2": typed = gamepad?.leftTrigger
        case "R2": typed = gamepad?.rightTrigger
        case "L3": typed = gamepad?.leftThumbstickButton
        case "R3": typed = gamepad?.rightThumbstickButton
        case "Options": typed = gamepad?.buttonOptions
        case "Menu": typed = gamepad?.buttonMenu
        case "Home": typed = gamepad?.buttonHome
        default: typed = nil
        }
        if let typed { return typed }
        return elementName[key].flatMap { controller.physicalInputProfile.buttons[$0] }
    }

    /// Every button this controller actually has, paired with its mapping key.
    static func buttons(on controller: GCController) -> [(key: String, button: GCControllerButtonInput)] {
        INDSPhysicalKey.all.compactMap { key in
            button(key, on: controller).map { (key, $0) }
        }
    }

    static func directionPad(on controller: GCController) -> GCControllerDirectionPad? {
        controller.extendedGamepad?.dpad
            ?? controller.physicalInputProfile.dpads[GCDirectionPadElementName.directionPad.rawValue]
    }

    static func thumbstick(on controller: GCController) -> GCControllerDirectionPad? {
        if let stick = controller.extendedGamepad?.leftThumbstick { return stick }

        let profile = controller.physicalInputProfile
        if let stick = profile.dpads[GCDirectionPadElementName.leftThumbstick.rawValue] { return stick }

        // iOS 26 added a generic name for devices with a single stick and no
        // left/right distinction — the same devices that get no extendedGamepad.
        // It resolves to nil on a normal pad, so this costs those nothing.
        if #available(iOS 26.0, *) {
            return profile.dpads[GCDirectionPadElementName.thumbstick.rawValue]
        }
        return nil
    }

    /// What iOS reports for this controller, for the mapping screen to show.
    /// A pad whose buttons do nothing is otherwise a dead end for support.
    static func detectedNames(on controller: GCController) -> [String] {
        let profile = controller.physicalInputProfile
        return (Array(profile.buttons.keys) + Array(profile.dpads.keys)).sorted()
    }
}

protocol INDSGamepadManagerDelegate: AnyObject {
    func gamepadManager(_ manager: INDSGamepadManager, setButton button: INDSButton, pressed: Bool)
    func gamepadManager(_ manager: INDSGamepadManager, perform action: INDSControllerAppAction)
    func gamepadManager(_ manager: INDSGamepadManager, setFastForwardActive active: Bool)
    func gamepadManagerDidChangeConnection(_ manager: INDSGamepadManager, connected: Bool)
}


final class INDSGamepadManager {

    weak var delegate: INDSGamepadManagerDelegate?

    private(set) var current: GCController?

    /// How many of the current pad's inputs could be wired. A controller that
    /// drives nothing must not count as connected: hiding the on-screen
    /// controls for one leaves no way to play at all.
    private var wiredInputCount = 0
    var isConnected: Bool { current != nil && wiredInputCount > 0 }

    private var observers: [NSObjectProtocol] = []

    /// What each physical key did when it went down, so its release undoes
    /// exactly that even if the mapping changed in between.
    private var pressedTargets: [String: INDSMappingTarget] = [:]
    private var stickDirections: Set<INDSButton> = []
    /// DS buttons currently reported as pressed: the union of the stick and
    /// every held key mapped to a DS button. Two keys on the same DS button
    /// (L1 and L2 both on L) release it only when the last one lets go.
    private var heldButtons: Set<INDSButton> = []
    private var fastForwardKeys: Set<String> = []
    private var fastForwardStartedAt: Date?
    private var menuEscape: DispatchWorkItem?

    /// The manager whose handlers are currently installed on the shared
    /// `GCController`. Two managers can overlap briefly (one game screen torn
    /// down after the next was set up); the older one must not clear the
    /// handlers the newer one just installed.
    private static weak var handlerOwner: INDSGamepadManager?

    private static let stickThreshold: Float = 0.5
    /// Shorter than this, a Fast Forward hold counts as a tap: next speed.
    private static let fastForwardTap: TimeInterval = 0.25
    /// Holding a remapped Menu this long opens the pause menu.
    private static let menuEscapeDelay: TimeInterval = 0.6

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.attach(controller)
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.handleDisconnect(of: controller)
        })
        // A button held while the app is suspended never delivers its
        // release. Let go of everything on the way out.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.releaseHeldInputs()
        })
        // Home/Share go back to iOS when they lose their job, and vice versa.
        observers.append(center.addObserver(forName: .indsControllerMappingDidChange, object: nil,
                                            queue: .main) { [weak self] _ in
            guard let self, let current = self.current, Self.handlerOwner === self else { return }
            Self.applySystemGestures(on: current)
        })

        // Connect notifications only fire for NEW connections: a pad paired
        // before the app launched needs this initial scan.
        if let existing = GCController.controllers().first {
            attach(existing)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let current { releaseAllInputs(current) }
    }

    // MARK: - Connect / disconnect

    private func attach(_ controller: GCController) {
        if let current {
            // Keep the pad in use — unless it wired nothing, in which case a
            // usable one replacing it is the only way to get input at all.
            guard wiredInputCount == 0, controller !== current else { return }
            releaseAllInputs(current)
        }
        current = controller
        INDSControllerMappingStore.activateProfile(for: controller)
        configureHandlers(controller)
        delegate?.gamepadManagerDidChangeConnection(self, connected: isConnected)
    }

    private func handleDisconnect(of controller: GCController) {
        guard controller === current else { return }
        releaseAllInputs(controller)
        current = nil
        delegate?.gamepadManagerDidChangeConnection(self, connected: false)

        if let next = GCController.controllers().first(where: { $0 !== controller }) {
            attach(next)
        }
    }

    private func releaseAllInputs(_ controller: GCController) {
        if Self.handlerOwner === self {
            Self.handlerOwner = nil
            controller.controllerPausedHandler = nil
            INDSControllerElements.thumbstick(on: controller)?.valueChangedHandler = nil
            for (_, button) in INDSControllerElements.buttons(on: controller) {
                button.valueChangedHandler = nil
                button.preferredSystemGestureState = .enabled
            }
        }
        wiredInputCount = 0
        releaseHeldInputs()
    }

    /// Reports a release for everything currently down without unwiring the
    /// pad — the disconnect path and the background path both end here.
    private func releaseHeldInputs() {
        menuEscape?.cancel()
        menuEscape = nil
        pressedTargets = [:]
        stickDirections = []
        syncHeldButtons()
        if !fastForwardKeys.isEmpty {
            fastForwardKeys = []
            fastForwardStartedAt = nil
            delegate?.gamepadManager(self, setFastForwardActive: false)
        }
    }

    // MARK: - Handler wiring

    private func configureHandlers(_ controller: GCController) {
        Self.handlerOwner = self
        wiredInputCount = 0

        if let stick = INDSControllerElements.thumbstick(on: controller) {
            wiredInputCount += 1
            stick.valueChangedHandler = { [weak self] _, x, y in
                self?.setStickDirections(Self.directions(fromStickX: x, y: y))
            }
        }

        let buttons = INDSControllerElements.buttons(on: controller)
        for (key, button) in buttons {
            wiredInputCount += 1
            button.valueChangedHandler = { [weak self] _, _, pressed in
                self?.handlePhysical(key, pressed: pressed)
            }
        }

        // Only pads that don't expose Menu as a button get the legacy pause
        // callback; wiring both would make one press do two things.
        if !buttons.contains(where: { $0.key == "Menu" }) {
            controller.controllerPausedHandler = { [weak self] _ in
                guard let self else { return }
                self.delegate?.gamepadManager(self, perform: .pause)
            }
        } else {
            controller.controllerPausedHandler = nil
        }
        Self.applySystemGestures(on: controller)

        if wiredInputCount == 0 {
            NSLog("[INDSGamepadManager] %@ exposes no input this app can read: %@",
                  controller.vendorName ?? "controller",
                  INDSControllerElements.detectedNames(on: controller).joined(separator: ", "))
        }
    }

    /// Home/Share/Menu belong to iOS (Games app, screenshots) unless the user
    /// gave them a job here.
    static func applySystemGestures(on controller: GCController) {
        let mapping = INDSControllerMappingStore.activeMapping()
        for key in ["Home", "Share", "Menu"] {
            let assigned = INDSControllerMappingStore.target(forPhysical: key, in: mapping) != .none
            INDSControllerElements.button(key, on: controller)?.preferredSystemGestureState = assigned ? .disabled : .enabled
        }
    }

    // MARK: - Physical input -> mapping target

    private func handlePhysical(_ key: String, pressed: Bool) {
        // Edge only: an analog trigger reports every value change, most of
        // them with `pressed` unchanged.
        guard (pressedTargets[key] != nil) != pressed else { return }

        if pressed {
            let mapping = INDSControllerMappingStore.activeMapping()
            let target = INDSControllerMappingStore.target(forPhysical: key, in: mapping)
            pressedTargets[key] = target
            if key == "Menu" && INDSMappingLogic.menuEscapeApplies(mapping) {
                armMenuEscape()
            }
            pressAction(target, key: key)
        } else {
            let target = pressedTargets.removeValue(forKey: key) ?? .none
            if key == "Menu" {
                menuEscape?.cancel()
                menuEscape = nil
            }
            releaseAction(target, key: key)
        }
        syncHeldButtons()
    }

    private func pressAction(_ target: INDSMappingTarget, key: String) {
        switch target {
        case .fastForward:
            if fastForwardKeys.isEmpty {
                fastForwardStartedAt = Date()
                delegate?.gamepadManager(self, setFastForwardActive: true)
            }
            fastForwardKeys.insert(key)
        default:
            // DS buttons go through syncHeldButtons; the rest fire once.
            guard let action = target.appAction else { return }
            delegate?.gamepadManager(self, perform: action)
        }
    }

    private func releaseAction(_ target: INDSMappingTarget, key: String) {
        guard target == .fastForward, fastForwardKeys.remove(key) != nil, fastForwardKeys.isEmpty else { return }
        delegate?.gamepadManager(self, setFastForwardActive: false)
        if let start = fastForwardStartedAt, Date().timeIntervalSince(start) < Self.fastForwardTap {
            delegate?.gamepadManager(self, perform: .nextFastForwardSpeed)
        }
        fastForwardStartedAt = nil
    }

    private func armMenuEscape() {
        menuEscape?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pressedTargets["Menu"] != nil else { return }
            self.menuEscape = nil
            self.delegate?.gamepadManager(self, perform: .pause)
        }
        menuEscape = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuEscapeDelay, execute: item)
    }

    // MARK: - DS buttons (mapped keys + left stick)

    private func setStickDirections(_ next: Set<INDSButton>) {
        guard stickDirections != next else { return }
        stickDirections = next
        syncHeldButtons()
    }

    private func syncHeldButtons() {
        let next = stickDirections.union(pressedTargets.values.compactMap(\.indsButton))
        guard next != heldButtons else { return }
        let before = heldButtons
        heldButtons = next
        for button in before.subtracting(next) { delegate?.gamepadManager(self, setButton: button, pressed: false) }
        for button in next.subtracting(before) { delegate?.gamepadManager(self, setButton: button, pressed: true) }
    }

    private static func directions(fromStickX x: Float, y: Float) -> Set<INDSButton> {
        var result: Set<INDSButton> = []
        if y > stickThreshold { result.insert(.up) }
        if y < -stickThreshold { result.insert(.down) }
        if x < -stickThreshold { result.insert(.left) }
        if x > stickThreshold { result.insert(.right) }
        return result
    }
}
