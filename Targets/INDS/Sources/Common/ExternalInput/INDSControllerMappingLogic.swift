//
//  INDSControllerMappingLogic.swift
//  eDuo
//
//  Pure controller-mapping logic, ported from iGBA (ControllerMappingLogic):
//  which physical buttons exist, what each one can do, how saved data is
//  migrated, which conflicts exist and at what rate turbo fires. Deliberately
//  free of UIKit and GameController: scripts/controller_mapping_check.sh
//  compiles it standalone with swiftc and tests it.
//
//  The saved format does NOT change: `[physical key: raw INDSMappingTarget]`.
//  Only keys (d-pad, L3, R3, Menu, Home, Share) and targets (fast forward
//  on/off, turbo on/off, rewind) are added, so a mapping saved by an
//  earlier version opens as-is.
//

import Foundation

/// What a physical button can do. DS buttons have the same values as
/// `INDSButton` (A=0 … Y=11); actions start at 50.
/// Do NOT renumber: they are persisted in UserDefaults.
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
        /// Hold = fast; a short tap steps to the next speed.
    case fastForward = 55
        /// One tap turns it on, another turns it off.
    case fastForwardToggle = 56
        /// Turns turbo on or off for the chosen buttons.
    case turboToggle = 57
    case rewind = 58

    case none = 99

    var id: Int { rawValue }

    var isDSButton: Bool { (0...11).contains(rawValue) }
    var isDirection: Bool { [.up, .down, .left, .right].contains(self) }

    static let consoleOrder: [INDSMappingTarget] = [.up, .down, .left, .right,
                                                    .a, .b, .x, .y, .l, .r, .start, .select]
    static let emulatorOrder: [INDSMappingTarget] = [.pause, .fastForward, .fastForwardToggle,
                                                     .turboToggle, .rewind, .quickSave, .quickLoad,
                                                     .cycleScreenLayout, .swapScreens]
        /// Buttons with turbo. Not directions or Start/Select: nobody wants a menu
        /// that opens and closes ten times a second.
    static let turboCapable: [INDSMappingTarget] = [.a, .b, .x, .y, .l, .r]
}

/// Physical keys, as stored by the mapping.
enum INDSPhysicalKey {
    static let directions = ["Up", "Down", "Left", "Right"]
    static let all: [String] = directions + ["A", "B", "X", "Y",
                                             "L1", "R1", "L2", "R2", "L3", "R3",
                                             "Options", "Menu", "Home", "Share"]
}

enum INDSMappingLogic {

        /// "DS layout": GameController calls the face buttons A/B/X/Y by position
        /// (south/east/west/north) on every controller, and on a DS the south one
        /// is B. So an Xbox's bottom button acts as B, where it sits on a real DS.
        /// L2/R2 = Select/Start (a regular pad has no more front buttons), Options and Menu pause.
    static let defaultMapping: [String: Int] = [
        "Up": INDSMappingTarget.up.rawValue,
        "Down": INDSMappingTarget.down.rawValue,
        "Left": INDSMappingTarget.left.rawValue,
        "Right": INDSMappingTarget.right.rawValue,
        "A": INDSMappingTarget.b.rawValue,
        "B": INDSMappingTarget.a.rawValue,
        "X": INDSMappingTarget.y.rawValue,
        "Y": INDSMappingTarget.x.rawValue,
        "L1": INDSMappingTarget.l.rawValue,
        "R1": INDSMappingTarget.r.rawValue,
        "L2": INDSMappingTarget.select.rawValue,
        "R2": INDSMappingTarget.start.rawValue,
        "L3": INDSMappingTarget.none.rawValue,
        "R3": INDSMappingTarget.none.rawValue,
        "Options": INDSMappingTarget.pause.rawValue,
        "Menu": INDSMappingTarget.pause.rawValue,
                // Nothing by default: iOS uses them (Games app, screenshots) and they are only
                // requested from the system when someone assigns them something.
        "Home": INDSMappingTarget.none.rawValue,
        "Share": INDSMappingTarget.none.rawValue,
    ]

