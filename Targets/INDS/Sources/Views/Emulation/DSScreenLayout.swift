//
//  DSScreenLayout.swift
//  eDuo
//
//  New (no iGBA equivalent — GBA has a single screen). Defines how the two DS
//  framebuffers (top = display only, bottom = touch) are arranged on screen,
//  plus persistence for the per-orientation mode and the swap flag.
//

import Foundation
import UIKit

/// Screen arrangement mode. Persisted separately per orientation class so a
/// user can e.g. keep `.stacked` in portrait but `.sideBySide` in landscape.
enum DSScreenLayoutMode: String, CaseIterable, Codable {
    case stacked
    case sideBySide
    case topOnly
    case bottomOnly

    var displayName: String {
        switch self {
        case .stacked:    return NSLocalizedString("Stacked", comment: "DS screen layout: both screens stacked vertically")
        case .sideBySide: return NSLocalizedString("Side by Side", comment: "DS screen layout: both screens side by side")
        case .topOnly:    return NSLocalizedString("Top Screen Only", comment: "DS screen layout: only the top screen")
        case .bottomOnly: return NSLocalizedString("Bottom Screen Only", comment: "DS screen layout: only the bottom/touch screen")
        }
    }

    var sfSymbolName: String {
        switch self {
        // Both from the `split` family, and both verified to exist:
        // "rectangle.grid.2x1.fill" is NOT a real SF Symbol, so
        // `UIImage(systemName:)` returned nil and the HUD's Layout button lost
        // its icon entirely in side-by-side — i.e. in landscape, by default.
        case .stacked:    return "rectangle.split.1x2.fill"
        case .sideBySide: return "rectangle.split.2x1.fill"
        case .topOnly:    return "square.tophalf.filled"
        case .bottomOnly: return "square.bottomhalf.filled"
        }
    }

    /// Whether the bottom (touch-capable) DS screen is visible at all in this mode.
    var showsBottomScreen: Bool { self != .topOnly }

    var next: DSScreenLayoutMode {
        let all = Self.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

enum DSScreenOrientationClass {
    case portrait
    case landscape
}

/// UserDefaults-backed persistence for the active screen layout. Keys are
/// stable and documented here so any future settings screen can read/write
/// them without going through this type.
enum DSScreenLayoutPreferences {
    private static let portraitKey = "eNDSScreenLayoutPortrait"
    private static let landscapeKey = "eNDSScreenLayoutLandscape"
    private static let swapKey = "eNDSScreenSwap"
    private static let stretchKey = "eNDSStretchScreens"

    static func mode(for orientationClass: DSScreenOrientationClass, containerSize: CGSize? = nil) -> DSScreenLayoutMode {
        if let saved = savedMode(for: orientationClass) { return saved }
        let consoleFits = containerSize.flatMap { DSConsoleLayout(in: $0) } != nil
        return orientationClass == .portrait || consoleFits ? .stacked : .sideBySide
    }

    /// nil is Automatic; explicit per-orientation choices keep their old keys.
    static func savedMode(for orientationClass: DSScreenOrientationClass) -> DSScreenLayoutMode? {
        let key = orientationClass == .portrait ? portraitKey : landscapeKey
        return UserDefaults.standard.string(forKey: key).flatMap(DSScreenLayoutMode.init(rawValue:))
    }

    static func setMode(_ mode: DSScreenLayoutMode?, for orientationClass: DSScreenOrientationClass) {
        let key = orientationClass == .portrait ? portraitKey : landscapeKey
        UserDefaults.standard.set(mode?.rawValue, forKey: key)
    }

    /// Advances and persists the mode for `orientationClass`, returning the new value.
    @discardableResult
    static func cycleMode(for orientationClass: DSScreenOrientationClass, containerSize: CGSize? = nil) -> DSScreenLayoutMode {
        let next = mode(for: orientationClass, containerSize: containerSize).next
        setMode(next, for: orientationClass)
        return next
    }

    static var swapEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: swapKey) }
        set { UserDefaults.standard.set(newValue, forKey: swapKey) }
    }

    /// "Fill screen (ignore aspect ratio)" — default OFF (today's always-4:3
    /// behavior).
    static var stretchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: stretchKey) }
        set { UserDefaults.standard.set(newValue, forKey: stretchKey) }
    }
}

