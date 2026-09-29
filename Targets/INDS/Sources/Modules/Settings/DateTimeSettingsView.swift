//
//  DateTimeSettingsView.swift
//  eDuo
//
//  Settings > Date & Time — the console's own clock, which plenty of DS games
//  read: life-sim games run on it entirely, monster-raising games grow berries and
//  changes day/night by it, and a pile of games gate daily events on it.
//  melonDS boots the RTC at 2000-01-01 unless the frontend seeds it, so this
//  page exists to seed it — and to let someone deliberately move the clock
//  (time-travel in a life sim, seeing a night-only event at noon).
//

import Combine
import SwiftUI

struct DateTimeSettingsView: View {
    @State private var syncToDevice = INDSRTCPreferences.syncToDeviceClock
    @State private var customDate = INDSRTCPreferences.consoleDate
    /// Ticks once a second so the preview reads like a real clock.
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var previewDate: Date {
        syncToDevice ? now : now.addingTimeInterval(customDate.timeIntervalSince(referenceNow))
    }

    /// The instant `customDate` was authored against, so the preview advances
    /// with real time instead of freezing at the picked value.
    @State private var referenceNow = Date()

    var body: some View {
        Form {
            Section {
                Toggle("Match Device Clock", isOn: $syncToDevice)
                    .onChange(of: syncToDevice) { _, newValue in
                        INDSRTCPreferences.syncToDeviceClock = newValue
                        if newValue {
                            INDSRTCPreferences.offsetSeconds = 0
                            customDate = Date()
                            referenceNow = Date()
                        }
                    }
            } header: {
                Text("🕹️ Console Clock")
            } footer: {
                Text("Games read the console's own clock — day and night cycles, daily events and once-a-day unlocks all run on it. Applies the next time you open a game.")
            }

            if !syncToDevice {
                Section {
                    DatePicker("Console Date & Time", selection: $customDate,
                               in: dateRange, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .onChange(of: customDate) { _, newValue in
                            referenceNow = Date()
                            INDSRTCPreferences.setConsoleDate(INDSRTCPreferences.clamped(newValue))
                        }
                } footer: {
                    Text("Set once and it keeps running from there — the console clock ticks forward on its own, it doesn't freeze at this moment. The console can only store years from 2000 to 2099.")
                }
            }

            Section {
                LabeledContent("In-Game Clock") {
                    Text(previewDate, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !syncToDevice {
                    Button("Reset to Device Clock") {
                        syncToDevice = true
                        INDSRTCPreferences.syncToDeviceClock = true
                        INDSRTCPreferences.offsetSeconds = 0
                        customDate = Date()
                        referenceNow = Date()
                        INDSHaptics.light()
                    }
                }
            }
        }
        .navigationTitle("Date & Time")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
        .onReceive(tick) { now = $0 }
    }

    private var dateRange: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        let lower = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date()
        let upper = calendar.date(from: DateComponents(year: 2099, month: 12, day: 31)) ?? Date()
        return lower...upper
    }
}
