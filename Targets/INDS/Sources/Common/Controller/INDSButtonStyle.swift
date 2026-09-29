//
//  INDSButtonStyle.swift
//  eDuo
//
//  Ported and adapted from iGBA's ButtonStyle.swift.
//  Per-button visual style: text/colors/border, or a user-imported image.
//  eDuo ships with no bundled controller-skin artwork (unlike iGBA's legacy
//  xcassets skin), so unlike the original there is no `.asset` fallback kind —
//  every button renders as a vector shape unless the user later imports a
//  custom image via the (deferred) layout editor.
//
//  Field shape intentionally mirrors iGBA's `ButtonStyle` 1:1 (fontName,
//  fontWeightRaw, etc.) even though nothing here sets them yet, so a future
//  port of ControllerLayoutEditorView / ButtonStyleEditorSheet is a drop-in.
//

import Foundation
import UIKit

// MARK: - Style Kind

public enum INDSButtonStyleKind: Int, Codable, CaseIterable {
    /// Vector button: text label + background + border.
    case text = 0
    /// User-imported image (PNG/JPEG data).
    case image = 1
}

// MARK: - Color hex helpers

public enum INDSButtonStyleColor {
    /// Encode a UIColor as `#RRGGBBAA`.
    public static func encode(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(max(0, min(1, r)) * 255))
        let gi = Int(round(max(0, min(1, g)) * 255))
        let bi = Int(round(max(0, min(1, b)) * 255))
        let ai = Int(round(max(0, min(1, a)) * 255))
        return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
    }

    /// Decode `#RGB`, `#RRGGBB`, or `#RRGGBBAA` strings to UIColor. Returns nil on failure.
    public static func decode(_ hex: String) -> UIColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: UInt64
        switch s.count {
        case 3:
            r = (value >> 8) & 0xF; g = (value >> 4) & 0xF; b = value & 0xF; a = 0xF
            return UIColor(red: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255,
                           blue: CGFloat(b * 17) / 255, alpha: CGFloat(a * 17) / 255)
        case 6:
            r = (value >> 16) & 0xFF; g = (value >> 8) & 0xFF; b = value & 0xFF; a = 0xFF
        case 8:
            r = (value >> 24) & 0xFF; g = (value >> 16) & 0xFF; b = (value >> 8) & 0xFF; a = value & 0xFF
        default:
            return nil
        }
        return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

// MARK: - Button Style

/// Per-button visual style. All fields have safe defaults so a partially
/// specified JSON still decodes; a `nil` style on a `INDSButtonLayoutEntry`
/// means "use the default vector look for this button".
public struct INDSButtonStyle: Codable, Equatable {
    public var kind: INDSButtonStyleKind

    // Text styling
    public var label: String?
    public var fontName: String?
    /// UIFont.Weight rawValue mapped to 0...1. Stored as Double for Codable.
    public var fontWeightRaw: Double
    /// Fraction of the button's min(width,height); 0.4 ≈ classic, 0.6 ≈ big.
    public var fontSizeFraction: Double
    public var textColorHex: String

    // Shape styling
    public var backgroundColorHex: String
    public var borderColorHex: String
    public var borderWidth: Double
    /// Corner radius as fraction of min(width,height). 0.5 = pill.
    public var cornerRadiusFraction: Double

    // Custom image
    public var customImageData: Data?

    public init(kind: INDSButtonStyleKind = .text,
                label: String? = nil,
                fontName: String? = nil,
                fontWeightRaw: Double = 0.6,
                fontSizeFraction: Double = 0.42,
                textColorHex: String = "#FFFFFFFF",
                backgroundColorHex: String = "#1F1F2EE6",
                borderColorHex: String = "#FFFFFFCC",
                borderWidth: Double = 2,
                cornerRadiusFraction: Double = 0.3,
                customImageData: Data? = nil) {
        self.kind = kind
        self.label = label
        self.fontName = fontName
        self.fontWeightRaw = fontWeightRaw
        self.fontSizeFraction = fontSizeFraction
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.borderColorHex = borderColorHex
        self.borderWidth = borderWidth
        self.cornerRadiusFraction = cornerRadiusFraction
        self.customImageData = customImageData
    }

    // Backward/forward-compatible decoding: any missing field uses defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = INDSButtonStyle()
        self.kind = (try? c.decode(INDSButtonStyleKind.self, forKey: .kind)) ?? defaults.kind
        self.label = try? c.decode(String.self, forKey: .label)
        self.fontName = try? c.decode(String.self, forKey: .fontName)
        self.fontWeightRaw = (try? c.decode(Double.self, forKey: .fontWeightRaw)) ?? defaults.fontWeightRaw
        self.fontSizeFraction = (try? c.decode(Double.self, forKey: .fontSizeFraction)) ?? defaults.fontSizeFraction
        self.textColorHex = (try? c.decode(String.self, forKey: .textColorHex)) ?? defaults.textColorHex
        self.backgroundColorHex = (try? c.decode(String.self, forKey: .backgroundColorHex)) ?? defaults.backgroundColorHex
        self.borderColorHex = (try? c.decode(String.self, forKey: .borderColorHex)) ?? defaults.borderColorHex
        self.borderWidth = (try? c.decode(Double.self, forKey: .borderWidth)) ?? defaults.borderWidth
        self.cornerRadiusFraction = (try? c.decode(Double.self, forKey: .cornerRadiusFraction)) ?? defaults.cornerRadiusFraction
        self.customImageData = try? c.decode(Data.self, forKey: .customImageData)
    }

    // MARK: Derived

    public var fontWeight: UIFont.Weight {
        let weights: [UIFont.Weight] = [
            .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black
        ]
        let idx = max(0, min(weights.count - 1, Int(round(fontWeightRaw * Double(weights.count - 1)))))
        return weights[idx]
    }

    public func uiFont(forSize size: CGSize) -> UIFont {
        let pointSize = max(8, min(size.width, size.height) * CGFloat(fontSizeFraction))
        if let name = fontName, !name.isEmpty, let custom = UIFont(name: name, size: pointSize) {
            let descriptor = custom.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: fontWeight]
            ])
            return UIFont(descriptor: descriptor, size: pointSize)
        }
        return UIFont.systemFont(ofSize: pointSize, weight: fontWeight)
    }

    public func textColor() -> UIColor {
        INDSButtonStyleColor.decode(textColorHex) ?? .white
    }

    public func backgroundColor() -> UIColor {
        INDSButtonStyleColor.decode(backgroundColorHex) ?? UIColor.black.withAlphaComponent(0.6)
    }

    public func borderColor() -> UIColor {
        INDSButtonStyleColor.decode(borderColorHex) ?? UIColor.white.withAlphaComponent(0.8)
    }

    public func customImage() -> UIImage? {
        guard let data = customImageData else { return nil }
        return UIImage(data: data)
    }

    public func cornerRadius(for size: CGSize) -> CGFloat {
        let m = min(size.width, size.height)
        let frac = max(0, min(0.5, CGFloat(cornerRadiusFraction)))
        return m * frac
    }

    private enum CodingKeys: String, CodingKey {
        case kind, label, fontName, fontWeightRaw, fontSizeFraction, textColorHex
        case backgroundColorHex, borderColorHex, borderWidth, cornerRadiusFraction, customImageData
    }
}

// MARK: - Default style factory

public extension INDSButtonStyle {
    /// The look every button gets until the user customizes it (or imports a
    /// layout with one) — dark translucent fill, light border, bold label.
    static func defaultStyle(for id: INDSControllerButtonID) -> INDSButtonStyle {
        INDSButtonStyle(kind: .text, label: id.defaultStyleLabel)
    }
}
