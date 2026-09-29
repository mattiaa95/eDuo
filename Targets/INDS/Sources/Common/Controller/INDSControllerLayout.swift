//
//  INDSControllerLayout.swift
//  eDuo
//
//  Ported and adapted from iGBA's CustomControllerLayout.swift.
//  Data model for the on-screen controller overlay: which buttons exist, where
//  they sit (normalized 0-1 position within the emulation view), and how big
//  they are. Positions are authored once per orientation and reused for both
//  iPhone and iPad (button *size* still scales per idiom via `baseSize`), which
//  keeps a single set of hand-tuned coordinates instead of four.
//

import Foundation
import UIKit

// MARK: - Directional Input Type

/// Whether the D-pad slot renders as a classic cross or a virtual joystick.
public enum INDSDirectionalInputType: Int, Codable, CaseIterable {
    case dpad = 0
    case joystick = 1

    public var displayName: String {
        switch self {
        case .dpad: return NSLocalizedString("D-Pad", comment: "")
        case .joystick: return NSLocalizedString("Joystick", comment: "")
        }
    }
}

// MARK: - Button Identifier

/// Every interactive element on the DS on-screen controller. Deliberately
/// smaller than iGBA's set: no turbo, no A+B combo, no macros, no menu button
/// (pause is a dedicated floating HUD button, not part of the skin layout).
public enum INDSControllerButtonID: String, Codable, CaseIterable, Hashable {
    case dpad
    case a
    case b
    case x
    case y
    case l
    case r
    case start
    case select
    case menu
    case layout
    /// Speed toggle. A HUD pill rather than a skin button, and a toggle rather
    /// than a hold: the gamepad mapping is a hold because a shoulder button is
    /// easy to keep down, but pinning a finger to the screen while both thumbs
    /// are already busy is not. Tap on, tap off.
    case fastForward

    /// Menu, Layout and Fast Forward are HUD chrome, not engine inputs: they
    /// live in this model so the layout editor can move and hide them like
    /// everything else, but they are drawn and hit-tested by `NDSHUDView`
    /// (blurred pills with captions, and they must survive the overlay being
    /// hidden when a gamepad connects), not by the controller overlay.
    public var isHUDChrome: Bool { self == .menu || self == .layout || self == .fastForward }

    /// Default label rendered on the vector button (no bundled skin artwork).
    public var defaultStyleLabel: String {
        switch self {
        case .dpad:   return "+"
        case .a:      return "A"
        case .b:      return "B"
        case .x:      return "X"
        case .y:      return "Y"
        case .l:      return "L"
        case .r:      return "R"
        case .start:  return "START"
        case .select: return "SELECT"
        case .menu:   return NSLocalizedString("Menu", comment: "HUD button caption: opens the pause menu")
        case .layout: return NSLocalizedString("Layout", comment: "HUD button caption: cycles the screen layout")
        case .fastForward: return NSLocalizedString("Speed", comment: "HUD button caption: toggles fast forward")
        }
    }

    /// Spoken name for VoiceOver. The rendered glyph ("A", "+") is not a label:
    /// VoiceOver would read "A" as the letter and "+" as "plus", and neither
    /// tells anyone what the control does.
    public var accessibilityName: String {
        switch self {
        case .dpad:   return NSLocalizedString("Directional pad", comment: "VoiceOver label for the on-screen D-pad")
        case .a:      return NSLocalizedString("A button", comment: "VoiceOver label")
        case .b:      return NSLocalizedString("B button", comment: "VoiceOver label")
        case .x:      return NSLocalizedString("X button", comment: "VoiceOver label")
        case .y:      return NSLocalizedString("Y button", comment: "VoiceOver label")
        case .l:      return NSLocalizedString("L shoulder button", comment: "VoiceOver label")
        case .r:      return NSLocalizedString("R shoulder button", comment: "VoiceOver label")
        case .start:  return NSLocalizedString("Start button", comment: "VoiceOver label")
        case .select: return NSLocalizedString("Select button", comment: "VoiceOver label")
        case .menu:   return NSLocalizedString("Menu", comment: "HUD button caption: opens the pause menu")
        case .layout: return NSLocalizedString("Layout", comment: "HUD button caption: cycles the screen layout")
        case .fastForward: return NSLocalizedString("Fast forward", comment: "VoiceOver label for the speed toggle")
        }
    }

