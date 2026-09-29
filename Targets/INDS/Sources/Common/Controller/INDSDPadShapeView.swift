//
//  INDSDPadShapeView.swift
//  eDuo
//
//  New (no iGBA equivalent): iGBA's D-pad rendered a bundled xcassets image
//  ("DPAD.png"); eDuo ships with no controller-skin artwork at all, so this
//  draws an equivalent translucent cross purely with CAShapeLayer, matching
//  the same dark-fill / light-border language as `INDSStyledButtonView`.
//  Purely decorative — `NDSControllerView` still owns 9-zone hit testing over
//  this view's frame, exactly like it would over an image-based D-pad.
//

import UIKit

final class INDSDPadShapeView: UIView {

    private let fillLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private let arrowsLayer = CAShapeLayer()

    /// VoiceOver: this view is a focusable element (`NDSControllerView` names
    /// it) but takes no touches, so without custom actions it could be
    /// selected and never pressed. Each action fires one direction through
    /// the owner's press-and-release path.
    var onAccessibilityDirection: ((INDSButton) -> Void)? {
        didSet { configureAccessibilityActions() }
    }

    private func configureAccessibilityActions() {
        guard onAccessibilityDirection != nil else {
            accessibilityCustomActions = nil
            return
        }
        let directions: [(name: String, button: INDSButton)] = [
            (NSLocalizedString("Up", comment: "Mapping target"), .up),
            (NSLocalizedString("Down", comment: "Mapping target"), .down),
            (NSLocalizedString("Left", comment: "Mapping target"), .left),
            (NSLocalizedString("Right", comment: "Mapping target"), .right),
        ]
        accessibilityCustomActions = directions.map { direction in
            UIAccessibilityCustomAction(name: direction.name) { [weak self] _ in
                guard let handler = self?.onAccessibilityDirection else { return false }
                handler(direction.button)
                return true
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        fillLayer.fillColor = UIColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 0.9).cgColor
        strokeLayer.fillColor = UIColor.clear.cgColor
        strokeLayer.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
        strokeLayer.lineWidth = 1.5
        arrowsLayer.fillColor = UIColor.white.withAlphaComponent(0.55).cgColor

        layer.addSublayer(fillLayer)
        layer.addSublayer(strokeLayer)
        layer.addSublayer(arrowsLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }

        let cross = Self.crossPath(in: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = cross
        strokeLayer.path = cross
        arrowsLayer.path = Self.arrowsPath(in: bounds)
        CATransaction.commit()
    }

    /// A classic plus/cross shape, arm width = 1/3 of the container.
    private static func crossPath(in bounds: CGRect) -> CGPath {
        let armFraction: CGFloat = 1.0 / 3.0
        let armW = bounds.width * armFraction
        let armH = bounds.height * armFraction
        let cornerRadius = min(armW, armH) * 0.28

        let horizontal = CGRect(x: bounds.minX, y: bounds.midY - armH / 2, width: bounds.width, height: armH)
        let vertical = CGRect(x: bounds.midX - armW / 2, y: bounds.minY, width: armW, height: bounds.height)

        let path = UIBezierPath(roundedRect: horizontal, cornerRadius: cornerRadius)
        path.append(UIBezierPath(roundedRect: vertical, cornerRadius: cornerRadius))
        return path.cgPath
    }

    /// Small triangular direction indicators inside each arm.
    private static func arrowsPath(in bounds: CGRect) -> CGPath {
        let armFraction: CGFloat = 1.0 / 3.0
        let armW = bounds.width * armFraction
        let armH = bounds.height * armFraction
        let triSize = min(armW, armH) * 0.32
        let inset = min(armW, armH) * 0.62

        let path = UIBezierPath()
        // Up
        path.append(triangle(apex: CGPoint(x: bounds.midX, y: bounds.minY + inset - triSize), size: triSize, pointing: .up))
        // Down
        path.append(triangle(apex: CGPoint(x: bounds.midX, y: bounds.maxY - inset + triSize), size: triSize, pointing: .down))
        // Left
        path.append(triangle(apex: CGPoint(x: bounds.minX + inset - triSize, y: bounds.midY), size: triSize, pointing: .left))
        // Right
        path.append(triangle(apex: CGPoint(x: bounds.maxX - inset + triSize, y: bounds.midY), size: triSize, pointing: .right))
        return path.cgPath
    }

    private enum Direction { case up, down, left, right }

    private static func triangle(apex: CGPoint, size: CGFloat, pointing: Direction) -> UIBezierPath {
        let path = UIBezierPath()
        switch pointing {
        case .up:
            path.move(to: CGPoint(x: apex.x, y: apex.y - size / 2))
            path.addLine(to: CGPoint(x: apex.x - size / 2, y: apex.y + size / 2))
            path.addLine(to: CGPoint(x: apex.x + size / 2, y: apex.y + size / 2))
        case .down:
            path.move(to: CGPoint(x: apex.x, y: apex.y + size / 2))
            path.addLine(to: CGPoint(x: apex.x - size / 2, y: apex.y - size / 2))
            path.addLine(to: CGPoint(x: apex.x + size / 2, y: apex.y - size / 2))
        case .left:
            path.move(to: CGPoint(x: apex.x - size / 2, y: apex.y))
            path.addLine(to: CGPoint(x: apex.x + size / 2, y: apex.y - size / 2))
            path.addLine(to: CGPoint(x: apex.x + size / 2, y: apex.y + size / 2))
        case .right:
            path.move(to: CGPoint(x: apex.x + size / 2, y: apex.y))
            path.addLine(to: CGPoint(x: apex.x - size / 2, y: apex.y - size / 2))
            path.addLine(to: CGPoint(x: apex.x - size / 2, y: apex.y + size / 2))
        }
        path.close()
        return path
    }
}