    private static let validTargets = Set(INDSMappingTarget.allCases.map(\.rawValue))

        /// The saved data, sanitized: every expected key present, invalid values and
        /// unknown keys dropped. Idempotent.
    static func migrate(_ stored: [String: Int]) -> [String: Int] {
        var out = defaultMapping
        for (key, value) in stored where defaultMapping[key] != nil && validTargets.contains(value) {
            out[key] = value
        }
        return out
    }

        /// Assigns and counts what was left without a button, to offer "undo".
    static func assign(_ target: INDSMappingTarget, to key: String,
                       in mapping: [String: Int]) -> (mapping: [String: Int], displaced: INDSMappingTarget?) {
        var out = mapping
        let previous = out[key].flatMap(INDSMappingTarget.init(rawValue:))
        out[key] = target.rawValue
        guard let previous, previous != .none, previous != target else { return (out, nil) }
                // Only "displaced" if no other button reaches it any more.
        return (out, out.values.contains(previous.rawValue) ? nil : previous)
    }

        /// Physical keys that perform `target`, in on-screen order.
    static func keys(for target: INDSMappingTarget, in mapping: [String: Int]) -> [String] {
        INDSPhysicalKey.all.filter { mapping[$0] == target.rawValue }
    }

        /// Does holding Menu open pause even if it has another job? Only when
        /// no other button opens it and what Menu does is not a held action
        /// (with hold-to-fast-forward there, pause would trigger mid-run).
    static func menuEscapeApplies(_ mapping: [String: Int]) -> Bool {
        let target = INDSMappingTarget(rawValue: mapping["Menu"] ?? INDSMappingTarget.pause.rawValue) ?? .none
        if target == .pause { return false }
        if mapping.contains(where: { $0.key != "Menu" && $0.value == INDSMappingTarget.pause.rawValue }) { return false }
        return target != .fastForward && !target.isDSButton
    }

        /// Essentials that no button reaches. The d-pad only counts if the
        /// controller has no stick: the left stick always moves.
    static func unreachableEssentials(_ mapping: [String: Int], hasStick: Bool) -> [INDSMappingTarget] {
        let reached = Set(mapping.values)
        var needed: [INDSMappingTarget] = [.a, .b, .start]
        if !menuEscapeApplies(mapping) { needed.append(.pause) }
        if !hasStick { needed = [.up, .down, .left, .right] + needed }
        return needed.filter { !reached.contains($0.rawValue) }
    }
}

/// Turbo rate. The DS reads the keypad 60 times a second: 30/s is
/// one frame pressed and one released, the most a game can see.
enum INDSTurboPattern {
    static let rates = [5, 8, 10, 12, 15, 20, 30]
        /// 15/s was the fixed rate before.
    static let defaultRate = 15

        /// The first pulse holds this long before it starts to flicker. Without it, at
        /// 15/s a normal tap (~100 ms) crossed ON-OFF-ON and the game saw two
        /// presses: with turbo on A/B, "one press counts as two"
        /// (user report, Xbox controller). A tap is one press;
        /// holding keeps firing.
    static let firstPulseHold: TimeInterval = 0.15

        /// Is the turbo button pressed `elapsed` seconds after it was pressed?
        /// The same calculation the `NDSRomViewController` timer does.
    static func isOn(elapsed: TimeInterval, rate: Int) -> Bool {
        guard elapsed >= firstPulseHold else { return true }
        let phase = 1.0 / Double(2 * clampedRate(rate))
        return Int((elapsed - firstPulseHold) / phase) % 2 == 1
    }

    static func clampedRate(_ rate: Int) -> Int {
        rates.contains(rate) ? rate : defaultRate
    }

        /// The next or previous step of the ladder, without overflowing.
    static func step(_ rate: Int, by delta: Int) -> Int {
        let index = rates.firstIndex(of: clampedRate(rate)) ?? 4
        return rates[max(0, min(rates.count - 1, index + delta))]
    }
}

