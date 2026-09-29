//
//  ProfileSettingsView.swift
//  eDuo
//
//  Settings > Profile — the name and language the console itself carries, in
//  the firmware's user settings. A real DS asks for both once, on its very
//  first boot; eDuo direct-boots straight into the game, so this page is
//  where that answer lives instead. Without it, melonDS's own defaults show
//  through: every player is called "melonDS", in English.
//

import SwiftUI

struct ProfileSettingsView: View {
    @State private var nickname = INDSConsolePreferences.nickname
    /// -1 follows the phone; anything else is an `INDSConsoleLanguage`.
    @State private var languageSelection = INDSConsolePreferences.languageOverride?.rawValue ?? -1

    private var automaticLabel: String {
        String(format: NSLocalizedString("Automatic (%@)", comment: "Console language picker: follow the device language, with that language's own name filled in"),
               INDSConsoleLanguage.matchingDevice.displayName)
    }

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("Name", comment: "Console nickname text field placeholder"),
                          text: $nickname)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onChange(of: nickname) { _, newValue in
                        // Clamp as it is typed rather than silently dropping
                        // the tail on save — the console has room for ten
                        // characters and the field should feel like it.
                        // The firmware field is ten UTF-16 code units, not
                        // ten grapheme clusters: ten emoji would otherwise
                        // reach the console as five. Dropping whole
                        // characters never splits a surrogate pair.
                        var clamped = newValue
                        while clamped.utf16.count > INDSConsolePreferences.maxNicknameLength {
                            clamped.removeLast()
                        }
                        if clamped != newValue { nickname = clamped }
                        INDSConsolePreferences.nickname = clamped
                    }
            } header: {
                Text("Console Name")
            } footer: {
                Text("The name the console answers to. Games that ask you to name yourself or your save start from this one. Up to 10 characters.")
            }

            Section {
                Picker(selection: $languageSelection) {
                    Text(automaticLabel).tag(-1)
                    ForEach(INDSConsoleLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                } label: {
                    Text("Language")
                }
                .onChange(of: languageSelection) { _, newValue in
                    INDSConsolePreferences.languageOverride = INDSConsoleLanguage(rawValue: newValue)
                }
            } footer: {
                Text("Most games ship every European language on the cartridge and pick one from this setting instead of asking. Japanese games rarely offer a choice at all.\n\nBoth apply the next time you open a game — the console reads them once, while it boots.")
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
    }
}
