//
//  INDSAppearanceStore.swift
//  eDuo
//
//  Shared accent-color preference, loosely inspired by iGBA's
//  `SettingsViewModel.accentColor` — same idea (a persisted,
//  reactive `Color`, applied app-wide via `.tint`/`.accentColor`) scaled down
//  to a single-property singleton since eDuo's Settings has nothing else that
//  needs to be a shared, cross-screen `ObservableObject` yet. Everything else
//  in Controls/Screens/Audio reads/writes its UserDefaults key directly with
//  plain `@State`.
//
//  A singleton (rather than a `@StateObject` owned by `SettingsView`, like
//  iGBA's `viewModel`) because the accent color also needs to be read from
//  `NDSPauseMenuHostingController`, a UIKit class outside the SwiftUI tree
//  that presents its own separately-hosted `UIHostingController` — a plain
//  environment-object pass-down can't reach across that boundary.
//
//  `gameBackgroundColor` (emulation letterbox/gap fill, default black) piggy-
//  backs on the same store and persistence idiom. Like every other Settings
//  page's "applies next time" convention, `NDSRomViewController` only reads
//  it once, in `configureView()` — there's no live Combine subscription into
//  that UIKit screen, same as how this store's own `accentColor` only ever
//  reaches `NDSPauseMenuHostingController` (also UIKit) at construction time.
//

import SwiftUI
import UIKit

final class INDSAppearanceStore: ObservableObject {
    static let shared = INDSAppearanceStore()

    private static let accentColorKey = "eNDSAccentColor"
    private static let gameBackgroundColorKey = "eNDSGameBackgroundColor"

    /// Brand crimson (matches the app icon gradient) — the default accent.
    /// `.accentColor` would fall through to system blue: there is no
    /// AccentColor set in the asset catalog.
    static let brandCrimson = Color(red: 232 / 255, green: 84 / 255, blue: 106 / 255)

    @Published var accentColor: Color {
        didSet { Self.persist(accentColor, forKey: Self.accentColorKey) }
    }

    /// Fill color behind/between the DS screens in `NDSRomViewController`.
    /// Defaults to today's hardcoded black.
    @Published var gameBackgroundColor: Color {
        didSet { Self.persist(gameBackgroundColor, forKey: Self.gameBackgroundColorKey) }
    }

    /// UIKit convenience for `NDSRomViewController`, which has no SwiftUI
    /// `Color` of its own to bind to.
    var gameBackgroundUIColor: UIColor { UIColor(gameBackgroundColor) }

    private init() {
        accentColor = Self.loadPersistedColor(forKey: Self.accentColorKey) ?? Self.brandCrimson
        gameBackgroundColor = Self.loadPersistedColor(forKey: Self.gameBackgroundColorKey) ?? .black
    }

    private static func loadPersistedColor(forKey key: String) -> Color? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let uiColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: data)
        else { return nil }
        return Color(uiColor)
    }

    private static func persist(_ color: Color, forKey key: String) {
        let uiColor = UIColor(color)
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: uiColor, requiringSecureCoding: true) else {
            debugLog("[Settings] Failed to archive color for \(key)")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
