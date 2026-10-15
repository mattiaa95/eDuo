//
//  DSHinge.swift
//  eDuo
//
//  Where a folding iPhone's crease is, read from the system instead of
//  guessed: `UIView.reservedRegions(kind: .division)` (iOS 27.1 SDK) gives the
//  band the hinge takes, and `.occlusion` gives what covers the display (the
//  clock rail). Measured on the Duo simulator, 21-sep-2026: with the display
//  open (669×951) the division region is `{0, 455.5} 669×40` — a 40 pt band
//  centred on the middle of the display — and the occlusion `{535, 0} 134×82`.
//
//  Everything here is in the owning view's coordinates, shifted by the
//  content rect's origin so the layouts (which work in the safe-area rect)
//  can use the numbers as they are.
//

import UIKit

/// The crease, in the content rect's own coordinates.
struct DSHingeBand: Equatable {
    /// True when the band runs top to bottom (the display is held like a
    /// book: screens side by side). False: it runs left to right and the
    /// screens stack.
    var isVertical: Bool
    /// y (horizontal band) or x (vertical band) of the band's middle.
    var center: CGFloat
    /// Half the band's thickness. Nothing is drawn or touchable inside it.
    var half: CGFloat
    /// Areas the system draws over the display (clock rail, sensors).
    var occlusions: [CGRect] = []

    /// 40 pt measured on the Duo; used when a guess has to stand in.
    static let defaultHalf: CGFloat = 20

    /// The edge of the band nearer to the content's origin, and the farther one.
    var leadingEdge: CGFloat { center - half }
    var trailingEdge: CGFloat { center + half }
}

enum DSHingeState: Equatable {
    /// The system can't tell (SDK or OS before iOS 27.1): fall back to the
    /// size heuristic in `DSFoldableLayout.isUnfolded`.
    case unknown
    /// The system can tell, and there is no active crease: a closed Duo
    /// (outer display), or any other phone or iPad.
    case none
    case band(DSHingeBand)

    /// Layout checks (`-iNDSDuoSweep`) compose views that are not in a window
    /// at the measured Duo geometry; this stands in for the system's answer.
    static var override: DSHingeState?

    /// Asks `view` (which must be in a window) about the crease. `content` is
    /// the rect the layouts work in, in `view` coordinates.
    static func resolve(for view: UIView, content: CGRect) -> DSHingeState {
        if let override { return override }
        // ponytail: reservedRegions only exists in the iOS 27.1 SDK (UIKit
        // 9127.0.85; 27.0 is .84). An older toolchain builds without it.
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            guard view.window != nil else { return .unknown }
            // ⚠️Measured (Duo simulator, 10-oct-2026): the division region is
            // ACTIVE only while the hinge is partially open. Flat open it is
            // reported INACTIVE, with the same frame (`{0,455.5} 669×40`
            // portrait, `{455.5,0} 40×669` landscape) — the crease is still
            // in the glass, so the screens keep to its two halves. Folded
            // (outer display) there is no region at all. So: any region that
            // lies on this view's display counts, active or not.
            let divisions = view.reservedRegions(kind: .division, options: [.includeInactive])
                .filter { $0.frame.intersects(view.bounds) }
            guard let division = divisions.first else { return .none }
            let frame = division.frame
            // The frame includes the margins around the reserved rect, and
            // margins are symmetric on the crease: its thickness is the
            // frame's short side.
            let isVertical = frame.height > frame.width
            let thickness = isVertical ? frame.width : frame.height
            let origin = content.origin
            let center = isVertical ? frame.midX - origin.x : frame.midY - origin.y
            let occlusions = view.reservedRegions(kind: .occlusion).filter(\.isActive)
                .map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }
            return .band(DSHingeBand(isVertical: isVertical, center: center,
                                     half: thickness / 2, occlusions: occlusions))
        }
        #endif
        return .unknown
    }
}