    /// Base render size used by the live overlay. Positions are authored once
    /// per orientation in normalized space; only the size scales per idiom.
    public func baseSize(for userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGSize {
        let isPhone = userInterfaceIdiom == .phone
        switch self {
        case .dpad:
            return isPhone ? CGSize(width: 132, height: 132) : CGSize(width: 190, height: 190)
        case .a, .b, .x, .y:
            return isPhone ? CGSize(width: 54, height: 54) : CGSize(width: 78, height: 78)
        case .l, .r:
            return isPhone ? CGSize(width: 84, height: 32) : CGSize(width: 120, height: 40)
        case .start, .select:
            return isPhone ? CGSize(width: 66, height: 28) : CGSize(width: 86, height: 34)
        case .menu, .layout, .fastForward:
            // Matches what `NDSHUDView`'s configuration-based pills actually
            // measure (icon over a 9pt caption), so the editor's preview and
            // the live HUD agree on where they are.
            //
            // Shrunk when Fast Forward joined the column: three of the old
            // 44pt pills plus their gaps overflowed the main row (132pt on
            // phone), and `clampedFrame` pushed the last one back inside —
            // straight on top of Menu.
            return isPhone ? CGSize(width: 54, height: 36) : CGSize(width: 70, height: 44)
        }
    }

    /// Maps this skin slot to the engine button it drives, by raw value
    /// (Swift's ObjC importer refuses to strip the `INDSButton` prefix down
    /// to a single letter for A/B/L/R/X/Y, so `.a`/`.l`/… aren't valid
    /// identifiers here — going through `rawValue` sidesteps that entirely
    /// and matches the raw values documented on `INDSButton` itself:
    /// A=0, B=1, Select=2, Start=3, Right=4, Left=5, Up=6, Down=7, R=8, L=9, X=10, Y=11).
    /// `nil` for `.dpad`, which resolves to up to two buttons via 9-zone hit testing instead.
    public var indsButton: INDSButton? {
        switch self {
        case .a: return INDSButton(rawValue: 0)
        case .b: return INDSButton(rawValue: 1)
        case .select: return INDSButton(rawValue: 2)
        case .start: return INDSButton(rawValue: 3)
        case .r: return INDSButton(rawValue: 8)
        case .l: return INDSButton(rawValue: 9)
        case .x: return INDSButton(rawValue: 10)
        case .y: return INDSButton(rawValue: 11)
        case .dpad, .menu, .layout, .fastForward: return nil
        }
    }
}

// MARK: - Button Entry

/// A single button's layout: position (normalized 0-1), size, and visibility.
public struct INDSButtonLayoutEntry: Codable, Equatable {
    public var id: INDSControllerButtonID

    /// Horizontal center position as fraction of container width (0 = left, 1 = right).
    public var normalizedX: CGFloat

    /// Vertical center position as fraction of container height (0 = top, 1 = bottom).
    public var normalizedY: CGFloat

    /// Scale multiplier relative to default size (1.0 = 100%).
    public var scale: CGFloat

    /// Whether this button is visible and active.
    public var isVisible: Bool

    /// Optional per-button visual style. `nil` uses the default vector look.
    public var style: INDSButtonStyle?

    public init(id: INDSControllerButtonID, normalizedX: CGFloat, normalizedY: CGFloat,
                scale: CGFloat = 1.0, isVisible: Bool = true, style: INDSButtonStyle? = nil) {
        self.id = id
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.scale = max(0.5, min(2.0, scale))
        self.isVisible = isVisible
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, normalizedX, normalizedY, scale, isVisible, style
    }

