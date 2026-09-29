//
//  INDSSavingPreferences.swift
//  eDuo
//
//  UserDefaults-backed preferences for Settings → Saving. Same idiom as
//  `INDSHaptics.isEnabled` (Common/Controller) throughout: default `true`
//  when a key has never been set, so existing installs keep today's
//  behavior until the user opts out.
//
//  - `autoSaveOnExitEnabled` gates whether `NDSRomViewController` writes an
//    autosave state on background/exit.
//  - `autoResumeEnabled` gates whether `loadCore()` loads that autosave back
//    automatically right after boot — the load path itself already existed
//    (every launch silently resumed); this only adds the opt-out and the
//    HUD's "Resumed" toast.
//  - `showSaveIndicatorEnabled` gates the "Auto-saved" toast on a successful
//    autosave, independent of the other two.
//

import Foundation

enum INDSSavingPreferences {
    private static let autoSaveOnExitKey = "eNDSAutoSaveEnabled"
    private static let autoResumeKey = "eNDSAutoResume"
    private static let showSaveIndicatorKey = "eNDSShowSaveIndicator"
    private static let rewindKey = "eNDSRewindEnabled"

    static var autoSaveOnExitEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoSaveOnExitKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoSaveOnExitKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoSaveOnExitKey) }
    }

    static var autoResumeEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoResumeKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoResumeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoResumeKey) }
    }

    static var showSaveIndicatorEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: showSaveIndicatorKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showSaveIndicatorKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showSaveIndicatorKey) }
    }

    /// Keeps ~35 s of in-memory history for the pause menu's Rewind (~60 MB).
    static var rewindEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: rewindKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: rewindKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: rewindKey) }
    }
}
