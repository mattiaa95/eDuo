//
//  INDSConsolePreferences.swift
//  eDuo
//
//  Settings > Profile. The DS keeps its owner's name and system language in
//  the firmware's user settings, and direct boot copies them straight into
//  main RAM for the game to read — so this is what name-aware games
//  suggests when it asks your name, and how most multi-language carts decide
//  which of their translations to show without ever asking.
//
//  melonDS's generated firmware fills both in with its own defaults: the
//  literal name "melonDS", in English. Neither is something a player of eDuo
//  should be handed, hence this file. Baked into the firmware image at ROM
//  load (`MelonDSCoreBridge.loadROMAtPath:`), so changes here land the next
//  time a game is opened — see [[inds-project]] for the wider console-state
//  work this belongs to (the RTC in `INDSRTCPreferences` is the other half).
//

import Foundation

/// The six languages a DS (as opposed to a DSi) firmware can be set to.
/// Chinese exists in the enum melonDS uses but only on iQue DSi hardware, so
/// it is deliberately not offered here.
enum INDSConsoleLanguage: Int, CaseIterable, Identifiable {
    case japanese = 0
    case english = 1
    case french = 2
    case german = 3
    case italian = 4
    case spanish = 5

    var id: Int { rawValue }

    /// Each language in its own words, the way the console's own setup screen
    /// shows them — which also means there is nothing here to translate.
    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .spanish: return "Español"
        }
    }

    /// The closest console language to the language the phone is set to, or
    /// English for the many languages the DS never shipped (the console has
    /// no Portuguese, Russian, Korean or Chinese setting).
    static var matchingDevice: INDSConsoleLanguage {
        let code = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
        switch code {
        case "ja": return .japanese
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "es": return .spanish
        default: return .english
        }
    }
}

enum INDSConsolePreferences {
    /// The firmware stores the name as 10 UTF-16 characters and no more.
    static let maxNicknameLength = 10
    static let defaultNickname = "eDuo"

    private static let nicknameKey = "eNDSConsoleNickname"
    private static let languageKey = "eNDSConsoleLanguage"

    static var nickname: String {
        get {
            let stored = UserDefaults.standard.string(forKey: nicknameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultNickname : String(stored.prefix(maxNicknameLength))
        }
        set {
            let cleaned = String(newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxNicknameLength))
            UserDefaults.standard.set(cleaned, forKey: nicknameKey)
        }
    }

    /// nil while the console follows the phone's language, which is the
    /// default — an explicit choice is for players who want a game in a
    /// language their phone isn't set to.
    static var languageOverride: INDSConsoleLanguage? {
        get {
            guard let raw = UserDefaults.standard.object(forKey: languageKey) as? Int else { return nil }
            return INDSConsoleLanguage(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
    }

    static var language: INDSConsoleLanguage {
        languageOverride ?? .matchingDevice
    }

    /// Copies the current profile onto the core, to be baked into the
    /// generated firmware by the next `loadROM`. Call before loading, not
    /// after: the firmware image is read once, at boot.
    static func apply(to core: MelonDSCoreBridge) {
        core.firmwareNickname = nickname
        core.firmwareLanguage = language.rawValue
    }
}
