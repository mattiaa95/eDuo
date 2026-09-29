//
//  INDSVirtualJoystickView.swift
//  eDuo
//
//  Ported near-verbatim from iGBA's VirtualJoystickView.swift.
//  Only the direction → button raw-value mapping changed (INDSButton's
//  Up/Down/Left/Right instead of GBAControllerButton's).
//

import UIKit

/// A virtual joystick that maps touch input to 8-direction D-pad buttons.
///
/// Touch area is circular. A dead zone (15% radius) prevents accidental
/// inputs. The thumb indicator follows the touch within the joystick radius.
/// Directions are split into 8 equal 45° sectors.
final class INDSVirtualJoystickView: UIView {

    // MARK: - Configuration

    /// Fraction of radius considered dead zone (no input). Default: 0.15
    var deadZoneFraction: CGFloat = 0.15

    /// Opacity of the base ring.
    var baseAlpha: CGFloat = 0.3 { didSet { baseLayer.opacity = Float(baseAlpha) } }

    /// Opacity of the thumb indicator when active.
    var thumbAlpha: CGFloat = 0.7

    // MARK: - Output

    /// Current set of pressed direction buttons (INDSButton raw values). Empty when idle.
    private(set) var pressedDirections: Set<Int> = []

    /// Called whenever the pressed directions change.
    var onDirectionsChanged: ((Set<Int>) -> Void)?

    // MARK: - Visual Layers

    private let baseLayer = CAShapeLayer()
    private let thumbLayer = CAShapeLayer()
    private let thumbRadius: CGFloat = 18

    // MARK: - State

    private var activeTouch: UITouch?
    private var joystickCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var joystickRadius: CGFloat { min(bounds.width, bounds.height) / 2 }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = false
        backgroundColor = .clear

        baseLayer.fillColor = UIColor(white: 0.3, alpha: 0.6).cgColor
        baseLayer.strokeColor = UIColor.white.cgColor
        baseLayer.lineWidth = 2
        baseLayer.opacity = Float(baseAlpha)
        layer.addSublayer(baseLayer)

        thumbLayer.fillColor = UIColor.white.cgColor
        thumbLayer.opacity = 0
        layer.addSublayer(thumbLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = joystickCenter
        let radius = joystickRadius

        baseLayer.path = UIBezierPath(arcCenter: center, radius: radius - 1,
                                       startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

        resetThumb()
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        handleTouch(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        handleTouch(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        releaseJoystick()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        releaseJoystick()
    }

    // MARK: - Direction Computation

    private func handleTouch(_ touch: UITouch) {
        let point = touch.location(in: self)
        let center = joystickCenter
        let radius = joystickRadius

        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)

        let clampedDistance = min(distance, radius - thumbRadius)
        let angle = atan2(dy, dx)
        let thumbX = center.x + cos(angle) * clampedDistance
        let thumbY = center.y + sin(angle) * clampedDistance

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.path = UIBezierPath(arcCenter: CGPoint(x: thumbX, y: thumbY),
                                        radius: thumbRadius,
                                        startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        thumbLayer.opacity = Float(thumbAlpha)
        CATransaction.commit()

        let deadZone = radius * deadZoneFraction
        var newDirections: Set<Int> = []

        if distance > deadZone {
            var degrees = angle * 180 / .pi
            if degrees < 0 { degrees += 360 }
            newDirections = Self.directionsForAngle(degrees)
        }

        if newDirections != pressedDirections {
            pressedDirections = newDirections
            onDirectionsChanged?(newDirections)
        }
    }

    private func releaseJoystick() {
        activeTouch = nil
        resetThumb()

        if !pressedDirections.isEmpty {
            pressedDirections = []
            onDirectionsChanged?([])
        }
    }

    private func resetThumb() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.path = UIBezierPath(arcCenter: joystickCenter,
                                        radius: thumbRadius,
                                        startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        thumbLayer.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Angle → Directions

    /// Maps an angle in degrees to a set of INDSButton direction raw values.
    /// Uses 8 sectors of 45° each.
    static func directionsForAngle(_ degrees: CGFloat) -> Set<Int> {
        let up    = INDSButton.up.rawValue
        let down  = INDSButton.down.rawValue
        let left  = INDSButton.left.rawValue
        let right = INDSButton.right.rawValue

        let d = degrees.truncatingRemainder(dividingBy: 360)
        let angle = d < 0 ? d + 360 : d

        if angle >= 337.5 || angle < 22.5    { return [right] }
        if angle >= 22.5  && angle < 67.5    { return [right, down] }
        if angle >= 67.5  && angle < 112.5   { return [down] }
        if angle >= 112.5 && angle < 157.5   { return [down, left] }
        if angle >= 157.5 && angle < 202.5   { return [left] }
        if angle >= 202.5 && angle < 247.5   { return [left, up] }
        if angle >= 247.5 && angle < 292.5   { return [up] }
        if angle >= 292.5 && angle < 337.5   { return [up, right] }

        return []
    }

    // MARK: - External Control

    /// Forcefully cancels any active tracking. Called by the parent view during teardown.
    func cancelTracking() {
        if activeTouch != nil {
            releaseJoystick()
        }
    }

    // MARK: - Hit Test

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let center = joystickCenter
        let radius = joystickRadius
        return hypot(point.x - center.x, point.y - center.y) <= radius
    }
}
