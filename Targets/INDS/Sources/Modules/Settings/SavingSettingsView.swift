//
//  SavingSettingsView.swift
//  eDuo
//
//  Settings → Saving. Three toggles over `INDSSavingPreferences` (Support),
//  all consulted by `NDSRomViewController`: `autosaveIfNeeded()` (background/
//  exit autosave + its "Auto-saved" toast) and `loadCore()` (auto-loading
//  that autosave back on next launch + its "Resumed" toast).
//

import SwiftUI

struct SavingSettingsView: View {
    @State private var autoSaveOnExit = INDSSavingPreferences.autoSaveOnExitEnabled
    @State private var autoResume = INDSSavingPreferences.autoResumeEnabled
    @State private var showSaveIndicator = INDSSavingPreferences.showSaveIndicatorEnabled
    @State private var rewind = INDSSavingPreferences.rewindEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Auto Save State on Exit", isOn: $autoSaveOnExit)
                    .onChange(of: autoSaveOnExit) { _, newValue in
                        INDSSavingPreferences.autoSaveOnExitEnabled = newValue
                    }

                Toggle("Show Save Indicator", isOn: $showSaveIndicator)
                    .onChange(of: showSaveIndicator) { _, newValue in
                        INDSSavingPreferences.showSaveIndicatorEnabled = newValue
                    }
            } header: {
                Text("💾 Saving")
            } footer: {
                Text("When on, eDuo saves a snapshot automatically whenever you leave a game or the app goes to the background, and offers to resume from it next time. The save indicator briefly shows \"Auto-saved\" on screen whenever that happens; turn it off to save silently.\n\nThis is separate from a game's own battery save (.sav) — the in-game save system, written when you save inside the game itself, exactly like a real cartridge. Save states are manual snapshots you create anytime from the pause menu and can return to instantly, even mid-level; autosave is just one save state eDuo keeps up to date for you automatically.")
            }

            Section {
                Toggle("Resume Where You Left Off", isOn: $autoResume)
                    .onChange(of: autoResume) { _, newValue in
                        INDSSavingPreferences.autoResumeEnabled = newValue
                    }
            } footer: {
                Text("When on, opening a game with an autosave loads it automatically right after boot, so you're back where you left off. Turn this off to always boot fresh and load save states manually from the pause menu instead.")
            }

            Section {
                Toggle("Rewind", isOn: $rewind)
                    .onChange(of: rewind) { _, newValue in
                        INDSSavingPreferences.rewindEnabled = newValue
                    }
            } footer: {
                Text("Keeps the last 35 seconds of play in memory, so Rewind in the pause menu can jump about 10 seconds back, up to three times in a row. Turn it off to free that memory on older devices.")
            }
        }
        .navigationTitle("Saving")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
    }
}
