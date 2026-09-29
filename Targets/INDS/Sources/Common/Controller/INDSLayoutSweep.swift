#if DEBUG
//
//  INDSLayoutSweep.swift
//  eDuo
//
//  Geometry sweep behind the `-iNDSLayoutSweep` launch argument: validates
//  the default layouts and the DS screens across a matrix of arbitrary
//  container sizes — today's candybar phones, the near-square aspects of an
//  unfolded foldable phone, and the in-between sizes of a resizable iPadOS
//  window (a single drag walks through ALL of them). No current simulator can
//  reproduce those sizes; the geometry is a pure function of the container,
//  so it is validated directly.
//
//  Same invariant as `NDSControllerView.assertDefaultLayoutHasNoOverlaps`
//  (the bug class from v1.0(8): a 1px overlap means one thumb fires two
//  buttons), but against the whole size space instead of the single device
//  the build happens to run on. It prints one verdict per case and ends the
//  process: all PASS → exit 0, any FAIL → exit 1.
//

import UIKit

enum INDSLayoutSweep {

    /// Called from `AppDelegate.didFinishLaunching` (DEBUG only). Does
    /// nothing when the launch argument is absent.
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-iNDSLayoutSweep") else { return }

        // Widths × heights in points. Every size is tried as-is and
        // transposed, with idiom .phone and .pad. `mustPass: false` = below
        // any real window minimum (informational, does not fail the sweep).
        let cases: [(size: CGSize, mustPass: Bool)] = [
            // Today's candybar phones (folded, outer display)
            (CGSize(width: 320, height: 568), true),
            (CGSize(width: 375, height: 667), true),
            (CGSize(width: 393, height: 852), true),
            (CGSize(width: 430, height: 932), true),
            (CGSize(width: 440, height: 956), true),
            // iPhone Duo. Measured on the simulator 21-sep-2026: the inner
            // display is 2007x2853 px @3 = **669x951 pt** and the outer
            // 1398x2034 = 466x678. The 626x890 Apple's page quotes is not a
            // display this device has; it stays here only as a regression
            // guard, since the geometry must hold at any container size.
            (CGSize(width: 626, height: 890), true),
            (CGSize(width: 669, height: 951), true),
            // What a build made with an SDK older than 27.1 is actually given:
            // the system keeps the 82 pt strip at the top and hands the app
            // 669×871, with no way to see the rest.
            (CGSize(width: 669, height: 871), true),
            (CGSize(width: 466, height: 678), true),
            // Unfolded foldable: 4:3-ish / near-square aspects
            (CGSize(width: 600, height: 700), true),
            (CGSize(width: 640, height: 840), true),
            (CGSize(width: 700, height: 840), true),
            (CGSize(width: 717, height: 829), true),
            (CGSize(width: 768, height: 1024), true),
            (CGSize(width: 800, height: 900), true),
            // Exact squares (worst case for the portrait/landscape threshold)
            (CGSize(width: 500, height: 500), true),
            (CGSize(width: 700, height: 700), true),
            // Both sides of the control-metric thresholds, including the
            // compact-height transition after transposing the first pair.
            (CGSize(width: 499, height: 700), true),
            (CGSize(width: 500, height: 700), true),
            (CGSize(width: 619, height: 600), true),
            (CGSize(width: 620, height: 600), true),
            // iPadOS window / Split View (a drag passes through every size in between)
            (CGSize(width: 320, height: 480), true),
            (CGSize(width: 400, height: 600), true),
            (CGSize(width: 507, height: 678), true),
            (CGSize(width: 639, height: 1024), true),
            (CGSize(width: 834, height: 1194), true),
            (CGSize(width: 1024, height: 768), true),
            (CGSize(width: 1032, height: 1376), true),
            // Below any window minimum: informational only
            (CGSize(width: 280, height: 400), false),
            (CGSize(width: 320, height: 1000), false),
        ]

        var failures = 0
        var informationalFailures = 0