/// A DS-shaped arrangement when two native-resolution panels and both thumb
/// clusters fit. These are content measurements, not device or hinge metrics.
struct DSConsoleLayout {
    let top: CGRect
    let bottom: CGRect
    let controls: INDSControllerLayout

    static func current(in size: CGSize, mode: DSScreenLayoutMode, stretch: Bool = false) -> DSConsoleLayout? {
        guard mode == .stacked, !stretch,
              INDSControllerLayoutManager.shared.persistedLayout == nil,
              (UserDefaults.standard.object(forKey: "eNDSControllerScale") as? Double ?? 1) <= 1 else { return nil }
        return DSConsoleLayout(in: size)
    }

    init?(in size: CGSize) {
        let idiom = INDSControlBand.effectiveIdiom(for: size)
        let dpad = INDSControllerButtonID.dpad.baseSize(for: idiom)
        let shoulder = INDSControllerButtonID.l.baseSize(for: idiom)
        let start = INDSControllerButtonID.start.baseSize(for: idiom)
        let hud = INDSControllerButtonID.menu.baseSize(for: idiom)
        let radius = INDSControlBand.faceClusterRadius(for: idiom)
        let rail = max(dpad.width, 2 * radius) + 16
        let header = hud.height + 20
        let panelHeight = (size.height - header - 16) / 2
        let screenWidth = min(size.width - 2 * rail, panelHeight * 4 / 3)
        guard screenWidth >= 256,
              panelHeight >= shoulder.height + 12 + max(dpad.height, 2 * radius) + 12 + start.height else { return nil }

        let screenHeight = screenWidth * 3 / 4
        let lowerY = header + panelHeight + 16
        top = CGRect(x: (size.width - screenWidth) / 2,
                     y: header + (panelHeight - screenHeight) / 2,
                     width: screenWidth, height: screenHeight)
        bottom = top.offsetBy(dx: 0, dy: panelHeight + 16)
        let left = rail / 2
        let right = size.width - left
        let middle = lowerY + panelHeight / 2
        let spread = INDSControlBand.faceSpread(for: idiom)
        controls = INDSControllerLayout(buttons: INDSControllerLayout.entries(from: [
            .l: CGPoint(x: left, y: lowerY + shoulder.height / 2),
            .r: CGPoint(x: right, y: lowerY + shoulder.height / 2),
            .dpad: CGPoint(x: left, y: middle),
            .y: CGPoint(x: right - spread, y: middle),
            .a: CGPoint(x: right + spread, y: middle),
            .x: CGPoint(x: right, y: middle - spread),
            .b: CGPoint(x: right, y: middle + spread),
            .select: CGPoint(x: left, y: size.height - start.height / 2),
            .start: CGPoint(x: right, y: size.height - start.height / 2),
            .layout: CGPoint(x: size.width / 2 - hud.width - 12, y: header / 2),
            .menu: CGPoint(x: size.width / 2, y: header / 2),
            .fastForward: CGPoint(x: size.width / 2 + hud.width + 12, y: header / 2),
        ], in: size))
    }
}

/// Pure geometry: computes where the DS top/bottom screens sit for a given
/// mode inside a content rect. Screen *identity* never changes — the returned
/// `top` rect is always for the DS top framebuffer and `bottom` for the DS
/// touch framebuffer; `swap` only reorders their on-screen position in the
/// dual-screen modes (stacked/sideBySide). `topOnly`/`bottomOnly` always show
/// exactly the screen their name says, regardless of swap, so cycling the HUD
/// button never surprises the user about which physical screen they asked for.
enum DSScreenGeometry {
    static let aspectWidth: CGFloat = 256
    static let aspectHeight: CGFloat = 192
    /// The two DS panels sit flush against each other, like the real hinge
    /// line. A gap here is dead space that comes straight out of the screens'
    /// size — with a reserved control band below (`INDSControlBand`), every
    /// point matters.
    static let gap: CGFloat = 0