    /// Backward-compatible decoding: clamps every numeric field so a
    /// corrupted/hand-edited JSON can never park a button off-screen or make
    /// it un-tappable with no way to recover it from the UI.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(INDSControllerButtonID.self, forKey: .id)
        let rawX = try c.decode(CGFloat.self, forKey: .normalizedX)
        let rawY = try c.decode(CGFloat.self, forKey: .normalizedY)
        self.normalizedX = max(0.0, min(1.0, rawX))
        self.normalizedY = max(0.0, min(1.0, rawY))
        let rawScale = (try? c.decode(CGFloat.self, forKey: .scale)) ?? 1.0
        self.scale = max(0.5, min(2.0, rawScale))
        self.isVisible = (try? c.decode(Bool.self, forKey: .isVisible)) ?? true
        self.style = try? c.decode(INDSButtonStyle.self, forKey: .style)
    }

    /// Pixel frame given the container size and the (already-scaled) base size.
    private func frame(in containerSize: CGSize, scaledBaseSize: CGSize) -> CGRect {
        let cx = normalizedX * containerSize.width
        let cy = normalizedY * containerSize.height
        return CGRect(x: cx - scaledBaseSize.width / 2, y: cy - scaledBaseSize.height / 2,
                      width: scaledBaseSize.width, height: scaledBaseSize.height)
    }

    /// Frame clamped fully inside `containerSize`, relative to its (0,0) origin.
    /// The caller (the overlay view) offsets this into safe-area-aware
    /// coordinates when the container itself isn't the full view bounds.
    public func clampedFrame(in containerSize: CGSize,
                             userInterfaceIdiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGRect {
        // A narrow window on iPad → phone sizes, same as the default centres
        // (see `INDSControlBand.effectiveIdiom`).
        let idiom = INDSControlBand.effectiveIdiom(for: containerSize,
                                                   device: userInterfaceIdiom)
        let baseSize = id.baseSize(for: idiom)
        let scaledBase = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        var frame = frame(in: containerSize, scaledBaseSize: scaledBase)
        frame.origin.x = max(0, min(containerSize.width - frame.width, frame.origin.x))
        frame.origin.y = max(0, min(containerSize.height - frame.height, frame.origin.y))
        return frame
    }
}

// MARK: - Controller Layout (single orientation)

/// Complete layout for one orientation (portrait or landscape).
public struct INDSControllerLayout: Codable, Equatable {
    public var buttons: [INDSButtonLayoutEntry]
    public var directionalInputType: INDSDirectionalInputType

    public init(buttons: [INDSButtonLayoutEntry], directionalInputType: INDSDirectionalInputType = .dpad) {
        self.buttons = INDSControllerLayout.fillMissingButtons(buttons)
        self.directionalInputType = directionalInputType
    }

    private enum CodingKeys: String, CodingKey {
        case buttons, directionalInputType
    }

    /// Backward-compatible decoder: ensures every `INDSControllerButtonID`
    /// case has an entry, even ones added by a later app version than the one
    /// that persisted this JSON.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode([INDSButtonLayoutEntry].self, forKey: .buttons)
        self.buttons = INDSControllerLayout.fillMissingButtons(raw)
        self.directionalInputType = (try? c.decode(INDSDirectionalInputType.self, forKey: .directionalInputType)) ?? .dpad
    }

    /// Append hidden default entries for any `INDSControllerButtonID` case not
    /// already present. Pure decode-time safety net (lookups never `nil`);
    /// the meaningful "bring it back visible at its default spot" healing
    /// lives in `INDSCustomControllerLayout.healed()`.
    private static func fillMissingButtons(_ buttons: [INDSButtonLayoutEntry]) -> [INDSButtonLayoutEntry] {
        var result = buttons
        let existing = Set(buttons.map { $0.id })
        for id in INDSControllerButtonID.allCases where !existing.contains(id) {
            result.append(INDSButtonLayoutEntry(id: id, normalizedX: 0.5, normalizedY: 0.5, isVisible: false))
        }
        return result
    }

    public func entry(for id: INDSControllerButtonID) -> INDSButtonLayoutEntry? {
        buttons.first { $0.id == id }
    }

