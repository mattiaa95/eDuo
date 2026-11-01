//
//  BatterySettingsView.swift
//  eDuo
//
//  Settings → Battery. Two independent toggles over
//  `INDSBatterySaverPreferences`, both read live by `NDSRomViewController`
//  (ProcessInfo power-state/thermal-state notifications) rather than only at
//  game launch — unlike most other Settings pages, this one can change
//  behavior in an already-open game, since Low Power Mode/thermal state can
//  themselves change mid-session.
//

import SwiftUI

struct BatterySettingsView: View {
    /// Same literal key `MelonDSCoreBridge.mm` reads at ROM load
    /// (`INDSThreadedRenderingEnabled`), default ON.
    fileprivate static let threadedRenderingKey = "eNDSThreadedRendering"

    @State private var manualSaver = INDSBatterySaverPreferences.manualEnabled
    @State private var respectLowPowerMode = INDSBatterySaverPreferences.respectLowPowerMode
    @State private var autoThrottleWhenHot = INDSBatterySaverPreferences.autoThrottleWhenHot
    @State private var threadedRendering =
        UserDefaults.standard.object(forKey: BatterySettingsView.threadedRenderingKey) as? Bool ?? true

    var body: some View {
        Form {
            Section {
                Toggle("Battery Saver", isOn: $manualSaver)
                    .onChange(of: manualSaver) { _, newValue in
                        INDSBatterySaverPreferences.manualEnabled = newValue
                    }
            } footer: {
                Text("Saves battery in every game: 3DS games render at native resolution, and DS and 3DS games show 30 frames per second on screen. Game speed stays the same; Fast Forward is limited to 1x. Your own settings come back when you turn it off. Low Power Mode and a hot device can also turn it on (below).")
            }

            Section {
                Toggle("Respect Low Power Mode", isOn: $respectLowPowerMode)
                    .onChange(of: respectLowPowerMode) { _, newValue in
                        INDSBatterySaverPreferences.respectLowPowerMode = newValue
                    }
            } footer: {
                Text("While iOS Low Power Mode is on, eDuo caps emulation speed at 1x — even if Fast Forward is held — and lowers the screen's refresh rate. The emulated console itself isn't slowed down or paused.")
            }

            Section {
                Toggle("Auto-Throttle When Hot", isOn: $autoThrottleWhenHot)
                    .onChange(of: autoThrottleWhenHot) { _, newValue in
                        INDSBatterySaverPreferences.autoThrottleWhenHot = newValue
                    }
            } footer: {
                Text("If your device starts running hot, eDuo automatically caps speed at 1x. If it keeps heating up, eDuo also lowers the screen's refresh rate to help it cool down.")
            }

            Section {
                Toggle("Threaded 3D Rendering", isOn: $threadedRendering)
                    .onChange(of: threadedRendering) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: Self.threadedRenderingKey)
                    }
            } header: {
                Text("⚡ Performance")
            } footer: {
                Text("Spreads 3D rendering across your device's CPU cores instead of just one. Leave it on — it's a large speed gain in 3D games and costs nothing. Turn it off only if a specific game shows glitched graphics. Applies the next time you open a game.")
            }
        }
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
    }
}
