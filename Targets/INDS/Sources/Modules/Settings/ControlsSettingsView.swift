//
//  ControlsSettingsView.swift
//  eDuo
//
//  Settings → Controls. Exposes the on-screen controller preferences that
//  `NDSControllerView` (Common/Controller) already reads from UserDefaults at
//  setup time — opacity ("eNDSControllerOpacity", floor 0.15, same clamp as
//  the live overlay), a global size multiplier ("eNDSControllerScale",
//  applied on top of each button's own per-button scale from the layout
//  editor), and haptics (`INDSHaptics.isEnabled`). Opacity/size values take
//  effect the next time a game is opened: Settings never touches a live
//  `NDSControllerView` instance directly, both are read once at `setup()`.
//
//  The preview below is a cheap, schematic SwiftUI mock (plain shapes, not
//  the real button skin) so this page doesn't need to depend on
//  Common/Controller's rendering code — just enough to see opacity/size
//  react live while dragging the sliders.
//
//  "Customize Layout" below pushes `INDSLayoutEditorView` (Common/Controller)
//  — the full per-button position/size/visibility/style editor. That one
//  DOES write straight through `INDSControllerLayoutManager`, so its changes
//  reach any live `NDSControllerView` immediately via
//  `layoutDidChangeNotification`, unlike opacity/size above.
//

import SwiftUI

struct ControlsSettingsView: View {
    private static let opacityKey = "eNDSControllerOpacity"
    private static let scaleKey = "eNDSControllerScale"

    @State private var opacity: Double
    @State private var scale: Double
    @State private var hapticsEnabled: Bool
    @State private var hapticStrength: INDSHapticStrength
    @State private var turboButtons: Set<INDSButton>
    @State private var fastForwardSpeed: Double

    init() {
        let defaults = UserDefaults.standard
        _opacity = State(initialValue: defaults.object(forKey: Self.opacityKey) as? Double ?? 0.55)
        _scale = State(initialValue: defaults.object(forKey: Self.scaleKey) as? Double ?? 1.0)
        _hapticsEnabled = State(initialValue: INDSHaptics.isEnabled)
        _hapticStrength = State(initialValue: INDSHaptics.strength)
        _turboButtons = State(initialValue: INDSTurboPreferences.buttons)
        _fastForwardSpeed = State(initialValue: INDSSpeedPreferences.fastForwardSpeed)
    }

    var body: some View {
        Form {
            Section {
                previewCanvas
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 10)
            } header: {
                Text("🎮 Preview")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                        Spacer()
                        Text("\(Int(opacity * 100))%").foregroundColor(.secondary)
                    }
                    Slider(value: $opacity, in: 0.15...1.0, step: 0.05)
                        .onChange(of: opacity) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: Self.opacityKey)
                        }
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Size")
                        Spacer()
                        Text("\(Int(scale * 100))%").foregroundColor(.secondary)
                    }
                    Slider(value: $scale, in: 0.8...1.25, step: 0.05)
                        .onChange(of: scale) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: Self.scaleKey)
                        }
                }
                .padding(.vertical, 4)
            } header: {
                Text("🎮 On-Screen Controller")
            } footer: {
                Text("Opacity and size apply the next time you open a game.")
            }

            Section {
                NavigationLink {
                    INDSLayoutEditorView()
                } label: {
                    Label("Customize Layout", systemImage: "hand.draw.fill")
                }
            } footer: {
                Text("Reposition, resize, hide, and restyle every button, per orientation.")
            }

            Section {
                ForEach(INDSTurboPreferences.eligible, id: \.rawValue) { button in
                    Toggle(INDSTurboPreferences.displayName(button), isOn: Binding(
                        get: { turboButtons.contains(button) },
                        set: { isOn in
                            INDSTurboPreferences.setTurbo(isOn, for: button)
                            turboButtons = INDSTurboPreferences.buttons
                        }
                    ))
                }
            } header: {
                Text("Turbo")
            } footer: {
                Text("A turbo button fires by itself while you hold it. Works with the on-screen controls, a controller and a keyboard.")
            }

            Section {
                Picker("Speed", selection: $fastForwardSpeed) {
                    ForEach(INDSSpeedPreferences.fastForwardSpeeds, id: \.self) { speed in
                        Text(INDSSpeedPreferences.label(speed)).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: fastForwardSpeed) { _, newValue in
                    INDSSpeedPreferences.fastForwardSpeed = newValue
                }
            } header: {
                Text("Fast forward")
            } footer: {
                Text("How fast the game runs while Fast Forward is on, both from the Speed button on screen and from a controller. Tapping the on-screen button steps through these rates. A heavy 3D game may not reach the fastest one on every device.")
            }

            Section {
                // Custom get/set (matching NDSScreenLayoutCard's own toggle
                // idiom elsewhere) instead of `.onChange`, so the Strength
                // row's appearance/disappearance below animates as one
                // transaction with the toggle flip rather than jumping.
                Toggle("Haptics", isOn: Binding(
                    get: { hapticsEnabled },
                    set: { newValue in
                        withMotion(INDSMotion.gentle) { hapticsEnabled = newValue }
                        INDSHaptics.isEnabled = newValue
                    }
                ))

                if hapticsEnabled {
                    Picker("Strength", selection: $hapticStrength) {
                        ForEach(INDSHapticStrength.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: hapticStrength) { _, newValue in
                        INDSHaptics.strength = newValue
                    }
                    .transition(.opacity)
                }
            } footer: {
                Text("Vibrate on button presses and pause menu actions.")
            }

            Section {
                NavigationLink {
                    ButtonMappingView()
                } label: {
                    Label("Controller Mapping", systemImage: "gamecontroller.fill")
                }
            } footer: {
                Text("Remap a physical controller's buttons, including hotkeys for Quick Save, Quick Load, Cycle Screen Layout and Swap Screens.")
            }
        }
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    // MARK: - Schematic live preview

    private var previewCanvas: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))

            HStack {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.primary.opacity(0.12)))

                Spacer()

                previewFaceButtons
            }
            .padding(18)
            .opacity(opacity)
            .scaleEffect(scale)
        }
        .frame(height: 130)
        .padding(.horizontal, 4)
    }

    private var previewFaceButtons: some View {
        VStack(spacing: 6) {
            previewGlyph("Y")
            HStack(spacing: 6) {
                previewGlyph("X")
                previewGlyph("A")
            }
            previewGlyph("B")
        }
    }

    private func previewGlyph(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .bold))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.accentColor.opacity(0.35)))
    }
}
