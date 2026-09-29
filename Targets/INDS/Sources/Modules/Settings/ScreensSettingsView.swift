//
//  ScreensSettingsView.swift
//  eDuo
//
//  Settings → Screens (new — no iGBA equivalent, GBA has a single screen).
//  Default portrait/landscape layout mode and screen swap, backed by the
//  existing `DSScreenLayoutPreferences` (Views/Emulation/DSScreenLayout.swift)
//  — the same store `NDSRomViewController` already reads on every orientation
//  change and the pause menu/HUD already write to via their cycle button.
//  This page just gives those keys a home in Settings; it doesn't duplicate
//  their persistence.
//

import SwiftUI

struct ScreensSettingsView: View {
    @State private var portraitMode = DSScreenLayoutPreferences.savedMode(for: .portrait)
    @State private var landscapeMode = DSScreenLayoutPreferences.savedMode(for: .landscape)
    @State private var swapEnabled = DSScreenLayoutPreferences.swapEnabled
    @State private var stretchEnabled = DSScreenLayoutPreferences.stretchEnabled
    @State private var displayFilter = NDSDisplayFilterPreferences.current
    @State private var pendingFilterOffer: ProGateOffer?

    @ObservedObject private var entitlements = EntitlementManager.shared

    private var isScanlinesEntitled: Bool {
        entitlements.hasPro || INDSHoneymoon.isActive
    }

    var body: some View {
        Form {
            Section {
                Picker("Portrait", selection: $portraitMode) {
                    Text("Automatic").tag(DSScreenLayoutMode?.none)
                    ForEach(DSScreenLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .onChange(of: portraitMode) { _, newValue in
                    DSScreenLayoutPreferences.setMode(newValue, for: .portrait)
                }

                Picker("Landscape", selection: $landscapeMode) {
                    Text("Automatic").tag(DSScreenLayoutMode?.none)
                    ForEach(DSScreenLayoutMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .onChange(of: landscapeMode) { _, newValue in
                    DSScreenLayoutPreferences.setMode(newValue, for: .landscape)
                }
            } header: {
                Text("📺 Default Screen Layout")
            }

            Section {
                Toggle("Swap Screens", isOn: $swapEnabled)
                    .onChange(of: swapEnabled) { _, newValue in
                        DSScreenLayoutPreferences.swapEnabled = newValue
                    }
            } footer: {
                Text("These are the defaults used the next time you open a game that has no layout of its own yet. You can always change the layout in-game from the pause menu or the HUD's layout button — eDuo remembers your choice per game.")
            }

            Section {
                Toggle("Fill Screen (Ignore Aspect Ratio)", isOn: $stretchEnabled)
                    .onChange(of: stretchEnabled) { _, newValue in
                        DSScreenLayoutPreferences.stretchEnabled = newValue
                    }
            } footer: {
                Text("Stretches each screen to completely fill its assigned area instead of keeping the original 4:3 shape. Takes effect immediately, in every layout mode.")
            }

            Section {
                Picker(NSLocalizedString("Display Filter", comment: ""), selection: $displayFilter) {
                    ForEach(NDSDisplayFilter.allCases, id: \.self) { filter in
                        Text(filter.requiresEntitlement && !isScanlinesEntitled ? "\(filter.displayName) 🔒" : filter.displayName)
                            .tag(filter)
                    }
                }
                .onChange(of: displayFilter) { _, newValue in
                    selectDisplayFilter(newValue)
                }
            } header: {
                Text("🎛️ Display Filter")
            } footer: {
                Text("Smooth and Crisp are always free; Scanlines is a PRO feature. This is the default for games with no filter of their own — you can always change it in-game from the pause menu.")
            }
        }
        .navigationTitle("Screens")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
        .proGateAlert(offer: $pendingFilterOffer)
    }

    /// Same shape as the pause menu speed slider's gate: a locked pick snaps
    /// the control back and offers an unlock instead of taking effect.
    private func selectDisplayFilter(_ filter: NDSDisplayFilter) {
        guard filter.requiresEntitlement, !isScanlinesEntitled else {
            NDSDisplayFilterPreferences.current = filter
            return
        }
        // Snap back to what the user already had, not to Smooth.
        let saved = NDSDisplayFilterPreferences.current
        displayFilter = saved.requiresEntitlement ? .smooth : saved
        pendingFilterOffer = ProGateOffer(
            title: NSLocalizedString("Scanlines is PRO", comment: "Display filter gate alert title"),
            message: NSLocalizedString("Smooth and Crisp are always free. Go PRO to unlock the Scanlines filter.", comment: "Display filter gate alert message")
        )
    }
}
