//
//  INDSKeyboardManager.swift
//  eDuo
//
//  Ported and adapted from iGBA's KeyboardController.m: routes
//  a physical keyboard (GCKeyboard, iOS 14+) to the engine through a
//  delegate, coexisting with the on-screen overlay and any connected gamepad
//  (does not take exclusive ownership of input, does not hide the overlay).
//
//  GOTCHA (ported verbatim from KeyboardController.m): GCKeyCode's static
//  members (`.keyA`, `.upArrow`, …) are runtime globals, not compile-time
//  constants, so they cannot be used as `switch` case labels — this uses
//  plain `if`/`==` checks throughout, exactly like the ObjC reference.
//
//  Fixed v1 key mapping (no remap UI — remapping is gamepad-only for now;
//  both directions below are always active):
//    D-Pad                 : Arrow keys ONLY (see collision note)
//    A (DS)                : X
//    B (DS)                : Z
//    X (DS)                : S
//    Y (DS)                : A
//    L                     : Q
//    R                     : W
//    Start                 : Return / Keypad Enter
//    Select                : Right Shift
//    Pause                 : P or Escape
//
//  Collision note: the brief's starting point was "arrows AND WASD both
//  drive the d-pad" (iGBA's own scheme) PLUS S→X, A→Y, Q→L, W→R. But S/A/W
//  are also WASD's down/left/up — three collisions. Resolved by dropping
//  WASD from the d-pad entirely and keeping ONLY the arrow keys for
//  movement; once WASD is fully freed, Q/W have nothing left to collide
//  with, so the plain Q=L / W=R pair from the brief is used as-is (no need
//  for the suggested 1/2 or Q/E fallback).
//

import GameController
import UIKit

protocol INDSKeyboardManagerDelegate: AnyObject {
    func keyboardManager(_ manager: INDSKeyboardManager, setButton button: INDSButton, pressed: Bool)
    func keyboardManagerDidRequestPause(_ manager: INDSKeyboardManager)
}

final class INDSKeyboardManager {

    weak var delegate: INDSKeyboardManagerDelegate?

    private var observers: [NSObjectProtocol] = []

    /// Logical DS buttons currently held, ref-counted. Two physical keys can
    /// map to the same DS button (Return and Keypad Enter both → Start), so
    /// releasing one of them while the other is still held must NOT report a
    /// release to the delegate. (`NSCountedSet`-equivalent, in plain Swift.)
    private var activeLogicalButtons: [INDSButton: Int] = [:]

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let keyboard = (note.object as? GCKeyboard) ?? GCKeyboard.coalesced else { return }
            self?.hook(keyboard)
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            // All physical keys went away with the keyboard — release
            // anything still held so the emulator doesn't get stuck moving.
            self?.releaseAllActiveButtons()
        })
        // A key held while the app is suspended never delivers its key-up.
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.releaseAllActiveButtons()
        })

        if let keyboard = GCKeyboard.coalesced {
            hook(keyboard)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        releaseAllActiveButtons()
    }

    private func hook(_ keyboard: GCKeyboard) {
        guard let input = keyboard.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            self?.handle(keyCode: keyCode, pressed: pressed)
        }
    }

    // MARK: - Key events

    private func handle(keyCode: GCKeyCode, pressed: Bool) {
        if isPauseKey(keyCode) {
            // Discrete action, routed separately from the held-button
            // bookkeeping below — fires once, on key-down.
            if pressed { delegate?.keyboardManagerDidRequestPause(self) }
            return
        }

        guard let button = dsButton(for: keyCode) else { return }
        setLogical(button, pressed: pressed)
    }

    private func isPauseKey(_ keyCode: GCKeyCode) -> Bool {
        keyCode == .escape || keyCode == .keyP
    }

    /// See the GOTCHA note at the top of this file: if/else, not switch.
    private func dsButton(for keyCode: GCKeyCode) -> INDSButton? {
        if keyCode == .upArrow { return .up }
        if keyCode == .downArrow { return .down }
        if keyCode == .leftArrow { return .left }
        if keyCode == .rightArrow { return .right }

        if keyCode == .keyX { return INDSButton(rawValue: 0) }   // A
        if keyCode == .keyZ { return INDSButton(rawValue: 1) }   // B
        if keyCode == .keyS { return INDSButton(rawValue: 10) }  // X
        if keyCode == .keyA { return INDSButton(rawValue: 11) }  // Y

        if keyCode == .keyQ { return INDSButton(rawValue: 9) }   // L
        if keyCode == .keyW { return INDSButton(rawValue: 8) }   // R

        if keyCode == .returnOrEnter || keyCode == .keypadEnter { return .start }
        if keyCode == .rightShift { return .select }

        return nil
    }

    private func setLogical(_ button: INDSButton, pressed: Bool) {
        if pressed {
            let wasActive = (activeLogicalButtons[button] ?? 0) > 0
            activeLogicalButtons[button, default: 0] += 1
            if !wasActive {
                delegate?.keyboardManager(self, setButton: button, pressed: true)
            }
        } else {
            guard let count = activeLogicalButtons[button], count > 0 else { return }
            if count == 1 {
                activeLogicalButtons.removeValue(forKey: button)
                delegate?.keyboardManager(self, setButton: button, pressed: false)
            } else {
                activeLogicalButtons[button] = count - 1
            }
        }
    }

    private func releaseAllActiveButtons() {
        guard !activeLogicalButtons.isEmpty else { return }
        let held = Array(activeLogicalButtons.keys)
        activeLogicalButtons.removeAll()
        for button in held { delegate?.keyboardManager(self, setButton: button, pressed: false) }
    }
}
