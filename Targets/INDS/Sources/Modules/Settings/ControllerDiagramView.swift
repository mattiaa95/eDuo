//
//  ControllerDiagramView.swift
//  eDuo
//
//  Ported from iGBA (ControllerGlyphs + ControllerDiagramView): the
//  controller is DRAWN. Each button sits where it is on the real one; a
//  physical press lights it up and sinks it, and tapping it here selects it,
//  so nobody has to guess which one is «L2» or which centre button is «View».
//  Names and symbols come from iOS for the connected pad (✕○△□ on
//  PlayStation, LB/RT on Xbox, ZL/ZR on Switch), falling back to generic ones.
//
import GameController
import SwiftUI

/// La forma del mando, para dibujarlo: con los sticks abajo y simétricos
/// (PlayStation) o con el izquierdo arriba (Xbox, Switch Pro, casi todos los
/// de móvil: Backbone, Kishi, 8BitDo).
enum ControllerStyle {
    case xbox, playstation, nintendo, generic

    static func of(_ controller: GCController?) -> ControllerStyle {
        guard let controller else { return .generic }
        if controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad {
            return .playstation
        }
        if controller.extendedGamepad is GCXboxGamepad { return .xbox }
        let category = controller.productCategory.lowercased()
        if category.contains("dualsense") || category.contains("dualshock") { return .playstation }
        if category.contains("xbox") { return .xbox }
        if category.contains("switch") || category.contains("joy-con") || category.contains("nintendo") { return .nintendo }
        return .generic
    }

    var hasSymmetricSticks: Bool { self == .playstation }
}

struct ControllerGlyph {
    /// Lo que pone en el botón ("LB", "Cross", "A").
    let name: String
    /// SF Symbol del botón físico.
    let symbol: String
}

enum ControllerGlyphs {

    private static let fallbackSymbol: [String: String] = [
        "A": "a.circle.fill", "B": "b.circle.fill", "X": "x.circle.fill", "Y": "y.circle.fill",
        "L1": "l1.rectangle.roundedbottom.fill", "R1": "r1.rectangle.roundedbottom.fill",
        "L2": "l2.rectangle.roundedtop.fill", "R2": "r2.rectangle.roundedtop.fill",
        "L3": "l.joystick.press.down.fill", "R3": "r.joystick.press.down.fill",
        "Options": "rectangle.fill.on.rectangle.fill", "Menu": "line.3.horizontal.circle.fill",
        "Home": "house.circle.fill", "Share": "square.and.arrow.up.circle.fill",
        "Up": "dpad.up.filled", "Down": "dpad.down.filled",
        "Left": "dpad.left.filled", "Right": "dpad.right.filled",
    ]

    private static func fallbackName(_ key: String) -> String {
        switch key {
        case "Up": return NSLocalizedString("D-pad up", comment: "Physical controller button")
        case "Down": return NSLocalizedString("D-pad down", comment: "Physical controller button")
        case "Left": return NSLocalizedString("D-pad left", comment: "Physical controller button")
        case "Right": return NSLocalizedString("D-pad right", comment: "Physical controller button")
        case "Options": return NSLocalizedString("Options / View", comment: "Physical controller button: the small left centre button")
        case "Menu": return NSLocalizedString("Menu", comment: "Physical controller button: the small right centre button")
        case "Home": return NSLocalizedString("Home", comment: "Physical controller button: the logo button")
        case "Share": return NSLocalizedString("Share", comment: "Physical controller button")
        default: return key
        }
    }

    /// El elemento físico de una clave, también las direcciones de la cruceta.
    static func element(for key: String, on controller: GCController?) -> GCControllerButtonInput? {
        guard let controller else { return nil }
        return INDSControllerElements.button(key, on: controller)
    }

    /// Un símbolo que no existe en esta versión de iOS pinta un hueco en blanco.
    private static func available(_ symbol: String?) -> String? {
        guard let symbol, UIImage(systemName: symbol) != nil else { return nil }
        return symbol
    }

    static func glyph(for key: String, on controller: GCController?) -> ControllerGlyph {
        let fallback = available(fallbackSymbol[key]) ?? "circle.fill"
        guard let element = element(for: key, on: controller) else {
            return ControllerGlyph(name: fallbackName(key), symbol: fallback)
        }
        let name = element.localizedName ?? fallbackName(key)
        guard let symbol = available(element.sfSymbolsName) else {
            return ControllerGlyph(name: name, symbol: fallback)
        }
        // Lo relleno se lee mejor sobre el dibujo; no todos los símbolos lo tienen.
        let filled = symbol.hasSuffix(".fill") || symbol.hasSuffix(".filled") ? symbol : symbol + ".fill"
        return ControllerGlyph(name: name, symbol: available(filled) ?? symbol)
    }

    /// ¿Tiene este mando ese botón? Sin mando conectado se enseñan todos.
    static func exists(_ key: String, on controller: GCController?) -> Bool {
        guard let controller else { return true }
        return element(for: key, on: controller) != nil
    }

    static func hasStick(_ controller: GCController?) -> Bool {
        guard let controller else { return true }
        return INDSControllerElements.thumbstick(on: controller) != nil
    }
}

