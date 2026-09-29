//
//  INDSAudioPreferences.swift
//  eDuo
//
//  UserDefaults-backed preference shared between `AudioSettingsView` and
//  `NDSRomViewController` for "Mute game while other audio plays" — unlike
//  "eNDSAudioVolume"/"eNDSMicEnabled" above it (which only the Objective-C
//  bridge reads, across a boundary where duplicating the literal key is the
//  established convention — see MelonDSCoreBridge.mm's own comment), this
//  key is read by another Swift file in the same module, so a shared
//  accessor is the more natural fit — same idiom as `INDSSavingPreferences`/
//  `INDSBatterySaverPreferences`. Default OFF: today's always-mix behavior.
//

import Foundation

enum INDSAudioPreferences {
    private static let muteWithOtherAudioKey = "eNDSMuteWithOtherAudio"

    static var muteWithOtherAudioEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: muteWithOtherAudioKey) }
        set { UserDefaults.standard.set(newValue, forKey: muteWithOtherAudioKey) }
    }
}
