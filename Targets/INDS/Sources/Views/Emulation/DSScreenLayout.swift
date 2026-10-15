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

    static func mode(for orientationClass: DSScreenOrientationClass, containerSize: CGSize? = nil,
                     hinge: DSHingeState = .unknown) -> DSScreenLayoutMode {
        if let saved = savedMode(for: orientationClass) { return saved }
        // A real crease decides: one screen each side of it, whatever the
        // container's aspect says.
        if case .band(let band) = hinge { return band.isVertical ? .sideBySide : .stacked }
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
    static func cycleMode(for orientationClass: DSScreenOrientationClass, containerSize: CGSize? = nil,
                          hinge: DSHingeState = .unknown) -> DSScreenLayoutMode {
        let next = mode(for: orientationClass, containerSize: containerSize, hinge: hinge).next
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

/// The arrangement for a display with a crease across it: one screen on each
/// side of the hinge band, nothing drawn or touchable inside the band, nothing
/// under what the system draws over the display (`DSHingeBand`).
///
/// Everything is derived from the band the system reports
/// (`DSHingeState.resolve`), not from device names or fixed measurements, so
/// a different posture or a different foldable only changes the inputs.
struct DSFoldableLayout {
    let top: CGRect
    let bottom: CGRect
    /// `nil` = keep the container's default control arrangement, or no
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

    /// Whether `size` can only be an unfolded folding iPhone. Only used when
    /// the system cannot say (`DSHingeState.unknown`: SDK or OS before iOS
    /// 27.1): an *iPhone* reporting a container no iPhone has (the largest
    /// gives 440×956 pt, so 560 pt of short side cannot be a candybar). An
    /// iPad, including every Split View and Stage Manager window, is `.pad`
    /// and never takes this path.
    static func isUnfolded(_ size: CGSize,
                           idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> Bool {
        idiom == .phone && min(size.width, size.height) >= 560
    }

    /// The crease for `size` given what the system said, or nil when there is
    /// none (the layout is then the ordinary one).
    static func band(for hinge: DSHingeState, size: CGSize, idiom: UIUserInterfaceIdiom) -> DSHingeBand? {
        switch hinge {
        case .none:
            return nil
        case .band(let band):
            return band
        case .unknown:
            guard isUnfolded(size, idiom: idiom) else { return nil }
            // The only assumption left: a symmetric foldable bends in half.
            let vertical = size.width > size.height
            return DSHingeBand(isVertical: vertical,
                               center: ((vertical ? size.width : size.height) / 2).rounded(),
                               half: DSHingeBand.defaultHalf)
        }
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
                        hinge: DSHingeState = .unknown) -> DSFoldableLayout? {
        guard !stretch,
              let band = band(for: hinge, size: size, idiom: idiom),
              INDSControllerLayoutManager.shared.persistedLayout == nil,
              (UserDefaults.standard.object(forKey: "eNDSControllerScale") as? Double ?? 1) <= 1 else { return nil }
        // The screens straddle the hinge: stacked across a horizontal band,
        // side by side across a vertical one (Automatic resolves to these).
        guard mode == (band.isVertical ? .sideBySide : .stacked) else { return nil }
        return band.isVertical
            ? DSFoldableLayout(landscapeIn: size, band: band, controlsReserved: controlsReserved)
            : DSFoldableLayout(portraitIn: size, band: band, controlsReserved: controlsReserved)
    }

    // MARK: - Hinge across the middle (screens stacked)

    private init?(portraitIn size: CGSize, band: DSHingeBand, controlsReserved: Bool) {
        let upperEnd = band.leadingEdge
        let lowerStart = band.trailingEdge
        guard upperEnd > 0, lowerStart < size.height else { return nil }
        let aspect = DSScreenGeometry.aspectHeight / DSScreenGeometry.aspectWidth
        // Whatever the system draws over the display above the hinge: the
        // upper panel must start below it wherever the two overlap.
        func topLimit(x: ClosedRange<CGFloat>) -> CGFloat {
            band.occlusions.filter { $0.minY < upperEnd && $0.maxX > x.lowerBound && $0.minX < x.upperBound }
                .map(\.maxY).max() ?? 0
        }

        // A gamepad is driving: no controls, so each panel takes a half. They
        // still match (a DS's screens are the same panel twice), so the
        // smaller half sets the size, and each hangs from the hinge.
        guard controlsReserved else {
            var width = size.width
            width = min(width, (upperEnd - topLimit(x: 0...size.width)) / aspect,
                        (size.height - lowerStart) / aspect)
            guard width >= 1 else { return nil }
            let height = width * aspect
            let x = (size.width - width) / 2
            top = CGRect(x: x, y: Self.topY(upperEnd: upperEnd, panelHeight: height), width: width, height: height)
            bottom = CGRect(x: x, y: lowerStart, width: width, height: height)
            // Pills a little smaller than the default so they fit in what is
            // left under the lower panel (48 pt on the Duo).
            controls = Self.hudRow(between: top, and: bottom, in: size, scale: 0.85)
            return
        }

        // The touch panel sits against the hinge with the d-pad and the face
        // buttons either side of it, exactly where the thumbs already are.
        // The clusters shrink to about an iPhone's own button size so the
        // panel is as wide as that allows; `INDSButtonLayoutEntry.scale`
        // carries the factor to the drawn frames, so measurements and pixels
        // agree.
        let idiom = INDSControlBand.effectiveIdiom(for: size)
        let s = Self.clusterScale(for: idiom)
        let dpad = Self.size(.dpad, idiom, s)
        let radius = INDSControlBand.faceClusterRadius(for: idiom) * s
        let spread = INDSControlBand.faceSpread(for: idiom) * s
        let shoulder = Self.size(.l, idiom, Self.shoulderScale(s))
        let start = Self.size(.start, idiom, Self.shoulderScale(s))
        let hud = Self.size(.menu, idiom, Self.shoulderScale(s))
        let clusterWidth = max(dpad.width, 2 * radius)
        let margin: CGFloat = 8
        let rail = clusterWidth + 2 * margin
        let bottomMargin: CGFloat = 16

        // Under the touch panel: SELECT/START on the bottom edge.
        let below = 8 + start.height + bottomMargin
        let panelX0 = rail
        var width = size.width - 2 * rail
        width = min(width,
                    (size.height - lowerStart - below) / aspect,
                    (upperEnd - topLimit(x: panelX0...(size.width - rail))) / aspect)
        guard width >= 192 else { return nil }
        let height = width * aspect
        let x = (size.width - width) / 2
        bottom = CGRect(x: x, y: lowerStart, width: width, height: height)
        top = CGRect(x: x, y: Self.topY(upperEnd: upperEnd, panelHeight: height), width: width, height: height)

        let left = rail / 2
        let right = size.width - left
        let bottomY = size.height - bottomMargin - start.height / 2
        // The clusters sit at the bottom of the lower half, where thumbs rest.
        // They are narrower than the rails, so they can reach up past the
        // panel's lower edge without touching it.
        let clusterY = size.height - bottomMargin - clusterWidth / 2
        // L/R go where a DS has its shoulder buttons: the top corners of the
        // lower half, right under the hinge. The rear display, where index
        // fingers rest, takes no app content in iOS 27.1.
        let shoulderY = lowerStart + 6 + shoulder.height / 2
        // HUD pills: the strip above the upper panel when there is one (it is
        // empty and out of the thumbs' way), else the strip under the touch
        // panel, above SELECT/START.
        let hudHeight = hud.height
        let aboveGap = top.minY - topLimit(x: 0...size.width)
        let hudY: CGFloat
        if aboveGap >= hudHeight + 16 {
            hudY = topLimit(x: 0...size.width) + aboveGap / 2
        } else {
            hudY = (bottom.maxY + bottomY - start.height / 2) / 2
        }
        let shoulderScale = Self.shoulderScale(s)
        var entries = INDSControllerLayout.entries(from: [
            .dpad: CGPoint(x: left, y: clusterY),
            .y: CGPoint(x: right - spread, y: clusterY),
            .a: CGPoint(x: right + spread, y: clusterY),
            .x: CGPoint(x: right, y: clusterY - spread),
            .b: CGPoint(x: right, y: clusterY + spread),
        ], in: size, scale: s)
        entries += INDSControllerLayout.entries(from: [
            .l: CGPoint(x: left, y: shoulderY),
            .r: CGPoint(x: right, y: shoulderY),
            .layout: CGPoint(x: size.width / 2 - hud.width - 12, y: hudY),
            .menu: CGPoint(x: size.width / 2, y: hudY),
            .fastForward: CGPoint(x: size.width / 2 + hud.width + 12, y: hudY),
            .select: CGPoint(x: size.width / 2 - start.width, y: bottomY),
            .start: CGPoint(x: size.width / 2 + start.width, y: bottomY),
        ], in: size, scale: shoulderScale)
        controls = INDSControllerLayout(buttons: entries)
    }

    /// The upper panel's y when it hangs off the hinge band: lifted while
    /// half open, as far as the space above it allows.
    private static func topY(upperEnd: CGFloat, panelHeight: CGFloat) -> CGFloat {
        let onCrease = upperEnd - panelHeight
        return isHalfOpen ? max(0, onCrease - halfOpenLift) : onCrease
    }

    // MARK: - Hinge down the middle (screens side by side)

    private init?(landscapeIn size: CGSize, band: DSHingeBand, controlsReserved: Bool) {
        let leftEnd = band.leadingEdge
        let rightStart = band.trailingEdge
        guard leftEnd > 0, rightStart < size.width else { return nil }
        // Both panels are the same size, so the narrower side of the crease
        // sets it — the safe area is not centred on the hinge — and neither
        // one enters the band itself.
        let half = min(leftEnd, size.width - rightStart)
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
        top = CGRect(x: leftEnd - panelWidth, y: y, width: panelWidth, height: panelHeight)
        bottom = CGRect(x: rightStart, y: y, width: panelWidth, height: panelHeight)

        guard controlsReserved else {
            controls = nil
            return
        }

        let lowerMiddle = size.height - lowerBand / 2
        let upperMiddle = upperBand / 2
        let left = 12 + max(dpad.width, 2 * radius) / 2
        let right = size.width - left
        let center = band.center
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
            .select: CGPoint(x: center - start.width, y: lowerMiddle),
            .start: CGPoint(x: center + start.width, y: lowerMiddle),
            // Menu and Layout against the hinge on the left, Speed on the
            // right: the band itself stays empty.
            .layout: CGPoint(x: leftEnd - 12 - 1.5 * hud.width - 12, y: upperMiddle),
            .menu: CGPoint(x: leftEnd - 12 - hud.width / 2, y: upperMiddle),
            .fastForward: CGPoint(x: rightStart + 12 + hud.width / 2, y: upperMiddle),
        ], in: size))
    }

    /// Sin mandos en pantalla el HUD se iba al sitio de la banda de
    /// controles, que sin mandos es la pantalla TÁCTIL: las tres pastillas
    /// quedaban encima del juego y tapando los toques. Van en fila a la tira
    /// que sobra debajo del panel de abajo, y si no cabe, a la de arriba; si
    /// tampoco, nil y se deja el sitio por defecto. Lo usan el Duo abierto y
    /// cualquier vertical bajo con mando (Duo cerrado, iPhone SE), donde la
    /// columna de tres no cabe bajo las pantallas.
    static func hudRow(between top: CGRect, and bottom: CGRect, in size: CGSize,
                       scale: CGFloat = 1) -> INDSControllerLayout? {
        let base = INDSControllerButtonID.menu.baseSize(for: INDSControlBand.effectiveIdiom(for: size))
        let hudSize = CGSize(width: base.width * scale, height: base.height * scale)
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
            ], in: size, scale: scale))
        }
    }

    /// Width of each thumb cluster (the d-pad, the face diamond) in the
    /// stacked arrangement. The panel is as wide as what is left between the
    /// two, so this is the one number that trades screen for buttons: 124 pt
    /// gives a 118 pt d-pad and 48 pt face buttons, a little under an
    /// iPhone's own (132 / 54) and over the 44 pt touch-target minimum.
    private static let clusterTargetWidth: CGFloat = 124

    private static func clusterScale(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        let full = max(INDSControllerButtonID.dpad.baseSize(for: idiom).width,
                       2 * INDSControlBand.faceClusterRadius(for: idiom))
        return max(0.5, min(1, clusterTargetWidth / full))
    }

    /// Shoulders, SELECT/START and the HUD pills are wide and short, and are
    /// pressed with a thumb that has all the room it needs, so they shrink
    /// less than the clusters do.
    private static func shoulderScale(_ clusterScale: CGFloat) -> CGFloat {
        min(1, clusterScale * 1.4)
    }

    private static func size(_ id: INDSControllerButtonID,
                             _ idiom: UIUserInterfaceIdiom,
                             _ scale: CGFloat) -> CGSize {
        let base = id.baseSize(for: idiom)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }
}