/// Position → pressed directions, with hysteresis: a direction engages when
/// `press` is crossed and is only released on returning below `release`.
///
/// Without this, a thumb resting right on a zone's edge (the d-pad arrow next to
/// the dead centre, or the stick at half travel) jitters a point up and down past
/// the threshold, and every jitter is a release and a re-press:
/// one press comes out as two (user report). Per axis, as
/// before: a diagonal is still two directions.
///
/// `x` grows to the right and `y` upward, both in -1…1.
enum INDSDirectionHysteresis {
        /// Touch d-pad: the central third is neutral, like the classic 3×3 grid;
        /// once pressed, it holds until 0.2.
    static let touchPress = 1.0 / 3.0
    static let touchRelease = 0.2
        /// Controller left stick: engages at half travel, releases at 0.35.
    static let stickPress = 0.5
    static let stickRelease = 0.35

    static func directions(x: Double, y: Double, held: Set<INDSMappingTarget>,
                           press: Double, release: Double) -> Set<INDSMappingTarget> {
        func on(_ value: Double, _ direction: INDSMappingTarget) -> Bool {
            value > (held.contains(direction) ? release : press)
        }
        var result: Set<INDSMappingTarget> = []
        if on(y, .up) { result.insert(.up) }
        if on(-y, .down) { result.insert(.down) }
        if on(-x, .left) { result.insert(.left) }
        if on(x, .right) { result.insert(.right) }
        return result
    }
}

extension INDSDirectionHysteresis {
    /// What the controller's left stick turns into on the D-pad. The DS has no
    /// analog, so the stick stands in for the D-pad there. A 3DS game reads the
    /// stick as the Circle Pad and the D-pad separately: synthesizing D-pad
    /// presses on top made one stick push move both. On 3DS
    /// it is off unless the user opted in ("Left Stick Also Moves D-Pad").
    static func stickDPad(x: Double, y: Double, held: Set<INDSMappingTarget>,
                          stickDrivesDPad: Bool) -> Set<INDSMappingTarget> {
        guard stickDrivesDPad else { return [] }
        return directions(x: x, y: y, held: held, press: stickPress, release: stickRelease)
    }
}

/// Merges the three sources (touch, controller, keyboard) before the core.
///
/// - A DS button stays pressed while any source holds it: previously, releasing
///   the same button from another source released it in the core, and if a
///   physical press arrived through two out-of-phase paths the game saw two.
/// - Physical sources (`graced`) release with a `releaseGrace` margin: a
///   release-and-press faster than that is not something a finger does (mashing a button
///   leaves ≥40 ms between release and re-press), it is a bounce or a system
///   duplicate, and it stays a single press. Pressing is never delayed.
///
/// `button` is INDSButton's raw value; `source` any stable label.
struct INDSPressMerger {
    static let releaseGrace: TimeInterval = 0.025

    enum Output: Equatable {
        case none
        case press
        /// Release in the core after `after` seconds if `releaseFired` confirms it.
        case release(after: TimeInterval, token: Int)
    }

    private var holders: [Int: Set<String>] = [:]
    /// Buttons with a scheduled release, with their token (the last one wins).
    private var pending: [Int: Int] = [:]
    private var nextToken = 0

    mutating func handle(button: Int, pressed: Bool, source: String, graced: Bool) -> Output {
        var set = holders[button] ?? []
        if pressed {
            let wasDown = !set.isEmpty || pending[button] != nil
            set.insert(source)
            holders[button] = set
            pending[button] = nil   // comes back before the margin: it was never released
            return wasDown ? .none : .press
        }
        guard set.remove(source) != nil else { return .none }
        holders[button] = set.isEmpty ? nil : set
        guard set.isEmpty else { return .none }
        nextToken += 1
        pending[button] = nextToken
        return .release(after: graced ? Self.releaseGrace : 0, token: nextToken)
    }

    /// true if the release scheduled with `token` is still pending.
    mutating func releaseFired(button: Int, token: Int) -> Bool {
        guard pending[button] == token, holders[button] == nil else { return false }
        pending[button] = nil
        return true
    }
}
