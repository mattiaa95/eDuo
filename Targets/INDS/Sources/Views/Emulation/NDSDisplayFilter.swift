//
//  NDSDisplayFilter.swift
//  eDuo
//
//  New (no iGBA equivalent — GBA's single-screen renderer has its own,
//  differently-scoped filter set). How the DS framebuffers are scaled/
//  overlaid in `DSDualScreenView`. Mirrors `DSScreenLayoutMode` /
//  `DSScreenLayoutPreferences` (DSScreenLayout.swift) in shape: a plain
//  `String`-backed `CaseIterable` enum plus a tiny UserDefaults-backed
//  preferences store for the app-wide default.
//

import Foundation

/// `.smooth` and `.crisp` are always free; `.scanlines` needs PRO (or the
/// first-48h honeymoon, see `INDSHoneymoon`) — same shape as the speed
/// slider's >2x gate.
enum NDSDisplayFilter: String, CaseIterable, Codable {
    case smooth
    case crisp
    case scanlines

    var displayName: String {
        switch self {
        case .smooth:    return NSLocalizedString("Smooth", comment: "Display filter: linear-scaled screens")
        case .crisp:     return NSLocalizedString("Crisp", comment: "Display filter: pixel-perfect nearest-neighbor scaled screens")
        case .scanlines: return NSLocalizedString("Scanlines", comment: "Display filter: retro CRT scanline overlay")
        }
    }

    var sfSymbolName: String {
        switch self {
        case .smooth:    return "circle.grid.cross.fill"
        case .crisp:     return "square.grid.3x3.fill"
        case .scanlines: return "tv.fill"
        }
    }

    var requiresEntitlement: Bool { self == .scanlines }
}

/// UserDefaults-backed persistence for the app-wide default display filter
/// (`ScreensSettingsView`'s "Display Filter" section) — the value a game
/// with no filter of its own falls back to, exactly like
/// `DSScreenLayoutPreferences` does for layout. `NDSRomViewController`
/// overrides this per-game via `INDSPerGameProfileStore`, same as speed.
enum NDSDisplayFilterPreferences {
    private static let key = "eNDSDisplayFilter"

    static var current: NDSDisplayFilter {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), let filter = NDSDisplayFilter(rawValue: raw) else {
                return .smooth
            }
            return filter
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
