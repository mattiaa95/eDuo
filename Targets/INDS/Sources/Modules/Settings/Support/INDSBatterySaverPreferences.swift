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
