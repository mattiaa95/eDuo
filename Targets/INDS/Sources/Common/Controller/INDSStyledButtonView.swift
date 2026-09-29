//
//  INDSStyledButtonView.swift
//  eDuo
//
//  Ported and adapted from the private `StyledControllerButtonView` nested in
//  iGBA's CustomControllerView.swift. Renders a single
//  on-screen button from an `INDSButtonStyle` (vector text, or an imported
//  image). No macro-slot gesture handling here (eDuo has no macros) — this
//  view is purely visual; `NDSControllerView` owns all touch/hit-testing.
//

import UIKit

final class INDSStyledButtonView: UIView {

    let buttonID: INDSControllerButtonID
    let style: INDSButtonStyle

    private let imageView = UIImageView()
    private let label = UILabel()

    init(buttonID: INDSControllerButtonID, style: INDSButtonStyle) {
        self.buttonID = buttonID
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false

        switch style.kind {
        case .image:
            // A persisted `.image` style with missing/undecodable data used to
            // render a fully invisible (but still tappable) button in iGBA —
            // fall back to the text style instead of leaving nothing at all.
            if let custom = style.customImage() {
                imageView.image = custom
                imageView.contentMode = .scaleAspectFit
                imageView.clipsToBounds = false
                addSubview(imageView)
            } else {
                configureTextStyle()
            }
        case .text:
            configureTextStyle()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Set by `NDSControllerView`. VoiceOver's double-tap has to land here
    /// because this view has `isUserInteractionEnabled = false` and never sees
    /// a touch — the parent owns multi-touch resolution for the whole overlay.
    var onAccessibilityActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        guard let onAccessibilityActivate else { return false }
        onAccessibilityActivate()
        return true
    }

    private func configureTextStyle() {
        backgroundColor = style.backgroundColor()
        layer.borderColor = style.borderColor().cgColor
        layer.borderWidth = CGFloat(style.borderWidth)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.numberOfLines = 1
        label.textColor = style.textColor()
        label.text = (style.label?.isEmpty == false) ? style.label : buttonID.defaultStyleLabel
        addSubview(label)
    }

    /// Called by `NDSControllerView.updateButtonFrames` whenever the frame
    /// changes so size-dependent properties (font size, corner radius) stay
    /// in sync without rebuilding the whole layout.
    func updateForSize(_ size: CGSize) {
        switch style.kind {
        case .image where imageView.superview != nil:
            imageView.frame = bounds
        default:
            layer.cornerRadius = style.cornerRadius(for: size)
            label.frame = bounds.insetBy(dx: max(2, CGFloat(style.borderWidth)),
                                         dy: max(2, CGFloat(style.borderWidth)))
            label.font = style.uiFont(forSize: size)
        }
    }
}