        var total = 0
        var report: [String] = []
        let adaptiveProblems = validateAdaptiveViews()
        total += 1
        if adaptiveProblems.isEmpty {
            report.append("SWEEP PASS adaptive view identity, resizing, and touch image geometry")
        } else {
            failures += 1
            adaptiveProblems.forEach { report.append("SWEEP FAIL adaptive views: \($0)") }
        }
        // Unfolded iPhone Duo: the layout that straddles the hinge. Both
        // published inner sizes, both orientations.
        for size in [CGSize(width: 626, height: 890), CGSize(width: 890, height: 626),
                     CGSize(width: 669, height: 951), CGSize(width: 951, height: 669),
                     CGSize(width: 669, height: 871), CGSize(width: 871, height: 669)] {
            total += 1
            let problems = validateFoldable(containerSize: size)
            let tag = "\(Int(size.width))x\(Int(size.height)) unfolded"
            if problems.isEmpty {
                report.append("SWEEP PASS \(tag)")
            } else {
                failures += 1
                for p in problems { report.append("SWEEP FAIL \(tag): \(p)") }
            }
        }

        for (base, mustPass) in cases {
            for size in [base, CGSize(width: base.height, height: base.width)] {
                for idiom in [UIUserInterfaceIdiom.phone, .pad] {
                    total += 1
                    let problems = validate(containerSize: size, idiom: idiom)
                    let tag = "\(Int(size.width))x\(Int(size.height)) \(idiom == .pad ? "pad" : "phone")"
                    if problems.isEmpty {
                        report.append("SWEEP PASS \(tag)")
                    } else if mustPass {
                        failures += 1
                        for p in problems { report.append("SWEEP FAIL \(tag): \(p)") }
                    } else {
                        informationalFailures += 1
                        for p in problems { report.append("SWEEP INFO \(tag) (below the minimum window size): \(p)") }
                    }
                }
            }
        }
        report.append("SWEEP DONE \(total) cases: \(total - failures - informationalFailures) passed, \(failures) hard failures, \(informationalFailures) informational failures below the minimum size")
        report.forEach { print($0) }
        // The stdout of a `simctl launch` does not always come through: the
        // file in the container is the reliable way to read the verdict from
        // outside.
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? report.joined(separator: "\n")
                .write(to: docs.appendingPathComponent("layout-sweep.txt"), atomically: true, encoding: .utf8)
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// The four face buttons form a deliberately tight diamond;
    /// `buttonsForTouch` resolves that overlap by nearest centre. Same
    /// exemption as the production assertion.
    private static let faceCluster: Set<INDSControllerButtonID> = [.a, .b, .x, .y]

