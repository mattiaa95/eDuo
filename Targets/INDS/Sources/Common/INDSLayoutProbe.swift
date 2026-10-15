//
//  INDSLayoutProbe.swift
//  eDuo
//
//  `-eNDSLayoutProbe`: after the game's layout settles, writes where
//  everything is — in WINDOW coordinates, next to what the system says about
//  the display and the hinge — to `Documents/layout-probe.json`, and prints it
//  as one `LAYOUTPROBE {json}` line. `scripts/duo_layout_check.sh` reads it to
//  check the screens against the hinge band, the clock rail and the safe area,
//  and to check that the game kept running across a fold. Inert without the
//  flag.
//

import UIKit

#if DEBUG

enum INDSLayoutProbe {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-eNDSLayoutProbe")

    private static var pending: DispatchWorkItem?
    private static var sequence = 0
    private static var backgroundEvents = 0
    private static var observing = false

    /// Called from `viewDidLayoutSubviews`; coalesces to one write 0.6 s after
    /// the last layout pass, i.e. once an animation has settled.
    static func schedule(controller: UIViewController, dual: DSDualScreenView,
                         buttons: NDSControllerView, hud: NDSHUDView, core: MelonDSCoreBridge) {
        guard enabled else { return }
        observeLifecycle()
        pending?.cancel()
        let work = DispatchWorkItem { [weak controller, weak dual, weak buttons, weak hud, weak core] in
            guard let controller, let dual, let buttons, let hud, let core else { return }
            write(controller: controller, dual: dual, buttons: buttons, hud: hud, core: core)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func observeLifecycle() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { _ in backgroundEvents += 1 }
    }

    private static func rect(_ r: CGRect) -> [Double] {
        let values: [Double] = [r.minX, r.minY, r.width, r.height].map { Double($0) }
        return values.map { ($0 * 100).rounded() / 100 }
    }

    private static func write(controller: UIViewController, dual: DSDualScreenView,
                              buttons: NDSControllerView, hud: NDSHUDView, core: MelonDSCoreBridge) {
        guard let window = controller.view.window else { return }
        let view = controller.view!
        sequence += 1
        func inWindow(_ r: CGRect, of source: UIView) -> CGRect { source.convert(r, to: window) }

        var out: [String: Any] = [
            "seq": sequence,
            "time": Date().timeIntervalSince1970,
            "screen": rect(window.windowScene?.screen.bounds ?? .zero),
            "window": rect(window.bounds),
            "safeArea": [window.safeAreaInsets.top, window.safeAreaInsets.left,
                         window.safeAreaInsets.bottom, window.safeAreaInsets.right],
            "idiom": UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad",
            "halfOpen": DSFoldableLayout.isHalfOpen,
            "hingeState": String(describing: DSHingeState.resolve(for: view, content: view.bounds.inset(by: view.safeAreaInsets))),
            "gamepadHidesControls": buttons.isHidden,
            "swap": DSScreenLayoutPreferences.swapEnabled,
            "emulatedFrames": core.emulatedFrames,
            "coreRunning": core.running,
            "audioEngineRunning": core.audioEngineRunning,
            "backgroundEvents": backgroundEvents,
            "sceneState": window.windowScene?.activationState.rawValue ?? -1,
            "top": rect(inWindow(dual.topScreenView.frame, of: dual)),
            "touch": rect(inWindow(dual.bottomScreenView.frame, of: dual)),
            "topHidden": dual.topScreenView.isHidden,
            "touchHidden": dual.bottomScreenView.isHidden,
        ]
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            func regions(_ kind: UIView.ReservedRegion.Kind) -> [[String: Any]] {
                view.reservedRegions(kind: kind, options: [.includeInactive]).map {
                    ["frame": rect(view.convert($0.frame, to: window)), "active": $0.isActive]
                }
            }
            out["division"] = regions(.division)
            out["occlusion"] = regions(.occlusion)
        }
        #endif
        var controls: [String: [Double]] = [:]
        if !buttons.isHidden {
            for (name, frame) in buttons.probeFrames { controls[name] = rect(inWindow(frame, of: buttons)) }
        }
        for (name, frame) in hud.probeFrames { controls["hud." + name] = rect(inWindow(frame, of: hud)) }
        out["controls"] = controls
        // The system's own idea of the touch mapping: where a touch at the
        // touch screen's four corners and centre lands in DS pixels, using the
        // same arithmetic as `NDSRomViewController.updateTouch`.
        let b = dual.bottomScreenView.bounds
        func ds(_ p: CGPoint) -> [Int] {
            [max(0, min(255, Int(((p.x / b.width) * 255).rounded()))),
             max(0, min(191, Int(((p.y / b.height) * 191).rounded())))]
        }
        out["touchMap"] = ["topLeft": ds(.zero), "bottomRight": ds(CGPoint(x: b.width, y: b.height)),
                           "center": ds(CGPoint(x: b.midX, y: b.midY))]

        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print("LAYOUTPROBE " + json)
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: docs.appendingPathComponent("layout-probe.json"))
        }
    }
}

#endif