    /// Converts point-space centers (see `INDSControlBand`) into the model's
    /// normalized entries, in a stable order. Clamped because a container
    /// smaller than the band itself would otherwise produce negative
    /// fractions that `clampedFrame` can only partially rescue.
    /// `scale` is the multiplier the CENTRES were authored against, so a
    /// caller that had to shrink the buttons to make its arrangement fit
    /// (`DSFoldableLayout` puts the touch panel between the thumb clusters)
    /// gets frames that match its own measurements.
    static func entries(from centers: [INDSControllerButtonID: CGPoint],
                        in containerSize: CGSize,
                        scale: CGFloat = 1) -> [INDSButtonLayoutEntry] {
        guard containerSize.width > 1, containerSize.height > 1 else { return [] }
        return INDSControllerButtonID.allCases.compactMap { id in
            guard let center = centers[id] else { return nil }
            return INDSButtonLayoutEntry(id: id,
                                         normalizedX: max(0, min(1, center.x / containerSize.width)),
                                         normalizedY: max(0, min(1, center.y / containerSize.height)),
                                         scale: scale)
        }
    }

    /// Content-rect sizes to author defaults against when there is no live
    /// geometry to ask (layout editor reset, `healed()`). Exact for whichever
    /// orientation the app is in right now; the other one is the same screen
    /// with the axes swapped, which is within a few points of the truth
    /// because the safe-area insets differ only at the edges.
    static func referenceContainerSizes() -> (portrait: CGSize, landscape: CGSize) {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        let bounds = window?.bounds ?? UIScreen.main.bounds
        let insets = window?.safeAreaInsets ?? .zero
        let content = CGSize(width: bounds.width - insets.left - insets.right,
                             height: bounds.height - insets.top - insets.bottom)
        let flipped = CGSize(width: content.height, height: content.width)
        return content.height >= content.width ? (content, flipped) : (flipped, content)
    }

    public mutating func updateEntry(for id: INDSControllerButtonID, transform: (inout INDSButtonLayoutEntry) -> Void) {
        guard let index = buttons.firstIndex(where: { $0.id == id }) else { return }
        transform(&buttons[index])
    }
}

// MARK: - Full Custom Layout (both orientations)

/// Wraps portrait + landscape layouts under one named preset.
public struct INDSCustomControllerLayout: Codable, Equatable {
    public var portrait: INDSControllerLayout
    public var landscape: INDSControllerLayout
    public var name: String

    public init(name: String, portrait: INDSControllerLayout, landscape: INDSControllerLayout) {
        self.name = name
        self.portrait = portrait
        self.landscape = landscape
    }
}

// MARK: - Control Band

/// The fixed-height strip at the bottom of the portrait content rect that
/// belongs to the on-screen controls, and the point-space geometry of what
/// goes inside it.
///
/// Why a *fixed* strip instead of hand-picked normalized coordinates: two
/// stacked 256:192 screens eat ~79% of a phone's height, leaving 72pt (SE) to
/// 188pt (Pro Max) of room for controls that need ~258pt. Every set of
/// hardcoded normalized defaults therefore had buttons landing on top of each
/// other and on the touch screen, and by different amounts per device — the
/// strip's *share* of the height varies from 11% to 22% across the lineup, so
/// no single normalized number can be right everywhere. Reserving the band in
/// points (both here and in `DSScreenGeometry`, which shrinks the screens by
/// exactly this much) makes the controls land identically on every device and
/// the screens absorb the difference.
///
/// Overlaps are not cosmetic here: `NDSControllerView.buttonsForTouch` unions
/// every button frame containing the touch, so one pixel of overlap means one
/// thumb press firing two buttons at once (the d-pad + L phantom press the
/// v1.0(8) defaults produced on every phone).
public enum INDSControlBand {

    /// Control metrics follow usable space, including an expanded phone or
    /// a narrow tablet window. The existing pad row needs 620pt horizontally;
    /// compact heights keep the smaller controls off the game image.
    /// `device` remains source-compatible with saved-layout callers, but
    /// device identity must not change geometry for the same container.
    public static func effectiveIdiom(for containerSize: CGSize,
                                      device _: UIUserInterfaceIdiom = .unspecified) -> UIUserInterfaceIdiom {
        let minWidth: CGFloat = containerSize.width > containerSize.height ? 620 : 500
        return containerSize.width >= minWidth && containerSize.height >= 500 ? .pad : .phone
    }