    /// The hinge layout for a container only a folding iPhone can produce.
    /// Pure geometry plus the real views, so it is checked without the
    /// device — including that an iPad window of the same size never takes
    /// this path. The view half only means anything on a phone simulator.
    private static func validateFoldable(containerSize size: CGSize) -> [String] {
        var problems: [String] = []
        let isPortrait = size.height >= size.width
        let mode: DSScreenLayoutMode = isPortrait ? .stacked : .sideBySide
        if DSFoldableLayout.current(in: size, mode: mode, idiom: .pad) != nil {
            problems.append("the foldable exception fired for an iPad window")
        }
        guard let foldable = DSFoldableLayout.current(in: size, mode: mode, idiom: .phone) else {
            return problems + ["no hinge layout for an unfolded phone"]
        }
        // The hinge is a 40 pt band, not a line (measured: the division region
        // is 669×40 centred on the display's middle), so each panel has to sit
        // against its EDGE — 20 pt out from the centre — and leave the band
        // itself empty.
        let fold = ((isPortrait ? size.height : size.width) / 2).rounded()
        let half: CGFloat = 20
        let againstHinge = isPortrait
            ? abs(foldable.top.maxY - (fold - half)) <= 1 && abs(foldable.bottom.minY - (fold + half)) <= 1
            : abs(foldable.top.maxX - (fold - half)) <= 1 && abs(foldable.bottom.minX - (fold + half)) <= 1
        if !againstHinge {
            problems.append("a panel does not sit against the hinge: \(foldable.top) \(foldable.bottom)")
        }
        if min(foldable.top.width, foldable.bottom.width) < 192 {
            problems.append("a panel is under 0.75x native: \(foldable.top.size) \(foldable.bottom.size)")
        }
        // A DS is the same panel twice. If the two ever drift apart it stops
        // looking like the console and starts looking like a phone app.
        if abs(foldable.top.width - foldable.bottom.width) > 1
            || abs(foldable.top.height - foldable.bottom.height) > 1 {
            problems.append("the two panels are not the same size: \(foldable.top.size) \(foldable.bottom.size)")
        }

        guard UIDevice.current.userInterfaceIdiom == .phone else { return problems }
        let screens = DSDualScreenView(frame: CGRect(origin: .zero, size: size))
        screens.applyLayout(mode: mode, swap: false, animated: false)
        let upper = screens.topScreenView.frame
        let lower = screens.bottomScreenView.frame
        if upper != foldable.top || lower != foldable.bottom {
            problems.append("the screens ignore the hinge layout: \(upper) \(lower)")
        }
        let controller = NDSControllerView(frame: screens.bounds)
        let hud = NDSHUDView(frame: screens.bounds)
        // Both take the arrangement from the owning controller in the app;
        // here it has to be handed over, or they lay out for `.stacked`.
        controller.screenLayoutMode = mode
        hud.setLayoutIcon(mode)
        controller.layoutIfNeeded()
        hud.layoutIfNeeded()
        for button in (controller.subviews + hud.subviews.filter { $0 is UIButton }) where !button.isHidden {
            if !screens.bounds.contains(button.frame) || button.frame.intersects(upper) || button.frame.intersects(lower) {
                problems.append("a control covers a panel or clips: \(button.accessibilityLabel ?? "HUD") at \(button.frame)")
            }
        }
        for y in [lower.minY + 1, lower.midY, lower.maxY - 1] {
            for x in [lower.minX + 1, lower.midX, lower.maxX - 1] {
                if controller.hitTest(CGPoint(x: x, y: y), with: nil) != nil {
                    problems.append("controller intercepts the DS stylus")
                }
            }
        }
        print("DUO \(Int(size.width))x\(Int(size.height)) top=\(foldable.top) touch=\(foldable.bottom)"
              + " controls=\(foldable.controls == nil ? "default" : "hinge")")
        return problems
    }

