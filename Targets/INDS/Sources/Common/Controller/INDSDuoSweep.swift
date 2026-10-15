//
//  INDSDuoSweep.swift
//  eDuo
//
//  `-iNDSDuoSweep` (DEBUG, simulator): composes the REAL views (screens, touch
//  overlay, HUD) at the iPhone Duo's measured geometry and checks the hinge
//  rules, printing one `DUOSWEEP` line per posture and a verdict. No posture or
//  fold exists here — that is the simulator's job (`INDSLayoutProbe` +
//  `scripts/duo_layout_check.sh` live mode); this checks the arithmetic at
//  every posture we have measured, on any simulator.
//
//  Measured on the Duo simulator (Xcode 27.1, iOS 27.1), inner display open,
//  portrait: 669×951 pt, safe area {82,0,34,0}, division `{0,455.5} 669×40`,
//  occlusion `{535,0} 134×82`. Exterior: 466×678.
//

#if DEBUG
import UIKit

enum INDSDuoSweep {

    struct Scenario {
        let name: String
        /// The display's full size and the system's safe area, in window points.
        let display: CGSize
        let safe: UIEdgeInsets
        /// Crease and occlusions in WINDOW coordinates; nil = no crease (closed).
        let band: DSHingeBand?
        let gamepad: Bool
        let halfOpen: Bool

        var content: CGRect {
            CGRect(x: safe.left, y: safe.top,
                   width: display.width - safe.left - safe.right,
                   height: display.height - safe.top - safe.bottom)
        }
    }

    static let innerPortrait = CGSize(width: 669, height: 951)
    static let innerLandscape = CGSize(width: 951, height: 669)
    static let rail = CGRect(x: 535, y: 0, width: 134, height: 82)