    /// `stretch` (Screens > "Fill screen") drops the 4:3 aspect-fit and
    /// instead gives each screen the *entire* rect its mode/slot would
    /// otherwise only be centered inside — same slot boundaries (gap,
    /// stacking/side-by-side split) either way, just no more letterboxing.
    static func frames(mode: DSScreenLayoutMode, swap: Bool, stretch: Bool = false, in bounds: CGRect) -> (top: CGRect?, bottom: CGRect?) {
        switch mode {
        case .topOnly:
            return (stretch ? bounds : fit(in: bounds), nil)
        case .bottomOnly:
            return (nil, stretch ? bounds : fit(in: bounds))
        case .stacked:
            let (first, second) = stretch ? stackedFillPair(in: bounds) : stackedPair(in: bounds)
            return swap ? (second, first) : (first, second)
        case .sideBySide:
            let (first, second) = stretch ? sideBySideFillPair(in: bounds) : sideBySidePair(in: bounds)
            return swap ? (second, first) : (first, second)
        }
    }

    /// Single 256:192 rect, aspect-fit and centered in `bounds`.
    private static func fit(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / aspectWidth, bounds.height / aspectHeight)
        let w = aspectWidth * scale
        let h = aspectHeight * scale
        return CGRect(x: bounds.minX + (bounds.width - w) / 2,
                      y: bounds.minY + (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// Two equal 256:192 rects stacked vertically, top-anchored (per spec:
    /// "centradas arriba"), horizontally centered — leaves the remainder of
    /// `bounds` below free for controls on any phone-shaped screen.
    private static func stackedPair(in bounds: CGRect) -> (CGRect, CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.zero, .zero) }
        var screenW = bounds.width
        var screenH = screenW * aspectHeight / aspectWidth
        if screenH * 2 + gap > bounds.height {
            screenH = (bounds.height - gap) / 2
            screenW = screenH * aspectWidth / aspectHeight
        }
        let x = bounds.minX + (bounds.width - screenW) / 2
        let topY = bounds.minY
        let bottomY = topY + screenH + gap
        return (CGRect(x: x, y: topY, width: screenW, height: screenH),
                CGRect(x: x, y: bottomY, width: screenW, height: screenH))
    }

    /// Two equal 256:192 rects side by side, centered in `bounds`.
    private static func sideBySidePair(in bounds: CGRect) -> (CGRect, CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.zero, .zero) }
        var screenH = bounds.height
        var screenW = screenH * aspectWidth / aspectHeight
        if screenW * 2 + gap > bounds.width {
            screenW = (bounds.width - gap) / 2
            screenH = screenW * aspectHeight / aspectWidth
        }
        let y = bounds.minY + (bounds.height - screenH) / 2
        let leadingX = bounds.minX
        let trailingX = leadingX + screenW + gap
        return (CGRect(x: leadingX, y: y, width: screenW, height: screenH),
                CGRect(x: trailingX, y: y, width: screenW, height: screenH))
    }

    /// `stackedPair`'s stretch counterpart: same top-anchored split (full
    /// width, half the height minus the gap each) but without recomputing
    /// `screenW`/`screenH` from the 4:3 aspect ratio first — each screen
    /// simply fills its whole half.
    private static func stackedFillPair(in bounds: CGRect) -> (CGRect, CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.zero, .zero) }
        let screenH = (bounds.height - gap) / 2
        let topY = bounds.minY
        let bottomY = topY + screenH + gap
        return (CGRect(x: bounds.minX, y: topY, width: bounds.width, height: screenH),
                CGRect(x: bounds.minX, y: bottomY, width: bounds.width, height: screenH))
    }

    /// `sideBySidePair`'s stretch counterpart — full height, half the width
    /// minus the gap each.
    private static func sideBySideFillPair(in bounds: CGRect) -> (CGRect, CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.zero, .zero) }
        let screenW = (bounds.width - gap) / 2
        let leadingX = bounds.minX
        let trailingX = leadingX + screenW + gap
        return (CGRect(x: leadingX, y: bounds.minY, width: screenW, height: bounds.height),
                CGRect(x: trailingX, y: bounds.minY, width: screenW, height: bounds.height))
    }
}

// MARK: - Foldable (unfolded folding iPhone)

struct DSFoldableLayout {
    let top: CGRect
    let bottom: CGRect
    /// `nil` = keep the container's default control arrangement (portrait,
    /// where the reserved band already sits below both panels), or no
    /// controls at all (a hardware gamepad is driving).
    let controls: INDSControllerLayout?

