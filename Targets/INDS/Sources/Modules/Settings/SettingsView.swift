//
//  SettingsView.swift
//  eDuo
//
//  Settings hub — clones iGBA's hub-style settings screen
//  (SettingsView.swift): a short `Form` of `NavigationLink`s into focused
//  sub-pages
//  instead of one long scrolling form. Presented as a sheet (with its own
//  `NavigationStack`) from the gear button in `ROMListView`'s toolbar.
//

import StoreKit
import SwiftUI

/// A consistent icon + title + subtitle row, used by every hub entry.
/// Same shape as iGBA's private `SettingsHubRow`.
private struct SettingsHubRow: View {
    let icon: String
    let iconColor: Color
    // LocalizedStringKey, not String: `Text(someString)` does not localize,
    // so every row on this page shipped in English no matter the device
    // language. Literals at the call sites keep working unchanged.
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// Fixed point size that still follows Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @ObservedObject private var appearance = INDSAppearanceStore.shared
    @ObservedObject private var entitlements = EntitlementManager.shared
    @State private var showingBIOSSetup = false
    @State private var showProSheet = false
    @State private var showManageSubscription = false
    @Environment(\.dismiss) private var dismiss
    // Fixed point sizes that still follow Dynamic Type; the values are the
    // default-size look.
    @ScaledMetric(relativeTo: .body) private var proIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .footnote) private var chevronSize: CGFloat = 13

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                proSubscriptionSection

                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsHubRow(icon: "paintpalette.fill", iconColor: .pink,
                                       title: "Appearance", subtitle: "Accent color")
                    }

                    NavigationLink {
                        ControlsSettingsView()
                    } label: {
                        SettingsHubRow(icon: "gamecontroller.fill", iconColor: .purple,
                                       title: "Controls", subtitle: "On-screen controller & haptics")
                    }

                    NavigationLink {
                        ScreensSettingsView()
                    } label: {
                        SettingsHubRow(icon: "rectangle.grid.1x2.fill", iconColor: .blue,
                                       title: "Screens", subtitle: "Default layout & swap")
                    }

                    NavigationLink {
                        AudioSettingsView()
                    } label: {
                        SettingsHubRow(icon: "speaker.wave.2.fill", iconColor: .orange,
                                       title: "Audio", subtitle: "Volume & mute")
                    }

                    NavigationLink {
                        ProfileSettingsView()
                    } label: {
                        SettingsHubRow(icon: "person.text.rectangle.fill", iconColor: .mint,
                                       title: "Profile", subtitle: "Name & language games see")
                    }

                    NavigationLink {
                        DateTimeSettingsView()
                    } label: {
                        SettingsHubRow(icon: "clock.fill", iconColor: .pink,
                                       title: "Date & Time", subtitle: "Console clock used by games")
                    }

                    NavigationLink {
                        BatterySettingsView()
                    } label: {
                        SettingsHubRow(icon: "battery.75", iconColor: .teal,
                                       title: "Battery", subtitle: "Low Power Mode & thermal throttle")
                    }
                }

                Section {
                    Button {
                        showingBIOSSetup = true
                    } label: {
                        SettingsHubRow(icon: "cpu.fill", iconColor: .indigo,
                                       title: "BIOS", subtitle: "Optional firmware files")
                    }
                } footer: {
                    Text("Optional — eDuo boots games without BIOS files; add them only if a specific game needs them.")
                }

                Section {
                    NavigationLink {
                        SavingSettingsView()
                    } label: {
                        SettingsHubRow(icon: "externaldrive.fill", iconColor: .green,
                                       title: "Saving", subtitle: "Autosave on exit")
                    }

                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsHubRow(icon: "info.circle.fill", iconColor: .gray,
                                       title: "About", subtitle: "Version, credits & support")
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("eDuo — \(appVersion)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingBIOSSetup) {
                BIOSSetupView()
            }
            .fullScreenCover(isPresented: $showProSheet) {
                PurchaseView(isPresented: $showProSheet)
            }
        }
        .tint(appearance.accentColor)
    }

    // MARK: - PRO section
    //
    // Ported from iGBA's `proSubscriptionSection`
    // (App/SwiftUI/Modules/Settings/SettingsView/SettingsView.swift) — the
    // main entry point into the paywall (alongside the save-slot / scanlines
    // / background locks). Deliberately not shown in onboarding.
    private var proSubscriptionSection: some View {
        Section {
            if !entitlements.hasPro {
                Button {
                    showProSheet.toggle()
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.indsCrimsonLight, Color.indsCrimsonDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 42, height: 42)

                            Image(systemName: "crown.fill")
                                .font(.system(size: proIconSize))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("eDuo PRO")
                                .font(.headline.weight(.bold))
                                .foregroundColor(.primary)
                            Text("Unlock all PRO features")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: chevronSize, weight: .semibold))
                            .foregroundColor(.indsCrimsonLight)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Button {
                    showManageSubscription = true
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.indsCrimsonLight, Color.indsCrimsonDark],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 42, height: 42)

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: proIconSize))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("eDuo PRO Active")
                                .font(.headline.weight(.bold))
                                .foregroundColor(.primary)
                            Group {
                                if entitlements.hasLifetime {
                                    Text("Lifetime unlock — nothing to manage")
                                } else {
                                    Text("Manage your subscription")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: chevronSize, weight: .semibold))
                            .foregroundColor(.indsCrimsonLight)
                    }
                    .padding(.vertical, 4)
                }
                // The sheet is empty for the pay-once unlock — nothing to open.
                .disabled(entitlements.hasLifetime)
                .manageSubscriptionsSheet(isPresented: $showManageSubscription)
            }
        }
    }
}