    /// Exercise the actual views, including a resize that doesn't recreate
    /// the controller. Copying the geometry formula here missed these bugs.
    private static func validateAdaptiveViews() -> [String] {
        var problems: [String] = []
        let preferenceKey = "eNDSScreenLayoutLandscape"
        let savedPreference = UserDefaults.standard.object(forKey: preferenceKey)
        defer { UserDefaults.standard.set(savedPreference, forKey: preferenceKey) }
        DSScreenLayoutPreferences.setMode(nil, for: .landscape)
        if DSScreenLayoutPreferences.savedMode(for: .landscape) != nil
            || DSScreenLayoutPreferences.mode(for: .landscape, containerSize: CGSize(width: 840, height: 700)) != .stacked
            || DSScreenLayoutPreferences.mode(for: .landscape, containerSize: CGSize(width: 780, height: 390)) != .sideBySide {
            problems.append("Automatic does not follow available screen/control space")
        }
        DSScreenLayoutPreferences.setMode(.topOnly, for: .landscape)
        if DSScreenLayoutPreferences.mode(for: .landscape, containerSize: CGSize(width: 840, height: 700)) != .topOnly {
            problems.append("expanded automatic layout overwrites an explicit screen choice")
        }
        DSScreenLayoutPreferences.setMode(nil, for: .landscape)
        if DSScreenLayoutPreferences.cycleMode(for: .landscape, containerSize: CGSize(width: 840, height: 700)) != .sideBySide {
            problems.append("cycling skips the mode after the visible expanded default")
        }
        // Expanded stacked presentation must leave the lower display between
        // the thumb controls, instead of putting both displays above them.
        for size in [CGSize(width: 700, height: 840), CGSize(width: 840, height: 700),
                     CGSize(width: 688, height: 676), CGSize(width: 834, height: 1194),
                     CGSize(width: 1194, height: 834)] {
            let screens = DSDualScreenView(frame: CGRect(origin: .zero, size: size))
            screens.applyLayout(mode: .stacked, swap: false, animated: false)
            let upper = screens.topScreenView.frame
            let lower = screens.bottomScreenView.frame
            if upper.midY >= size.height / 2 || lower.midY <= size.height / 2 {
                problems.append("expanded DS must put one display above and one below the middle: \(size)")
            }
            // The classic DS layout's own requirement: the thumb clusters go
            // beside the touch panel. A foldable puts them below/around it
            // instead (`DSFoldableLayout`), and is checked separately.
            if DSFoldableLayout.current(in: size, mode: .stacked) == nil,
               lower.minX < 208 || lower.maxX > size.width - 208 {
                problems.append("expanded DS must leave room beside the touch display for controls: \(size)")
            }
            let controller = NDSControllerView(frame: screens.bounds)
            let hud = NDSHUDView(frame: screens.bounds)
            controller.layoutIfNeeded()
            hud.layoutIfNeeded()
            let buttons = controller.subviews + hud.subviews.filter { $0 is UIButton }
            for button in buttons where !button.isHidden {
                if !screens.bounds.contains(button.frame) || button.frame.intersects(upper) || button.frame.intersects(lower) {
                    problems.append("expanded control clips or covers a DS screen: \(button.accessibilityLabel ?? "HUD") at \(size)")
                }
            }
            for y in [lower.minY + 1, lower.midY, lower.maxY - 1] {
                for x in [lower.minX + 1, lower.midX, lower.maxX - 1] {
                    if controller.hitTest(CGPoint(x: x, y: y), with: nil) != nil {
                        problems.append("controller intercepts the DS stylus at \(size)")
                    }
                }
            }
        }
        // The foldable exception must stay unreachable for every device that
        // exists: content rects of the largest iPhones (both orientations,
        // safe areas already off) and any iPad window, which is `.pad`.
        for size in [CGSize(width: 440, height: 924), CGSize(width: 924, height: 440),
                     CGSize(width: 430, height: 900), CGSize(width: 900, height: 430),
                     CGSize(width: 393, height: 820), CGSize(width: 820, height: 393),
                     CGSize(width: 375, height: 635), CGSize(width: 635, height: 375)] {
            if DSFoldableLayout.isUnfolded(size, idiom: .phone) {
                problems.append("a candybar iPhone takes the foldable path: \(size)")
            }
        }
        for size in [CGSize(width: 626, height: 890), CGSize(width: 890, height: 626),
                     CGSize(width: 1024, height: 1366), CGSize(width: 639, height: 1024)] {
            if DSFoldableLayout.isUnfolded(size, idiom: .pad) {
                problems.append("an iPad window takes the foldable path: \(size)")
            }
        }
        for size in [CGSize(width: 390, height: 780), CGSize(width: 700, height: 840),
                     CGSize(width: 840, height: 700), CGSize(width: 780, height: 390)] {
            let phone = INDSControlBand.effectiveIdiom(for: size, device: .phone)
            let pad = INDSControlBand.effectiveIdiom(for: size, device: .pad)
            if phone != pad { problems.append("same space gives different control metrics: \(size)") }
        }

        let dual = DSDualScreenView(frame: CGRect(x: 0, y: 0, width: 700, height: 840))
        let top = dual.topScreenView
        let touch = dual.bottomScreenView
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 192)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        }
        top.image = image
        touch.image = image
        dual.applyLayout(mode: .stacked, swap: false, stretch: true, animated: false)
        if touch.contentMode != .scaleToFill || top.contentMode != .scaleToFill {
            problems.append("Fill Screen leaves letterboxing inside the stylus coordinate space")
        }
        dual.frame.size = CGSize(width: 840, height: 700)
        dual.applyLayout(mode: .sideBySide, swap: true, animated: false)
        dual.layoutIfNeeded()
        if dual.topScreenView !== top || dual.bottomScreenView !== touch || touch.image !== image {
            problems.append("resize/swap recreated a screen or lost its framebuffer")
        }
        if touch.frame.minX >= top.frame.minX || touch.contentMode != .scaleAspectFit {
            problems.append("swap or aspect-fit restoration failed")
        }

        let controller = NDSControllerView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        // A caller must not have to set an orientation before UIKit lays out
        // its child, or the first resize pass uses yesterday's button positions.
        for size in [CGSize(width: 390, height: 780), CGSize(width: 840, height: 700),
                     CGSize(width: 700, height: 700), CGSize(width: 390, height: 780)] {
            controller.screenLayoutMode = size.width > size.height ? .sideBySide : .stacked
            controller.frame.size = size
            controller.setNeedsLayout()
            controller.layoutIfNeeded()
            guard let shoulder = controller.subviews.first(where: {
                $0.accessibilityLabel == INDSControllerButtonID.l.accessibilityName
            }) else {
                problems.append("missing L shoulder after resize")
                continue
            }
            let landscape = size.width > size.height
            if landscape && shoulder.frame.midY > size.height / 2 {
                problems.append("landscape resize keeps portrait controls: \(size)")
            }
        }
        return problems
    }

    private static func validate(containerSize size: CGSize, idiom: UIUserInterfaceIdiom) -> [String] {
        var problems: [String] = []
        let isPortrait = size.height >= size.width

        let layout = isPortrait
            ? INDSCustomControllerLayout.defaultPortrait(containerSize: size, idiom: idiom)
            : INDSCustomControllerLayout.defaultLandscape(containerSize: size, idiom: idiom)

        // Same set production validates: visible and non-chrome (the HUD
        // draws Menu/Layout/FF with its own metrics).
        let frames: [(id: INDSControllerButtonID, frame: CGRect)] = layout.buttons
            .filter { $0.isVisible && !$0.id.isHUDChrome }
            .map { ($0.id, $0.clampedFrame(in: size, userInterfaceIdiom: idiom)) }
            .sorted { $0.0.rawValue < $1.0.rawValue }

        let container = CGRect(origin: .zero, size: size)
        for (id, frame) in frames {
            if frame.width < 1 || frame.height < 1 {
                problems.append("\(id.rawValue) has a degenerate size: \(frame.size)")
            }
            if !container.contains(frame) {
                problems.append("\(id.rawValue) falls outside the container: \(frame)")
            }
        }
        for (index, lhs) in frames.enumerated() {
            for rhs in frames.dropFirst(index + 1) where lhs.frame.intersects(rhs.frame) {
                if faceCluster.contains(lhs.id), faceCluster.contains(rhs.id) { continue }
                problems.append("solape \(lhs.id.rawValue) \(lhs.frame) x \(rhs.id.rawValue) \(rhs.frame) -> \(lhs.frame.intersection(rhs.frame))")
            }
        }

        // DS screens: in portrait the control band is subtracted first
        // (exactly what DSDualScreenView does with reservesControlBand).
        let mode: DSScreenLayoutMode = isPortrait ? .stacked : .sideBySide
        var screenBounds = container
        if isPortrait {
            // Same computation as DSDualScreenView: the band uses the
            // effective idiom derived from width, not the device's.
            let bandIdiom = INDSControlBand.effectiveIdiom(for: size, device: idiom)
            screenBounds.size.height -= INDSControlBand.height(for: bandIdiom)
        }
        if screenBounds.height < 100 {
            problems.append("the control band leaves no room for the screens (\(Int(screenBounds.height))pt left)")
        } else {
            let (top, bottom) = DSScreenGeometry.frames(mode: mode, swap: false, in: screenBounds)
            for (name, rect) in [("top", top), ("bottom", bottom)] {
                guard let rect else {
                    problems.append("pantalla \(name) ausente en modo \(mode)")
                    continue
                }
                if rect.width < 1 || rect.height < 1 {
                    problems.append("pantalla \(name) degenerada: \(rect)")
                    continue
                }
                let aspect = rect.width / rect.height
                let expected = DSScreenGeometry.aspectWidth / DSScreenGeometry.aspectHeight
                if abs(aspect - expected) > 0.01 {
                    problems.append("pantalla \(name) pierde el 4:3: \(rect) (aspect \(aspect))")
                }
                if !screenBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                    problems.append("the \(name) screen overlaps the control band: \(rect)")
                }
            }
        }

        return problems
    }
}
#endif
