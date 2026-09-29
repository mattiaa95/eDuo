//
//  INDSPerGameProfileStore.swift
//  eDuo
//
//  Ported and adapted from iGBA's PerGameProfileStore.swift:
//  automatic per-game settings memory. When the user changes speed or screen
//  layout while a game is running, the value is remembered for that game and
//  re-applied the next time it launches — no new UI, the app "just
//  remembers". Adaptation: a plain Swift enum instead of an `@objc NSObject`
//  subclass — iGBA's original is `@objc` because its legacy Objective-C
//  `EmuVC.mm` calls it directly; eDuo has no Objective-C call site for this
//  (only Swift, from `NDSRomViewController`), so the ObjC bridging is dead
//  weight here. `value(_:forGame:)` returns a plain `Int?` instead of
//  `NSNumber?` for the same reason.
//

import Foundation

enum INDSPerGameProfileStore {
    private static let storageKey = "eNDSPerGameProfiles"

    // Setting keys used by callers: "speedMultiplier", "layoutPortrait",
    // "layoutLandscape", "screenSwap".

    static func record(_ value: Int, setting: String, forGame name: String) {
        guard !name.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Int]] ?? [:]
        var game = all[name] ?? [:]
        game[setting] = value
        all[name] = game
        UserDefaults.standard.set(all, forKey: storageKey)
    }

    /// nil = the game has no remembered value for this setting.
    static func value(_ setting: String, forGame name: String) -> Int? {
        guard !name.isEmpty,
              let all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Int]]
        else { return nil }
        return all[name]?[setting]
    }

    /// Profiles are keyed by the ROM's base name, so they follow a rename
    /// (`ROMStorageManager.renameROM`) instead of silently detaching.
    static func rename(fromGame oldName: String, toGame newName: String) {
        guard !oldName.isEmpty, !newName.isEmpty, oldName != newName,
              var all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Int]],
              let game = all.removeValue(forKey: oldName)
        else { return }
        all[newName] = game
        UserDefaults.standard.set(all, forKey: storageKey)
    }

    /// Drops every remembered setting for `name` ("Delete ROM + Save Data").
    static func remove(forGame name: String) {
        guard !name.isEmpty,
              var all = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String: Int]],
              all.removeValue(forKey: name) != nil
        else { return }
        UserDefaults.standard.set(all, forKey: storageKey)
    }
}