    /// Spacing only — the button *sizes* come from
    /// `INDSControllerButtonID.baseSize(for:)`, which stays the single source
    /// of truth for how big anything is.
    private struct Spacing {
        var margin: CGFloat        // outer horizontal inset for the clusters
        var topAir: CGFloat        // breathing room under the touch screen
        var lrToMain: CGFloat
        var bottom: CGFloat
        var startOffset: CGFloat   // SELECT/START centers, from centerX
        var faceGap: CGFloat       // visible air between diagonal face buttons
    }

    private static func spacing(for idiom: UIUserInterfaceIdiom) -> Spacing {
        idiom == .pad
            ? Spacing(margin: 8, topAir: 3, lrToMain: 10, bottom: 6, startOffset: 56, faceGap: 0)
            : Spacing(margin: 4, topAir: 2, lrToMain: 8, bottom: 4, startOffset: 40, faceGap: 0)
    }

    /// Vertical gap between the stacked Menu/Layout pair.
    static let hudPairSpacing: CGFloat = 8

    private static func size(_ id: INDSControllerButtonID, _ idiom: UIUserInterfaceIdiom) -> CGSize {
        id.baseSize(for: idiom)
    }

    /// Distance from the diamond's center to each face button's center. Set
    /// to 78% of the button's own side, which is roughly how tight a real DS
    /// is — the diagonal neighbours' rectangular frames do overlap at that
    /// spacing, and `NDSControllerView.buttonsForTouch` resolves it by taking
    /// the nearest button center instead of pressing both.
    static func faceSpread(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        (size(.a, idiom).width * 0.78).rounded() + spacing(for: idiom).faceGap
    }

    /// Half-width (and half-height) of the whole ABXY diamond.
    static func faceClusterRadius(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        size(.a, idiom).width / 2 + faceSpread(for: idiom)
    }

    /// Tallest row: the d-pad and the face diamond share it.
    static func mainRowHeight(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        max(size(.dpad, idiom).height, size(.a, idiom).height + 2 * faceSpread(for: idiom))
    }