    /// Duo half open, the lower half flat on the table: the upper half faces
    /// the player at an angle, and a panel hanging straight off the crease
    /// reads as bent. Set from the hinge (`NDSRomViewController`); stays
    /// false on every device without one, so nothing else moves.
    static var isHalfOpen = false

    /// How far the upper panel moves up, away from the crease, while
    /// `isHalfOpen`.
    private static let halfOpenLift: CGFloat = 24

    /// The upper panel's y when it would otherwise sit on the crease: lifted
    /// while half open, as far as the space above it allows.
    private static func topY(fold: CGFloat, panelHeight: CGFloat) -> CGFloat {
        let onCrease = fold - creaseHalf - panelHeight
        return isHalfOpen ? max(0, onCrease - halfOpenLift) : onCrease
    }

    /// Whether `size` can only be an unfolded folding iPhone.
    ///
    /// The exception is as narrow as it can be made without a posture API: an
    /// *iPhone* reporting a container no iPhone has. The largest iPhone gives
    /// 440×956pt, so its shortest side is 440pt in either orientation, and
    /// 560pt cannot be a candybar phone. An iPad — including every Split View
    /// and Stage Manager window on it, which can be any size at all — reports
    /// `.pad` and never takes this path. Nothing that exists today changes.
    static func isUnfolded(_ size: CGSize,
                           idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> Bool {
        idiom == .phone && min(size.width, size.height) >= 560
    }

    /// The arrangement for `size`, or nil to keep the existing layout — which
    /// is also the answer for an explicit screen choice, a custom control
    /// layout, enlarged controls or Fill Screen, exactly like
    /// `DSConsoleLayout.current`.
    static func current(in size: CGSize,
                        mode: DSScreenLayoutMode,
                        stretch: Bool = false,
                        controlsReserved: Bool = true,
                        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom,
                        fold: CGFloat? = nil) -> DSFoldableLayout? {
        guard isUnfolded(size, idiom: idiom), !stretch,
              INDSControllerLayoutManager.shared.persistedLayout == nil,
              (UserDefaults.standard.object(forKey: "eNDSControllerScale") as? Double ?? 1) <= 1 else { return nil }
        // The hinge is horizontal in portrait and vertical in landscape, so
        // the arrangement that straddles it is the stacked pair in portrait
        // and the side-by-side pair in landscape — which is what Automatic
        // already resolves to at these sizes.
        let isPortrait = size.height >= size.width
        guard mode == (isPortrait ? .stacked : .sideBySide) else { return nil }
        return isPortrait
            ? DSFoldableLayout(portraitIn: size, controlsReserved: controlsReserved, fold: fold)
            : DSFoldableLayout(landscapeIn: size, controlsReserved: controlsReserved, fold: fold)
    }

    /// Where the hinge falls inside `content`, whose origin is in `view`'s
    /// own coordinates. The crease splits the **display**, and the safe area
    /// is not centred on it — on the iPhone Duo the status rail eats 80 pt off
    /// one edge and the home indicator 34 pt off the other, so halving the
    /// safe-area rect put the seam 23,5 pt past the crease. Measured on the
    /// simulator, 21-sep-2026: display 669×951 pt, crease at 475,5.
    ///
    /// ⚠️Measured on the simulator, 21-sep-2026, with the SAME probe built
    /// twice: with the **iOS 27.1 SDK** the app gets the whole display
    /// (screen and window both 669×951, safe area {82,0,34,0}) and
    /// `reservedRegions(kind: .division)` returns the crease — `{0, 455.5}
    /// 669×40`, margins 20 top and bottom, i.e. **centred on 475,5 = the
    /// display's middle**. Built with the **27.0 SDK** the very same code
    /// gets 669×871 and cannot see any of it: `nativeBounds` is cut down too
    /// (2007×2613) and `UIScreen.main.bounds` answers about the *outer*
    /// display (466×678).
    ///
    /// So halving the screen is the crease, exactly, on the only toolchain
    /// that can see the Duo at all — and on an older one it is a guess that
    /// nothing can improve. ponytail: swap the two lines below for
    /// `reservedRegions(kind: .division)` once the build moves to 27.1;
    /// everything else here already works off `fold`.
    static func fold(for view: UIView, content: CGRect, vertical: Bool) -> CGFloat? {
        guard let window = view.window else { return nil }
        // ⚠️La pantalla de la escena no siempre es la que se está usando: en
        // iGBA `windowScene.screen` contesta por el display EXTERIOR (466×678
        // medidos) porque la app se fabrica su propia `UIWindow`. Si dice ser
        // más pequeña que la ventana, manda la ventana.
        let screen = window.windowScene?.screen.bounds ?? .zero
        let display = CGSize(width: max(screen.width, window.bounds.width),
                             height: max(screen.height, window.bounds.height))
        guard display.width > 1, display.height > 1 else { return nil }
        let origin = view.convert(content.origin, to: nil)
        return vertical ? display.height / 2 - origin.y : display.width / 2 - origin.x
    }

    // MARK: - Portrait: hinge across the middle

    private init?(portraitIn size: CGSize, controlsReserved: Bool, fold foldOverride: CGFloat? = nil) {
        let fold = (foldOverride ?? size.height / 2).rounded()
        guard fold > 0, fold < size.height else { return nil }

        // A gamepad is driving: no controls, so the two panels take a half
        // each. They still match — a DS's screens are the same panel twice —
        // so the shorter half sets the size, and each hangs from the hinge.
        guard controlsReserved else {
            let half = min(fold, size.height - fold) - Self.creaseHalf
            guard half > 1 else { return nil }
            let slot = CGRect(x: 0, y: 0, width: size.width, height: half)
            let panel = Self.panel(in: slot, anchor: .minYEdge)
            top = CGRect(x: panel.minX, y: Self.topY(fold: fold, panelHeight: panel.height),
                         width: panel.width, height: panel.height)
            bottom = CGRect(x: panel.minX, y: fold + Self.creaseHalf,
                            width: panel.width, height: panel.height)
            controls = Self.hudRow(between: top, and: bottom, in: size)
            return
        }

        // Lower half = a DS's body: the touch panel sits on the hinge with the
        // d-pad and the face buttons either side of it, exactly where the
        // thumbs already are, and the small buttons go under it.
        //
        // The clusters have to shrink for that: at full iPad metrics they are
        // 200pt wide each, which on a ~626pt display leaves under 200pt of
        // panel between them. `Self.clusterScale` of those metrics is about
        // what an iPhone already gives (a 133pt d-pad against 132pt), so
        // nothing ends up smaller than a phone's controls while the panel
        // gets ~40% wider than it would below the buttons.
        let idiom = INDSControlBand.effectiveIdiom(for: size)
        let s = Self.clusterScale
        let dpad = Self.size(.dpad, idiom, s)
        let shoulder = Self.size(.l, idiom, s)
        let start = Self.size(.start, idiom, s)
        let hud = Self.size(.menu, idiom, s)
        let spread = INDSControlBand.faceSpread(for: idiom) * s
        let radius = INDSControlBand.faceClusterRadius(for: idiom) * s

        let rail = max(dpad.width, 2 * radius) + 16
        let panelWidth = size.width - 2 * rail
        let panelHeight = panelWidth * DSScreenGeometry.aspectHeight / DSScreenGeometry.aspectWidth
        // Two rows under the panel: the HUD pills, then SELECT/START
        // against the bottom edge.
        let rowHeight = max(shoulder.height, hud.height)
        let panelTop = fold + Self.creaseHalf
        guard panelWidth >= 192,
              panelTop + panelHeight + 12 + rowHeight + 12 + start.height + 16 <= size.height else { return nil }

        bottom = CGRect(x: (size.width - panelWidth) / 2, y: panelTop,
                        width: panelWidth, height: panelHeight)
        // A DS's two screens are the same panel twice (256×192 each), so the
        // top one copies the touch one instead of filling its half. The touch
        // panel is the one that is boxed in — the d-pad and ABXY sit either
        // side of it — so it sets the size for both, and what is left above is
        // the console's own bezel, not wasted space.
        guard panelHeight + Self.creaseHalf <= fold else { return nil }
        top = CGRect(x: bottom.minX, y: Self.topY(fold: fold, panelHeight: panelHeight),
                     width: panelWidth, height: panelHeight)
        let clusterY = bottom.midY
        let left = rail / 2
        let right = size.width - left
        let bottomY = size.height - 16 - start.height / 2
        // L/R go where a DS has its shoulder buttons: the top corners of the
        // lower half, right under the hinge, above the d-pad and ABXY in the
        // rails beside the touch panel. The rear display, where the index
        // fingers actually rest, takes no app content in iOS 27.1 (the only
        // interactive scene accessory is camera capture).
        let shoulderY = panelTop + shoulder.height / 2
        // SELECT/START sit on the bottom edge, so the HUD row is
        // centred in what is left between them and the touch panel instead
        // of hugging the panel and leaving a dead strip in the middle.
        let rowY = (bottom.maxY + bottomY - start.height / 2 - 12) / 2
        controls = INDSControllerLayout(buttons: INDSControllerLayout.entries(from: [
            .dpad: CGPoint(x: left, y: clusterY),
            .y: CGPoint(x: right - spread, y: clusterY),
            .a: CGPoint(x: right + spread, y: clusterY),
            .x: CGPoint(x: right, y: clusterY - spread),
            .b: CGPoint(x: right, y: clusterY + spread),
            .l: CGPoint(x: left, y: shoulderY),
            .r: CGPoint(x: right, y: shoulderY),
            .layout: CGPoint(x: size.width / 2 - hud.width - 12, y: rowY),
            .menu: CGPoint(x: size.width / 2, y: rowY),
            .fastForward: CGPoint(x: size.width / 2 + hud.width + 12, y: rowY),
            .select: CGPoint(x: size.width / 2 - start.width, y: bottomY),
            .start: CGPoint(x: size.width / 2 + start.width, y: bottomY),
        ], in: size, scale: s))
    }

    // MARK: - Landscape: hinge down the middle

    private init?(landscapeIn size: CGSize, controlsReserved: Bool, fold foldOverride: CGFloat? = nil) {
        let fold = (foldOverride ?? size.width / 2).rounded()
        guard fold > 0, fold < size.width else { return nil }
        // Both panels are the same size, so the narrower side of the crease
        // sets it — the safe area is not centred on the hinge — and neither
        // one enters the 40 pt band the hinge itself takes.
        let half = min(fold, size.width - fold) - Self.creaseHalf
        guard half > 1 else { return nil }
        let idiom = INDSControlBand.effectiveIdiom(for: size)
        let dpad = INDSControllerButtonID.dpad.baseSize(for: idiom)
        let shoulder = INDSControllerButtonID.l.baseSize(for: idiom)
        let start = INDSControllerButtonID.start.baseSize(for: idiom)
        let hud = INDSControllerButtonID.menu.baseSize(for: idiom)
        let radius = INDSControlBand.faceClusterRadius(for: idiom)
        let spread = INDSControlBand.faceSpread(for: idiom)

        // Both panels are as wide as half the display, so their height is
        // fixed by the width — the leftover vertical space is free, and the
        // thumb clusters take the bottom of it while the HUD takes the top.
        // That keeps every control off both panels instead of floating them
        // over the game, which is what the compact-landscape default does.
        let lowerBand = controlsReserved ? max(dpad.height, 2 * radius) + 24 : 0
        let upperBand = controlsReserved ? max(shoulder.height, hud.height) + 20 : 0
        let free = size.height - lowerBand - upperBand
        let scale = min(half / DSScreenGeometry.aspectWidth, free / DSScreenGeometry.aspectHeight)
        let panelWidth = DSScreenGeometry.aspectWidth * scale
        let panelHeight = DSScreenGeometry.aspectHeight * scale
        guard panelWidth >= 192, free > 0 else { return nil }

        let y = upperBand + (free - panelHeight) / 2
        top = CGRect(x: fold - Self.creaseHalf - panelWidth, y: y,
                     width: panelWidth, height: panelHeight)
        bottom = CGRect(x: fold + Self.creaseHalf, y: y,
                        width: panelWidth, height: panelHeight)

        guard controlsReserved else {
            controls = nil
            return
        }

        let lowerMiddle = size.height - lowerBand / 2
        let upperMiddle = upperBand / 2
        let left = 12 + max(dpad.width, 2 * radius) / 2
        let right = size.width - left
        // SELECT/START and the HUD pills live in the wide gap the two thumb
        // clusters leave between them, split across the two bands.
        controls = INDSControllerLayout(buttons: INDSControllerLayout.entries(from: [
            .l: CGPoint(x: 12 + shoulder.width / 2, y: upperMiddle),
            .r: CGPoint(x: size.width - 12 - shoulder.width / 2, y: upperMiddle),
            .dpad: CGPoint(x: left, y: lowerMiddle),
            .y: CGPoint(x: right - spread, y: lowerMiddle),
            .a: CGPoint(x: right + spread, y: lowerMiddle),
            .x: CGPoint(x: right, y: lowerMiddle - spread),
            .b: CGPoint(x: right, y: lowerMiddle + spread),
            .select: CGPoint(x: fold - start.width, y: lowerMiddle),
            .start: CGPoint(x: fold + start.width, y: lowerMiddle),
            .layout: CGPoint(x: fold - hud.width - 12, y: upperMiddle),
            .menu: CGPoint(x: fold, y: upperMiddle),
            .fastForward: CGPoint(x: fold + hud.width + 12, y: upperMiddle),
        ], in: size))
    }

    /// Sin mandos en pantalla el HUD se iba al sitio de la banda de
    /// controles, que sin mandos es la pantalla TÁCTIL: las tres pastillas
    /// quedaban encima del juego y tapando los toques. Van en fila a la tira
    /// que sobra debajo del panel de abajo, y si no cabe, a la de arriba; si
    /// tampoco, nil y se deja el sitio por defecto. Lo usan el Duo abierto y
    /// cualquier vertical bajo con mando (Duo cerrado, iPhone SE), donde la
    /// columna de tres no cabe bajo las pantallas.
    static func hudRow(between top: CGRect, and bottom: CGRect, in size: CGSize) -> INDSControllerLayout? {
        let hudSize = INDSControllerButtonID.menu.baseSize(for: INDSControlBand.effectiveIdiom(for: size))
        let upper = top.minY <= bottom.minY ? top : bottom
        let lower = top.minY <= bottom.minY ? bottom : top
        let belowGap = size.height - lower.maxY
        let aboveGap = upper.minY
        let hudY: CGFloat? = belowGap >= hudSize.height + 8 ? lower.maxY + belowGap / 2
            : aboveGap >= hudSize.height + 8 ? aboveGap / 2 : nil
        return hudY.map { y in
            INDSControllerLayout(buttons: INDSControllerLayout.entries(from: [
                .layout: CGPoint(x: size.width / 2 - hudSize.width - 12, y: y),
                .menu: CGPoint(x: size.width / 2, y: y),
                .fastForward: CGPoint(x: size.width / 2 + hudSize.width + 12, y: y),
            ], in: size))
        }
    }

    /// How much of the default iPad control metrics the portrait arrangement
    /// uses, so the touch panel fits between the thumb clusters. Roughly a
    /// phone's own button sizes; `INDSButtonLayoutEntry.scale` carries it to
    /// the drawn frames, so measurements and pixels agree.
    private static let clusterScale: CGFloat = 0.7

    /// Half the crease. The hinge is a 40 pt band, not a line: measured on the
    /// simulator the division region is `{0, 455.5} 669×40` with 20 pt of
    /// margin on each side. Panels stop at its edge, which is also what the
    /// two screens of a real DS do — the hinge sits between them.
    private static let creaseHalf: CGFloat = 20

    private static func size(_ id: INDSControllerButtonID,
                             _ idiom: UIUserInterfaceIdiom,
                             _ scale: CGFloat) -> CGSize {
        let base = id.baseSize(for: idiom)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    /// A native-aspect panel, as large as `slot` allows, centred across the
    /// slot and pushed against `anchor` (the hinge).
    private static func panel(in slot: CGRect, anchor: CGRectEdge) -> CGRect {
        let scale = min(slot.width / DSScreenGeometry.aspectWidth,
                        slot.height / DSScreenGeometry.aspectHeight)
        let width = DSScreenGeometry.aspectWidth * scale
        let height = DSScreenGeometry.aspectHeight * scale
        let y = anchor == .maxYEdge ? slot.maxY - height : slot.minY
        return CGRect(x: slot.midX - width / 2, y: y, width: width, height: height)
    }
}
