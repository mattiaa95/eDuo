//
//  INDSBatterySaverPreferences.swift
//  eDuo
//
//  UserDefaults-backed preferences for Settings > Battery. Both toggles
//  default `true` (same "absent key means on" idiom as `INDSHaptics.isEnabled`
//  and `INDSSavingPreferences.autoSaveOnExitEnabled`) — existing installs get
//  the battery-friendlier behavior automatically, opt out if they'd rather
//  not. `NDSRomViewController` reads these live (not just at launch) every
//  time `ProcessInfo`'s power-state/thermal-state notifications fire.
//

import Foundation

enum INDSBatterySaverPreferences {
    private static let respectLowPowerModeKey = "eNDSRespectLowPowerMode"
    private static let autoThrottleWhenHotKey = "eNDSAutoThrottleWhenHot"
    private static let manualKey = "eNDSBatterySaverManual"

    /// Posted when the manual toggle changes so an open game re-derives its
    /// saver state live (same pattern as `INDSControllerOverlayPreferences`).
    static let didChangeNotification = Notification.Name("INDSBatterySaverPreferencesDidChange")

    /// Manual "Battery Saver" switch (Settings > Battery). Default OFF, unlike
    /// the two automatic triggers below. Effective saver state is always
    /// `manual || (respectLowPowerMode && lowPower) || (autoThrottleWhenHot && hot)`.
    static var manualEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: manualKey) }
        set {
            guard newValue != UserDefaults.standard.bool(forKey: manualKey) else { return }
            UserDefaults.standard.set(newValue, forKey: manualKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Low Power Mode (if respected) or a serious/critical thermal state (if
    /// auto-throttle is on) — the automatic half of the effective state.
    static var isAutomaticActive: Bool {
        if respectLowPowerMode && ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        if autoThrottleWhenHot {
            switch ProcessInfo.processInfo.thermalState {
            case .serious, .critical: return true
            default: break
            }
        }
        return false
    }

    /// The single definition of "Battery Saver is on" for both consoles.
    static var isEffectivelyActive: Bool { manualEnabled || isAutomaticActive }

    static var respectLowPowerMode: Bool {
        get {
            if UserDefaults.standard.object(forKey: respectLowPowerModeKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: respectLowPowerModeKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: respectLowPowerModeKey) }
    }

    static var autoThrottleWhenHot: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoThrottleWhenHotKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoThrottleWhenHotKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoThrottleWhenHotKey) }
    }
}