    /// Total reserved height. `DSScreenGeometry` subtracts exactly this from
    /// the portrait content rect before laying the DS screens out.
    ///
    /// Only two rows: shoulders + SELECT/START share the top one (the middle
    /// of that row is dead space — L and R are pinned to the far edges), and
    /// the d-pad/diamond/Menu-Layout share the main one. Giving SELECT/START
    /// their own row underneath cost 34pt of screen for two buttons that are
    /// pressed once a session.
    public static func height(for idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGFloat {
        let s = spacing(for: idiom)
        return s.topAir + topRowHeight(for: idiom) + s.lrToMain + mainRowHeight(for: idiom) + s.bottom
    }

    /// Tallest thing in the shoulders row.
    private static func topRowHeight(for idiom: UIUserInterfaceIdiom) -> CGFloat {
        max(size(.l, idiom).height, size(.start, idiom).height)
    }

    /// Row centers, measured down from the top of the band.
    fileprivate static func rowCenters(for idiom: UIUserInterfaceIdiom) -> (top: CGFloat, main: CGFloat) {
        let s = spacing(for: idiom)
        let top = s.topAir + topRowHeight(for: idiom) / 2
        let main = s.topAir + topRowHeight(for: idiom) + s.lrToMain + mainRowHeight(for: idiom) / 2
        return (top, main)
    }

    /// Button centers in points inside a portrait content rect of `size`.
    fileprivate static func portraitCenters(in containerSize: CGSize,
                                            idiom: UIUserInterfaceIdiom) -> [INDSControllerButtonID: CGPoint] {
        let s = spacing(for: idiom)
        let rows = rowCenters(for: idiom)
        let top = containerSize.height - height(for: idiom)
        let spread = faceSpread(for: idiom)
        let dpadCX = s.margin + size(.dpad, idiom).width / 2
        let faceCX = containerSize.width - s.margin - faceClusterRadius(for: idiom)
        let lrHalf = size(.l, idiom).width / 2
        // SELECT/START at ±startOffset from the centre, but never reaching
        // into the L/R pill: at 320pt wide the fixed offset left L and SELECT
        // overlapping by 1pt (one thumb = two buttons, the bug class from
        // v1.0(8)). The floor keeps SELECT and START apart from each other
        // even when the container is absurdly narrow.
        let selectHalf = size(.select, idiom).width / 2
        let maxOffset = containerSize.width / 2 - (s.margin + 2 * lrHalf) - selectHalf - 2
        let startOffset = max(selectHalf + 1, min(s.startOffset, maxOffset))
        // Menu/Layout stack vertically in the free column between the two
        // thumb clusters: side by side they were wide enough that a thumb
        // crossing the d-pad clipped them (device feedback on 1.0(8)).
        let hudCX = hudColumnCenterX(containerWidth: containerSize.width, idiom: idiom)
        // Three-item column CENTRED on the main row: Layout above, Menu in the
        // middle, Fast Forward below. The previous arrangement kept the old
        // pair centred and hung the third one underneath, which put it outside
        // the band.
        let hudStep = size(.menu, idiom).height + hudPairSpacing
        return [
            .l:      CGPoint(x: s.margin + lrHalf,                    y: top + rows.top),
            .r:      CGPoint(x: containerSize.width - s.margin - lrHalf, y: top + rows.top),
            .select: CGPoint(x: containerSize.width / 2 - startOffset, y: top + rows.top),
            .start:  CGPoint(x: containerSize.width / 2 + startOffset, y: top + rows.top),
            .dpad:   CGPoint(x: dpadCX,                               y: top + rows.main),
            .y:      CGPoint(x: faceCX - spread,                      y: top + rows.main),
            .a:      CGPoint(x: faceCX + spread,                      y: top + rows.main),
            .x:      CGPoint(x: faceCX,                               y: top + rows.main - spread),
            .b:      CGPoint(x: faceCX,                               y: top + rows.main + spread),
            .layout: CGPoint(x: hudCX,                                y: top + rows.main - hudStep),
            .menu:   CGPoint(x: hudCX,                                y: top + rows.main),
            .fastForward: CGPoint(x: hudCX,                           y: top + rows.main + hudStep),
        ]
    }

    /// Landscape has no band — the screens sit side by side across the whole
    /// content rect and the controls overlay their outer corners
    /// translucently. Same anti-overlap spacing, anchored to the four corners.
    fileprivate static func landscapeCenters(in containerSize: CGSize,
                                             idiom: UIUserInterfaceIdiom) -> [INDSControllerButtonID: CGPoint] {
        let s = spacing(for: idiom)
        let spread = faceSpread(for: idiom)
        let radius = faceClusterRadius(for: idiom)
        let lrSize = size(.l, idiom)
        let faceCX = containerSize.width - s.margin - radius
        let faceCY = containerSize.height - s.margin - radius
        // Bottom row, all bottom-aligned on the same edge despite different
        // heights: Layout · SELECT · START · Menu. In 1.0(10) the HUD pair
        // floated in the middle of the screen, right between the two DS
        // screens where it covered game content (device feedback).
        let bottom = containerSize.height - s.margin
        let startSize = size(.start, idiom)
        let hudSize = size(.menu, idiom)
        // Same as portrait: SELECT/START at ±startOffset from the centre but
        // without stepping on the d-pad (left) or the ABXY diamond (right) —
        // in a 568pt-wide window the fixed offset left the d-pad and SELECT
        // overlapping by 13pt. The floor keeps SELECT and START off each
        // other.
        let dpadRight = s.margin + size(.dpad, idiom).width
        let faceLeft = faceCX - radius
        let selectHalf = max(size(.select, idiom).width, startSize.width) / 2
        let halfSpan = min(containerSize.width / 2 - dpadRight, faceLeft - containerSize.width / 2)
        let startOffset = max(selectHalf + 1, min(s.startOffset, halfSpan - selectHalf - 4))
        let hudOffset = startOffset + startSize.width / 2 + 6 + hudSize.width / 2
        // L/R live at the top corner OF THE SCREENS, not of the container:
        // on a phone it makes no difference (the screens fill the height and
        // both corners coincide), but in a near-square container (a foldable
        // unfolded, in landscape) the screens sit centred in a band and
        // shoulders glued to the ceiling float a hand's width away from the
        // game. Same arithmetic as `DSScreenGeometry.sideBySidePair`.
        let sideScreenH = min(containerSize.height,
                              ((containerSize.width - DSScreenGeometry.gap) / 2)
                                  * DSScreenGeometry.aspectHeight / DSScreenGeometry.aspectWidth)
        let screensTop = (containerSize.height - sideScreenH) / 2
        let lrY = max(s.margin, screensTop + s.margin) + lrSize.height / 2
        return [
            .l:      CGPoint(x: s.margin + lrSize.width / 2,                     y: lrY),
            .r:      CGPoint(x: containerSize.width - s.margin - lrSize.width / 2, y: lrY),
            .dpad:   CGPoint(x: s.margin + size(.dpad, idiom).width / 2,
                             y: containerSize.height - s.margin - size(.dpad, idiom).height / 2),
            .y:      CGPoint(x: faceCX - spread, y: faceCY),
            .a:      CGPoint(x: faceCX + spread, y: faceCY),
            .x:      CGPoint(x: faceCX,          y: faceCY - spread),
            .b:      CGPoint(x: faceCX,          y: faceCY + spread),
            .select: CGPoint(x: containerSize.width / 2 - startOffset, y: bottom - startSize.height / 2),
            .start:  CGPoint(x: containerSize.width / 2 + startOffset, y: bottom - startSize.height / 2),
            .layout: CGPoint(x: containerSize.width / 2 - hudOffset,     y: bottom - hudSize.height / 2),
            .menu:   CGPoint(x: containerSize.width / 2 + hudOffset,     y: bottom - hudSize.height / 2),
            // Directly ABOVE Menu rather than further out along the row:
            // extending the row sideways walked it into the face-button
            // cluster, and the space above the bottom row is already where
            // this chrome floats.
            .fastForward: CGPoint(x: containerSize.width / 2 + hudOffset,
                                  y: bottom - hudSize.height / 2 - hudSize.height - hudPairSpacing),
        ]
    }

    // MARK: HUD (Menu / Layout) column

    /// The free column between the two thumb clusters, where the floating
    /// Menu/Layout pair lives. It is off-center by a few points because the
    /// d-pad and the ABXY diamond aren't the same width — centering the pair
    /// on the view's centerX instead would push it under the X/Y buttons on
    /// narrow phones.
    public static func hudColumnCenterX(containerWidth: CGFloat,
                                        idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGFloat {
        let s = spacing(for: idiom)
        let dpadRight = s.margin + size(.dpad, idiom).width
        let faceLeft = containerWidth - s.margin - 2 * faceClusterRadius(for: idiom)
        return (dpadRight + faceLeft) / 2
    }

    /// How wide that column is. `NDSHUDView` caps its status badges to this
    /// so a long translation shrinks to fit instead of spilling sideways onto
    /// the d-pad and the ABXY diamond.
    public static func hudColumnWidth(containerWidth: CGFloat,
                                      idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGFloat {
        let s = spacing(for: idiom)
        let dpadRight = s.margin + size(.dpad, idiom).width
        let faceLeft = containerWidth - s.margin - 2 * faceClusterRadius(for: idiom)
        return max(0, faceLeft - dpadRight)
    }

    /// Distance from the content rect's bottom edge up to the vertical center
    /// of that column (the main button row's center).
    public static func hudCenterYFromBottom(idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> CGFloat {
        height(for: idiom) - rowCenters(for: idiom).main
    }
}

// MARK: - Default Layout Factory

public extension INDSCustomControllerLayout {

    /// Defaults for a specific content rect. `NDSControllerView` calls this
    /// with the exact rect it is about to lay out in, so the band lands
    /// pixel-correct on the device actually in use; the no-argument version
    /// below is only for callers with no live geometry (the layout editor's
    /// "Reset to Defaults", `healed()`).
    static func defaultLayout(portraitContainer: CGSize,
                              landscapeContainer: CGSize,
                              idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> INDSCustomControllerLayout {
        INDSCustomControllerLayout(name: "Default",
                                   portrait: defaultPortrait(containerSize: portraitContainer, idiom: idiom),
                                   landscape: defaultLandscape(containerSize: landscapeContainer, idiom: idiom))
    }

    static func defaultLayout() -> INDSCustomControllerLayout {
        let reference = INDSControllerLayout.referenceContainerSizes()
        return defaultLayout(portraitContainer: reference.portrait, landscapeContainer: reference.landscape)
    }

    /// Portrait: the two DS screens stack in the top part of the view (see
    /// `DSScreenGeometry`, which reserves `INDSControlBand.height` for this
    /// strip), and everything below is controls: L/R across the top of the
    /// strip, d-pad and the ABXY diamond on the main row with the Menu/Layout
    /// pair in the gap between them, SELECT/START underneath.
    ///
    /// v1.0(1) put L/R at the screen's top corners, unreachable while holding
    /// the phone; v1.0(8) moved them into the strip but, with no strip
    /// actually reserved, they overlapped both the touch screen and the d-pad.
    static func defaultPortrait(containerSize: CGSize,
                                idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> INDSControllerLayout {
        let idiom = INDSControlBand.effectiveIdiom(for: containerSize, device: idiom)
        return ControllerLayout(buttons: INDSControllerLayout.entries(
            from: INDSControlBand.portraitCenters(in: containerSize, idiom: idiom), in: containerSize))
    }

    /// Landscape: screens sit side by side, spanning the full width with
    /// little to no side margin — so controls necessarily overlay the screens'
    /// outer corners, translucently. L/R are explicitly placed and visible
    /// here: a persisted layout from an older version that predates a button
    /// must still get it back via `healed()`, the same real bug iGBA shipped
    /// once for its landscape defaults.
    static func defaultLandscape(containerSize: CGSize,
                                 idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> INDSControllerLayout {
        let idiom = INDSControlBand.effectiveIdiom(for: containerSize, device: idiom)
        return ControllerLayout(buttons: INDSControllerLayout.entries(
            from: INDSControlBand.landscapeCenters(in: containerSize, idiom: idiom), in: containerSize))
    }

    // MARK: - Healing (persisted layouts from older app versions)

    /// Backfills any button missing from a persisted layout (added by a later
    /// app version) at today's default spot, visible. Without this, a stale
    /// JSON on disk permanently hides new buttons instead of just lacking the
    /// user's custom placement for them.
    func healed() -> (layout: INDSCustomControllerLayout, changed: Bool) {
        var changed = false
        let defaults = INDSCustomControllerLayout.defaultLayout()

        func heal(_ saved: INDSControllerLayout, against def: INDSControllerLayout) -> INDSControllerLayout {
            var result = saved
            let savedIDs = Set(saved.buttons.map(\.id))
            for defEntry in def.buttons where !savedIDs.contains(defEntry.id) {
                result.buttons.append(defEntry)
                changed = true
            }
            // `fillMissingButtons` runs first, at decode time, and invents a
            // hidden entry at dead centre for any button the saved JSON lacks —
            // which means a button added in a later version is already "present"
            // by the time we get here and the loop above skips it. That
            // placeholder is recognisable (hidden AND exactly 0.5/0.5; hiding a
            // button in the editor never moves it), so adopt the default for it.
            for (index, entry) in result.buttons.enumerated()
            where !entry.isVisible && entry.normalizedX == 0.5 && entry.normalizedY == 0.5 {
                guard let defEntry = def.buttons.first(where: { $0.id == entry.id }),
                      defEntry.isVisible else { continue }
                result.buttons[index] = defEntry
                changed = true
            }
            return result
        }

        var healedLayout = self
        healedLayout.portrait = heal(portrait, against: defaults.portrait)
        healedLayout.landscape = heal(landscape, against: defaults.landscape)
        return (healedLayout, changed)
    }
}

/// Local alias so the default-layout factory reads naturally without
/// repeating the `INDS` prefix on every line.
private typealias ControllerLayout = INDSControllerLayout
