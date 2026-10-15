//
//  TurboSettingsSection.swift
//  eDuo
//
//  Turbo (rapid fire): which buttons, how fast, hold or latch. One section
//  shared by Settings › Controls and the controller mapping screen.
//
//  ⚠️ Turbo is NOT fast forward: turbo presses one button over and over, fast
//  forward speeds the whole game up. The footer says so.
//

import SwiftUI

struct INDSTurboSettingsSection: View {
    @State private var buttons = INDSTurboPreferences.buttons
    @State private var rate = INDSTurboPreferences.rateHz
    @State private var toggleMode = INDSTurboPreferences.toggleMode

    var body: some View {
        Section {
            ForEach(INDSTurboPreferences.eligible, id: \.rawValue) { button in
                Toggle(INDSTurboPreferences.displayName(button), isOn: Binding(
                    get: { buttons.contains(button) },
                    set: { isOn in
                        INDSTurboPreferences.setTurbo(isOn, for: button)
                        buttons = INDSTurboPreferences.buttons
                    }
                ))
            }

            Stepper {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text(String(format: NSLocalizedString("%d presses/s", comment: "Rapid fire speed, presses per second"), rate))
                        .font(.body.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            } onIncrement: {
                INDSTurboPreferences.rateHz = INDSTurboPattern.step(rate, by: 1)
                rate = INDSTurboPreferences.rateHz
            } onDecrement: {
                INDSTurboPreferences.rateHz = INDSTurboPattern.step(rate, by: -1)
                rate = INDSTurboPreferences.rateHz
            }

            Picker(NSLocalizedString("Mode", comment: "Rapid fire mode picker"), selection: $toggleMode) {
                Text(NSLocalizedString("While held", comment: "Rapid fire mode: fires while the button is held")).tag(false)
                Text(NSLocalizedString("Tap on / tap off", comment: "Rapid fire mode: one press starts firing, the next one stops")).tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: toggleMode) { _, newValue in
                INDSTurboPreferences.toggleMode = newValue
            }
        } header: {
            Text("Turbo")
        } footer: {
            Text(NSLocalizedString("A rapid-fire button presses itself over and over. This is not fast forward: the game keeps its normal speed.", comment: "Rapid fire explanation")
                 + " "
                 + NSLocalizedString("Works with the on-screen controls, a controller and a keyboard. A controller button set to «Rapid fire on/off» pauses it mid-game.", comment: "Turbo settings footer"))
        }
    }
}
