//
//  INDSControllerMappingLogic.swift
//  eDuo
//
//  Lógica pura del mapeo del mando, portada de iGBA (ControllerMappingLogic):
//  qué botones físicos existen, qué puede hacer cada uno, cómo se migra lo
//  guardado, qué conflictos hay y a qué ritmo pulsa el turbo. Sin UIKit ni
//  GameController a propósito: scripts/controller_mapping_check.sh la compila
//  sola con swiftc y la prueba.
//
//  El formato guardado NO cambia: `[clave física: raw de INDSMappingTarget]`.
//  Solo se añaden claves (cruceta, L3, R3, Menu, Home, Share) y destinos
//  (avance rápido on/off, turbo on/off, rebobinar), así que un mapeo de la
//  1.0 se abre tal cual.
//

import Foundation

/// Lo que puede hacer un botón físico. Los botones DS valen lo mismo que
/// `INDSButton` (A=0 … Y=11); las acciones van de 50 en adelante.
/// NO renumerar: están guardados en UserDefaults.
enum INDSMappingTarget: Int, CaseIterable, Identifiable, Codable {
    case a = 0
    case b = 1
    case select = 2
    case start = 3
    case right = 4
    case left = 5
    case up = 6
    case down = 7
    case r = 8
    case l = 9
    case x = 10
    case y = 11

    case pause = 50
    case quickSave = 51
    case quickLoad = 52
    case cycleScreenLayout = 53
    case swapScreens = 54
    /// Mantener = rápido; un toque corto pasa a la siguiente velocidad.
    case fastForward = 55
    /// Un toque lo enciende, otro lo apaga.
    case fastForwardToggle = 56
    /// Enciende o apaga el turbo de los botones elegidos.
    case turboToggle = 57
    case rewind = 58

    case none = 99

    var id: Int { rawValue }

    var isDSButton: Bool { (0...11).contains(rawValue) }
    var isDirection: Bool { [.up, .down, .left, .right].contains(self) }

    static let consoleOrder: [INDSMappingTarget] = [.up, .down, .left, .right,
                                                    .a, .b, .x, .y, .l, .r, .start, .select]
    static let emulatorOrder: [INDSMappingTarget] = [.pause, .fastForward, .fastForwardToggle,
                                                     .turboToggle, .rewind, .quickSave, .quickLoad,
                                                     .cycleScreenLayout, .swapScreens]
    /// Botones con turbo. Direcciones y Start/Select no: nadie quiere un menú
    /// que se abre y se cierra diez veces por segundo.
    static let turboCapable: [INDSMappingTarget] = [.a, .b, .x, .y, .l, .r]
}

/// Claves físicas, tal y como las guarda el mapeo.
enum INDSPhysicalKey {
    static let directions = ["Up", "Down", "Left", "Right"]
    static let all: [String] = directions + ["A", "B", "X", "Y",
                                             "L1", "R1", "L2", "R2", "L3", "R3",
                                             "Options", "Menu", "Home", "Share"]
}

enum INDSMappingLogic {

    /// «Disposición DS»: GameController llama A/B/X/Y a sur/este/oeste/norte
    /// en todos los mandos, y en la DS el sur es B. Así el botón de abajo del
    /// Xbox hace de B, donde está en una DS de verdad. L2/R2 = Select/Start
    /// (un mando normal no tiene más botones frontales), Options y Menú pausan.
    static let defaultMapping: [String: Int] = [
        "Up": INDSMappingTarget.up.rawValue,
        "Down": INDSMappingTarget.down.rawValue,
        "Left": INDSMappingTarget.left.rawValue,
        "Right": INDSMappingTarget.right.rawValue,
        "A": INDSMappingTarget.b.rawValue,
        "B": INDSMappingTarget.a.rawValue,
        "X": INDSMappingTarget.y.rawValue,
        "Y": INDSMappingTarget.x.rawValue,
        "L1": INDSMappingTarget.l.rawValue,
        "R1": INDSMappingTarget.r.rawValue,
        "L2": INDSMappingTarget.select.rawValue,
        "R2": INDSMappingTarget.start.rawValue,
        "L3": INDSMappingTarget.none.rawValue,
        "R3": INDSMappingTarget.none.rawValue,
        "Options": INDSMappingTarget.pause.rawValue,
        "Menu": INDSMappingTarget.pause.rawValue,
        // Sin nada de fábrica: iOS los usa (app Juegos, capturas) y solo se le
        // piden al sistema cuando alguien les asigna algo.
        "Home": INDSMappingTarget.none.rawValue,
        "Share": INDSMappingTarget.none.rawValue,
    ]