struct ControllerDiagramView: View {
    let style: ControllerStyle
    let controller: GCController?
    let mapping: [String: Int]
    let pressed: Set<String>
    let selected: String?
    /// Esperando a que se pulse un botón para asignarle una acción.
    let capturing: Bool
    let onTap: (String) -> Void

    static let aspect: CGFloat = 1.62

    private struct Spot {
        let key: String
        let center: CGPoint
        let kind: Kind
    }

    private enum Kind {
        case face, trigger, shoulder, stick, small, dpad
    }

    private var spots: [Spot] {
        let symmetric = style.hasSymmetricSticks
        let dpad = symmetric ? CGPoint(x: 0.25, y: 0.42) : CGPoint(x: 0.37, y: 0.66)
        let leftStick = symmetric ? CGPoint(x: 0.37, y: 0.68) : CGPoint(x: 0.25, y: 0.42)
        let rightStick = symmetric ? CGPoint(x: 0.63, y: 0.68) : CGPoint(x: 0.63, y: 0.66)
        let face = CGPoint(x: 0.75, y: 0.42)
        let faceOffset: CGFloat = 0.075
        var out: [Spot] = [
            Spot(key: "L2", center: CGPoint(x: 0.21, y: 0.06), kind: .trigger),
            Spot(key: "R2", center: CGPoint(x: 0.79, y: 0.06), kind: .trigger),
            Spot(key: "L1", center: CGPoint(x: 0.22, y: 0.17), kind: .shoulder),
            Spot(key: "R1", center: CGPoint(x: 0.78, y: 0.17), kind: .shoulder),
            Spot(key: "L3", center: leftStick, kind: .stick),
            Spot(key: "R3", center: rightStick, kind: .stick),
            // Posiciones de Apple: A abajo, B derecha, X izquierda, Y arriba.
            Spot(key: "A", center: CGPoint(x: face.x, y: face.y + faceOffset * Self.aspect), kind: .face),
            Spot(key: "B", center: CGPoint(x: face.x + faceOffset, y: face.y), kind: .face),
            Spot(key: "X", center: CGPoint(x: face.x - faceOffset, y: face.y), kind: .face),
            Spot(key: "Y", center: CGPoint(x: face.x, y: face.y - faceOffset * Self.aspect), kind: .face),
        ]
        let arm: CGFloat = 0.058
        out += [
            Spot(key: "Up", center: CGPoint(x: dpad.x, y: dpad.y - arm * Self.aspect), kind: .dpad),
            Spot(key: "Down", center: CGPoint(x: dpad.x, y: dpad.y + arm * Self.aspect), kind: .dpad),
            Spot(key: "Left", center: CGPoint(x: dpad.x - arm, y: dpad.y), kind: .dpad),
            Spot(key: "Right", center: CGPoint(x: dpad.x + arm, y: dpad.y), kind: .dpad),
        ]
        if symmetric {
            out += [
                Spot(key: "Options", center: CGPoint(x: 0.33, y: 0.24), kind: .small),
                Spot(key: "Menu", center: CGPoint(x: 0.67, y: 0.24), kind: .small),
                Spot(key: "Share", center: CGPoint(x: 0.5, y: 0.32), kind: .small),
                Spot(key: "Home", center: CGPoint(x: 0.5, y: 0.66), kind: .small),
            ]
        } else {
            out += [
                Spot(key: "Options", center: CGPoint(x: 0.42, y: 0.42), kind: .small),
                Spot(key: "Menu", center: CGPoint(x: 0.58, y: 0.42), kind: .small),
                Spot(key: "Home", center: CGPoint(x: 0.5, y: 0.25), kind: .small),
                Spot(key: "Share", center: CGPoint(x: 0.5, y: 0.55), kind: .small),
            ]
        }
        return out.filter { ControllerGlyphs.exists($0.key, on: controller) }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                ControllerBodyShape()
                    .fill(LinearGradient(colors: [Color(UIColor.systemGray4), Color(UIColor.systemGray5)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

                // La cruz de la cruceta, debajo de sus cuatro brazos.
                if let up = spots.first(where: { $0.key == "Up" }) {
                    let center = CGPoint(x: up.center.x, y: up.center.y + 0.058 * Self.aspect)
                    DPadCross()
                        .fill(Color(UIColor.systemGray2))
                        .frame(width: w * 0.17, height: w * 0.17)
                        .position(x: center.x * w, y: center.y * h)
                }

                ForEach(spots, id: \.key) { spot in
                    element(spot, width: w)
                        .position(x: spot.center.x * w, y: spot.center.y * h)
                }

                if capturing {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .opacity(0.8)
                }
            }
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Controller", comment: "Accessibility: controller drawing"))
    }

    // MARK: - One button

    @ViewBuilder
    private func element(_ spot: Spot, width w: CGFloat) -> some View {
        let isPressed = pressed.contains(spot.key)
        let isSelected = selected == spot.key
        let glyph = ControllerGlyphs.glyph(for: spot.key, on: controller)
        let target = INDSMappingTarget(rawValue: mapping[spot.key] ?? INDSMappingTarget.none.rawValue) ?? .none
        let changed = mapping[spot.key] != INDSMappingLogic.defaultMapping[spot.key]
        let size = size(of: spot.kind, width: w)

        Button {
            onTap(spot.key)
        } label: {
            ZStack {
                shape(of: spot.kind)
                    .fill(isPressed ? Color.accentColor : fill(of: spot.kind))
                    .shadow(color: isPressed ? Color.accentColor.opacity(0.8) : .black.opacity(0.15),
                            radius: isPressed ? 10 : 2, y: isPressed ? 0 : 1)
                if spot.kind == .dpad {
                    Image(systemName: arrow(for: spot.key))
                        .font(.system(size: size.height * 0.42, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: glyph.symbol)
                        .resizable()
                        .scaledToFit()
                        .padding(spot.kind == .stick ? size.height * 0.26 : size.height * 0.12)
                        .foregroundColor(.white)
                }
                shape(of: spot.kind)
                    .stroke(Color.accentColor, lineWidth: isSelected ? 3 : 0)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topTrailing) {
                if changed {
                    badge(for: target)
                        .offset(x: 7, y: -7)
                }
            }
            .scaleEffect(isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: isPressed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(glyph.name)
        .accessibilityValue(target.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Lo que hace ahora, en pequeño, cuando no es lo de fábrica.
    private func badge(for target: INDSMappingTarget) -> some View {
        ZStack {
            Circle().fill(target == .none ? Color(UIColor.systemGray) : Color.orange)
            if target.shortLabel.isEmpty {
                Image(systemName: target.symbol)
                    .font(.system(size: 8, weight: .bold))
            } else {
                Text(target.shortLabel)
                    .font(.system(size: 8, weight: .heavy))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .foregroundColor(.white)
        .frame(width: 17, height: 17)
        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
    }

    private func size(of kind: Kind, width w: CGFloat) -> CGSize {
        switch kind {
        case .face: return CGSize(width: w * 0.075, height: w * 0.075)
        case .trigger: return CGSize(width: w * 0.15, height: w * 0.075)
        case .shoulder: return CGSize(width: w * 0.19, height: w * 0.06)
        case .stick: return CGSize(width: w * 0.13, height: w * 0.13)
        case .small: return CGSize(width: w * 0.055, height: w * 0.055)
        case .dpad: return CGSize(width: w * 0.058, height: w * 0.058)
        }
    }

    private func shape(of kind: Kind) -> ElementShape {
        switch kind {
        case .face, .stick, .small: return ElementShape(form: .circle)
        case .trigger: return ElementShape(form: .trigger)
        case .shoulder: return ElementShape(form: .capsule)
        case .dpad: return ElementShape(form: .rounded)
        }
    }

    private func fill(of kind: Kind) -> Color {
        switch kind {
        case .stick: return Color(UIColor.darkGray)
        case .small: return Color(UIColor.systemGray)
        default: return Color(UIColor.systemGray2).opacity(0.95)
        }
    }

    private func arrow(for key: String) -> String {
        switch key {
        case "Up": return "arrowtriangle.up.fill"
        case "Down": return "arrowtriangle.down.fill"
        case "Left": return "arrowtriangle.left.fill"
        default: return "arrowtriangle.right.fill"
        }
    }
}

// MARK: - Shapes

/// Cuerpo con dos empuñaduras: un rectángulo redondeado y dos óvalos
/// inclinados. Sin contorno, así la unión no enseña costuras.
private struct ControllerBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.addRoundedRect(in: CGRect(x: w * 0.08, y: h * 0.12, width: w * 0.84, height: h * 0.58),
                            cornerSize: CGSize(width: h * 0.24, height: h * 0.24))
        for (cx, angle) in [(0.2, -18.0), (0.8, 18.0)] {
            let grip = CGRect(x: -w * 0.12, y: -h * 0.27, width: w * 0.24, height: h * 0.54)
            let transform = CGAffineTransform(translationX: w * cx, y: h * 0.68)
                .rotated(by: angle * .pi / 180)
            path.addPath(Path(roundedRect: grip, cornerRadius: w * 0.11), transform: transform)
        }
        return path
    }
}

private struct DPadCross: Shape {
    func path(in rect: CGRect) -> Path {
        let t = rect.width * 0.36
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.midX - t / 2, y: rect.minY, width: t, height: rect.height),
                            cornerSize: CGSize(width: 4, height: 4))
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.midY - t / 2, width: rect.width, height: t),
                            cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

/// La forma de un botón. Gatillo: redondeado arriba, recto abajo (iOS 15 no
/// tiene UnevenRoundedRectangle ni AnyShape).
private struct ElementShape: Shape {
    enum Form { case circle, trigger, capsule, rounded }
    let form: Form

    func path(in rect: CGRect) -> Path {
        switch form {
        case .circle:
            return Circle().path(in: rect)
        case .capsule:
            return Capsule().path(in: rect)
        case .rounded:
            return RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: rect)
        case .trigger:
            let r = min(12, rect.height / 2, rect.width / 2)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
            path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
