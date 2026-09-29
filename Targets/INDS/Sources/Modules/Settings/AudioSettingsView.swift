//
//  AudioSettingsView.swift
//  eDuo
//
//  Settings → Audio. Volume + a quick-mute toggle over the existing
//  "eNDSAudioVolume" key, the same one `MelonDSCoreBridge` reads at init and
//  writes on every `audioVolume` change during gameplay. Settings has no live
//  core instance to talk to, so it reads/writes UserDefaults directly — the
//  next game launched picks it up when its `MelonDSCoreBridge` is created.
//  Mute logic mirrors the pause menu's own `NDSAudioCard` (remember the
//  pre-mute level, restore it on unmute).
//
//  The Microphone section below follows the exact same "no live core"
//  pattern over "eNDSMicEnabled" — MelonDSCoreBridge.mm reads that same
//  UserDefaults key (see -isMicrophoneToggleEnabled) each time a game opens
//  its mic window, so flipping this toggle here only ever takes effect on
//  the next such window (this session's or a future one), never live mid-
//  capture, same as every other setting on this screen.
//
//  "Mute game while other audio plays" is the one live exception: unlike
//  everything above, `NDSRomViewController` reads `INDSAudioPreferences`
//  on every `AVAudioSession.silenceSecondaryAudioHintNotification`, so this
//  toggle can affect an already-open game.
//

import AVFAudio
import SwiftUI

struct AudioSettingsView: View {
    private static let volumeKey = "eNDSAudioVolume"
    private static let micEnabledKey = "eNDSMicEnabled"

    @State private var volume: Double
    @State private var preMuteVolume: Double = 1.0
    @State private var micEnabled: Bool
    @State private var muteWithOtherAudio = INDSAudioPreferences.muteWithOtherAudioEnabled

    /// iOS-level microphone permission. The bridge treats a denial as fatal but
    /// silent (one NSLog, "silent by design"), so without surfacing it here a
    /// player who ever tapped "Don't Allow" blows into a mic game forever while
    /// this screen keeps insisting the mic is on. Re-read on every appearance
    /// and on foreground return, since the fix happens in the Settings app.
    @State private var recordPermission = AVAudioApplication.shared.recordPermission
    @Environment(\.scenePhase) private var scenePhase

    private var micBlockedBySystem: Bool { recordPermission == .denied }

    init() {
        _volume = State(initialValue: UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 1.0)
        _micEnabled = State(initialValue: UserDefaults.standard.object(forKey: Self.micEnabledKey) as? Bool ?? true)
    }

    private var isMuted: Bool { volume <= 0.0001 }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { isMuted },
                    set: { muted in
                        if muted {
                            preMuteVolume = volume > 0 ? volume : preMuteVolume
                            volume = 0
                        } else {
                            volume = preMuteVolume > 0 ? preMuteVolume : 1.0
                        }
                        persist(volume)
                    }
                )) {
                    Label("Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }

                Slider(value: $volume, in: 0...1) { editing in
                    if !editing { persist(volume) }
                }
                .disabled(isMuted)
            } header: {
                Text("🔊 Volume")
            } footer: {
                Text("Applies the next time you open a game. You can also adjust volume from the pause menu while playing.")
            }

            Section {
                Toggle(isOn: $micEnabled) {
                    Label("Microphone", systemImage: micBlockedBySystem ? "mic.slash.fill" : "mic.fill")
                }
                .onChange(of: micEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: Self.micEnabledKey)
                }
                .disabled(micBlockedBySystem)

                if micBlockedBySystem {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label(NSLocalizedString("Open iOS Settings", comment: "Button to fix a denied microphone permission"),
                              systemImage: "arrow.up.forward.app")
                    }
                }
            } header: {
                Text("🎤 Microphone")
            } footer: {
                if micBlockedBySystem {
                    Text("iOS is blocking microphone access for eDuo, so games that use the mic won't hear you. Turn it back on in iOS Settings › Privacy & Security › Microphone.")
                } else {
                    Text("Lets games listen — blowing into the mic in some games, or speaking in others. eDuo only asks for microphone access the first time a game actually needs it, never at launch, and audio never leaves your device. Turn this off to keep the mic silent.")
                }
            }

            Section {
                Toggle(isOn: $muteWithOtherAudio) {
                    Label("Mute While Other Audio Plays", systemImage: "speaker.slash.circle")
                }
                .onChange(of: muteWithOtherAudio) { _, newValue in
                    INDSAudioPreferences.muteWithOtherAudioEnabled = newValue
                }
            } footer: {
                Text("When on, eDuo silences itself while music or another app's audio is playing, instead of mixing with it. Takes effect immediately, even in an open game. Yields to the microphone whenever a game is actively listening.")
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recordPermission = AVAudioApplication.shared.recordPermission }
        .onChange(of: scenePhase) { _, phase in
            // The user fixes this in the Settings app and comes back — re-read
            // on return or the screen would keep showing the stale denial.
            if phase == .active { recordPermission = AVAudioApplication.shared.recordPermission }
        }
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    private func persist(_ value: Double) {
        UserDefaults.standard.set(value, forKey: Self.volumeKey)
    }
}