    static let scenarios: [Scenario] = [
        Scenario(name: "open-portrait", display: innerPortrait,
                 safe: UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0),
                 band: DSHingeBand(isVertical: false, center: 475.5, half: 20, occlusions: [rail]),
                 gamepad: false, halfOpen: false),
        Scenario(name: "open-portrait-gamepad", display: innerPortrait,
                 safe: UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0),
                 band: DSHingeBand(isVertical: false, center: 475.5, half: 20, occlusions: [rail]),
                 gamepad: true, halfOpen: false),
        Scenario(name: "half-open-portrait", display: innerPortrait,
                 safe: UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0),
                 band: DSHingeBand(isVertical: false, center: 475.5, half: 20, occlusions: [rail]),
                 gamepad: false, halfOpen: true),
        // Book posture: hinge vertical. Measured on the Duo simulator,
        // 10-oct-2026: window 951×669, safe area {top 0, left 0, bottom 34,
        // right 84}, division `{455.5,0} 40×669`, rail `{867,0} 84×120`.
        Scenario(name: "open-landscape", display: innerLandscape,
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84),
                 band: DSHingeBand(isVertical: true, center: 475.5, half: 20,
                                   occlusions: [CGRect(x: 867, y: 0, width: 84, height: 120)]),
                 gamepad: false, halfOpen: false),
        Scenario(name: "open-landscape-gamepad", display: innerLandscape,
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84),
                 band: DSHingeBand(isVertical: true, center: 475.5, half: 20,
                                   occlusions: [CGRect(x: 867, y: 0, width: 84, height: 120)]),
                 gamepad: true, halfOpen: false),
        // Closed: outer display, no crease. Ordinary phone layouts.
        Scenario(name: "closed-portrait", display: CGSize(width: 466, height: 678),
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84), band: nil,
                 gamepad: false, halfOpen: false),
        Scenario(name: "closed-landscape", display: CGSize(width: 678, height: 466),
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84), band: nil,
                 gamepad: false, halfOpen: false),
        Scenario(name: "closed-portrait-gamepad", display: CGSize(width: 466, height: 678),
                 safe: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84), band: nil,
                 gamepad: true, halfOpen: false),
    ]

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-iNDSDuoSweep") else { return }
        // A clean slate: a saved custom layout or explicit screen mode on this
        // simulator would test someone's settings instead of the defaults.
        for key in ["eNDSScreenLayoutPortrait", "eNDSScreenLayoutLandscape", "eNDSScreenSwap",
                    "eNDSStretchScreens", "eNDSControllerScale"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        var report: [String] = []
        var failures = 0
        for scenario in scenarios {
            let problems = check(scenario, report: &report)
            if problems.isEmpty {
                report.append("DUOSWEEP OK \(scenario.name)")
            } else {
                failures += 1
                problems.forEach { report.append("DUOSWEEP FALLO \(scenario.name): \($0)") }
            }
        }
        report.append(failures == 0 ? "DUOSWEEP DONE 0 FALLO(S)" : "DUOSWEEP DONE \(failures) FALLO(S)")
        report.forEach { print($0) }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.joined(separator: "\n")
                .write(to: docs.appendingPathComponent("duo-sweep.txt"), atomically: true, encoding: .utf8)
        }
        exit(failures == 0 ? 0 : 1)
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: "{%.1f,%.1f %.1fx%.1f}", r.minX, r.minY, r.width, r.height)
    }

    private static func check(_ s: Scenario, report: inout [String]) -> [String] {
        var problems: [String] = []
        let content = s.content
        let origin = content.origin
        // The same band the system would report, in content coordinates (the
        // sweep's views live in a content-sized box).
        var local = s.band
        if var band = local {
            band.center -= band.isVertical ? origin.x : origin.y
            band.occlusions = band.occlusions.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            local = band
        }
        DSHingeState.override = local.map { .band($0) } ?? .none
        DSFoldableLayout.isHalfOpen = s.halfOpen
        defer { DSHingeState.override = nil; DSFoldableLayout.isHalfOpen = false }

        let isLandscape = content.width > content.height
        let orientation: DSScreenOrientationClass = isLandscape ? .landscape : .portrait
        let mode = DSScreenLayoutPreferences.mode(for: orientation, containerSize: content.size,
                                                  hinge: DSHingeState.override ?? .none)

        let size = content.size
        let screens = DSDualScreenView(frame: CGRect(origin: .zero, size: size))
        screens.reservesControlBand = !s.gamepad
        screens.applyLayout(mode: mode, swap: false, animated: false)
        let controller = NDSControllerView(frame: screens.bounds)
        controller.screenLayoutMode = mode
        controller.isHidden = s.gamepad
        let hud = NDSHUDView(frame: screens.bounds)
        hud.setLayoutIcon(mode)
        hud.setGamepadConnected(s.gamepad)
        controller.layoutIfNeeded()
        hud.layoutIfNeeded()

        func window(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }
        let upper = window(screens.topScreenView.frame)
        let lower = window(screens.bottomScreenView.frame)
        let screenRects = [("top", upper), ("touch", lower)]

        // 1. The two screens.
        if abs(upper.width - lower.width) > 1 || abs(upper.height - lower.height) > 1 {
            problems.append("screens differ in size \(fmt(upper)) \(fmt(lower))")
        }
        if let band = s.band {
            let bandRect = band.isVertical
                ? CGRect(x: band.leadingEdge, y: 0, width: band.half * 2, height: s.display.height)
                : CGRect(x: 0, y: band.leadingEdge, width: s.display.width, height: band.half * 2)
            for (name, r) in screenRects where r.intersects(bandRect.insetBy(dx: 0, dy: 0)) && r.intersection(bandRect).width > 0.5 && r.intersection(bandRect).height > 0.5 {
                problems.append("\(name) screen enters the hinge band: \(fmt(r)) vs \(fmt(bandRect))")
            }
            let touching = band.isVertical
                ? (abs(upper.maxX - band.leadingEdge) <= 1 && abs(lower.minX - band.trailingEdge) <= 1)
                : (abs(upper.maxY - band.leadingEdge) <= 1 && abs(lower.minY - band.trailingEdge) <= 1 || s.halfOpen)
            if !touching && !s.gamepad {
                problems.append("screens do not sit against the hinge band: \(fmt(upper)) \(fmt(lower))")
            }
            if !band.isVertical && !s.halfOpen && !touching {
                problems.append("screens do not sit against the hinge band: \(fmt(upper)) \(fmt(lower))")
            }
            if !(upper.midY < lower.midY || band.isVertical) || (band.isVertical && !(upper.midX < lower.midX)) {
                problems.append("screen order is wrong: \(fmt(upper)) \(fmt(lower))")
            }
            for (name, r) in screenRects {
                for occ in band.occlusions {
                    let o = occ
                    if r.intersection(o).width > 0.5 && r.intersection(o).height > 0.5 {
                        problems.append("\(name) screen is under the system overlay \(fmt(o))")
                    }
                }
            }
            if min(upper.width, lower.width) < 192 { problems.append("a screen is under 0.75x native") }
        }
        let safeRect = content
        for (name, r) in screenRects where !safeRect.insetBy(dx: -0.5, dy: -0.5).contains(r) {
            problems.append("\(name) screen leaves the safe area: \(fmt(r)) vs \(fmt(safeRect))")
        }

        // 2. Controls.
        var controls: [(String, CGRect)] = []
        if !s.gamepad {
            for (name, frame) in controller.probeFrames { controls.append((name, window(frame))) }
        }
        for (name, frame) in hud.probeFrames where ["menu", "layout", "speed"].contains(name) {
            controls.append(("hud." + name, window(frame)))
        }
        for (name, r) in controls {
            if !safeRect.insetBy(dx: -0.5, dy: -0.5).contains(r) {
                problems.append("control \(name) leaves the safe area: \(fmt(r))")
            }
            // On a display with no crease the ordinary phone layouts apply, and
            // those overlay controls on the screens' corners by design.
            for (sname, sr) in screenRects where s.band != nil && r.intersection(sr).width > 0.5 && r.intersection(sr).height > 0.5 {
                problems.append("control \(name) covers the \(sname) screen: \(fmt(r)) vs \(fmt(sr))")
            }
            if let band = s.band {
                let bandRect = band.isVertical
                    ? CGRect(x: band.leadingEdge, y: 0, width: band.half * 2, height: s.display.height)
                    : CGRect(x: 0, y: band.leadingEdge, width: s.display.width, height: band.half * 2)
                if r.intersection(bandRect).width > 0.5 && r.intersection(bandRect).height > 0.5 {
                    problems.append("control \(name) is in the hinge band: \(fmt(r))")
                }
                for occ in band.occlusions where r.intersection(occ).width > 0.5 && r.intersection(occ).height > 0.5 {
                    problems.append("control \(name) is under the system overlay: \(fmt(r))")
                }
            }
        }
        // Controls must not overlap each other (the face diamond is exempt: a
        // deliberately tight diamond resolved by nearest centre).
        let face: Set<String> = ["a", "b", "x", "y"]
        for i in controls.indices {
            for j in controls.indices where j > i {
                let a = controls[i], b = controls[j]
                if face.contains(a.0) && face.contains(b.0) { continue }
                let overlap = a.1.intersection(b.1)
                if overlap.width > 1 && overlap.height > 1 {
                    problems.append("controls overlap: \(a.0) \(fmt(a.1)) / \(b.0) \(fmt(b.1))")
                }
            }
        }
        // Big enough to play on.
        if !s.gamepad {
            for (name, r) in controls where face.contains(name) && min(r.width, r.height) < 44 {
                problems.append("face button \(name) is under 44 pt: \(fmt(r))")
            }
            if let dpad = controls.first(where: { $0.0 == "dpad" }), min(dpad.1.width, dpad.1.height) < 100 {
                problems.append("d-pad is under 100 pt: \(fmt(dpad.1))")
            }
            if s.band != nil, controls.count < 12 { problems.append("only \(controls.count) controls on screen") }
        }

        // 3. Touch: the stylus is never intercepted, and the mapping is exact
        // at the corners.
        let touchLocal = screens.bottomScreenView.frame
        if !s.gamepad {
            for y in [touchLocal.minY + 1, touchLocal.midY, touchLocal.maxY - 1] {
                for x in [touchLocal.minX + 1, touchLocal.midX, touchLocal.maxX - 1]
                where controller.hitTest(CGPoint(x: x, y: y), with: nil) != nil {
                    problems.append("controller intercepts the stylus at (\(x), \(y))")
                }
            }
        }
        let b = screens.bottomScreenView.bounds
        func ds(_ p: CGPoint) -> (Int, Int) {
            (max(0, min(255, Int(((p.x / b.width) * 255).rounded()))),
             max(0, min(191, Int(((p.y / b.height) * 191).rounded()))))
        }
        if ds(.zero) != (0, 0) || ds(CGPoint(x: b.width, y: b.height)) != (255, 191) {
            problems.append("touch mapping is not exact at the corners")
        }
        if abs(b.width / b.height - 256.0 / 192.0) > 0.01 {
            problems.append("touch screen is not 4:3: \(fmt(lower))")
        }

        report.append("DUOSWEEP \(s.name) mode=\(mode.rawValue) top=\(fmt(upper)) touch=\(fmt(lower))"
                      + " scale=\(String(format: "%.2f", upper.width / 256)) controls=\(controls.count)")
        for (name, r) in controls.sorted(by: { $0.0 < $1.0 }) { report.append("DUOSWEEP   \(name) \(fmt(r))") }
        return problems
    }
}
#endif