    private static let validTargets = Set(INDSMappingTarget.allCases.map(\.rawValue))

    /// Lo guardado, sano: toda clave esperada presente, valores inválidos y
    /// claves desconocidas fuera. Idempotente.
    static func migrate(_ stored: [String: Int]) -> [String: Int] {
        var out = defaultMapping
        for (key, value) in stored where defaultMapping[key] != nil && validTargets.contains(value) {
            out[key] = value
        }
        return out
    }

    /// Asigna y cuenta qué se ha quedado fuera, para ofrecer «deshacer».
    static func assign(_ target: INDSMappingTarget, to key: String,
                       in mapping: [String: Int]) -> (mapping: [String: Int], displaced: INDSMappingTarget?) {
        var out = mapping
        let previous = out[key].flatMap(INDSMappingTarget.init(rawValue:))
        out[key] = target.rawValue
        guard let previous, previous != .none, previous != target else { return (out, nil) }
        // Solo es «desplazado» si ya no lo alcanza ningún otro botón.
        return (out, out.values.contains(previous.rawValue) ? nil : previous)
    }

    /// Claves físicas que hacen `target`, en el orden de pantalla.
    static func keys(for target: INDSMappingTarget, in mapping: [String: Int]) -> [String] {
        INDSPhysicalKey.all.filter { mapping[$0] == target.rawValue }
    }

    /// ¿Mantener Menú abre la pausa aunque tenga otro trabajo? Solo cuando
    /// ningún otro botón la abre y lo que hace Menú no se mantiene pulsado
    /// (con el avance rápido de mantener ahí, la pausa saltaría a media carrera).
    static func menuEscapeApplies(_ mapping: [String: Int]) -> Bool {
        let target = INDSMappingTarget(rawValue: mapping["Menu"] ?? INDSMappingTarget.pause.rawValue) ?? .none
        if target == .pause { return false }
        if mapping.contains(where: { $0.key != "Menu" && $0.value == INDSMappingTarget.pause.rawValue }) { return false }
        return target != .fastForward && !target.isDSButton
    }

    /// Lo imprescindible que ningún botón alcanza. La cruceta solo cuenta si el
    /// mando no tiene stick: el stick izquierdo mueve siempre.
    static func unreachableEssentials(_ mapping: [String: Int], hasStick: Bool) -> [INDSMappingTarget] {
        let reached = Set(mapping.values)
        var needed: [INDSMappingTarget] = [.a, .b, .start]
        if !menuEscapeApplies(mapping) { needed.append(.pause) }
        if !hasStick { needed = [.up, .down, .left, .right] + needed }
        return needed.filter { !reached.contains($0.rawValue) }
    }
}

/// El ritmo del turbo. La DS lee el teclado 60 veces por segundo: 30/s es
/// un fotograma pulsado y otro suelto, el máximo que un juego puede ver.
enum INDSTurboPattern {
    static let rates = [5, 8, 10, 12, 15, 20, 30]
    /// 15/s era el ritmo fijo de antes.
    static let defaultRate = 15

    static func clampedRate(_ rate: Int) -> Int {
        rates.contains(rate) ? rate : defaultRate
    }

    /// El siguiente o el anterior de la escalera, sin salirse.
    static func step(_ rate: Int, by delta: Int) -> Int {
        let index = rates.firstIndex(of: clampedRate(rate)) ?? 4
        return rates[max(0, min(rates.count - 1, index + delta))]
    }
}
