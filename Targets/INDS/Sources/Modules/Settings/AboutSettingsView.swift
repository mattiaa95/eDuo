//
//  AboutSettingsView.swift
//  eDuo
//
//  Settings → About. Version/build, melonDS license note, and the
//  Rate/Support/Privacy rows iGBA's own About-flavored footer covers
//  (SettingsView.swift) — using `INDSConstants` for the URLs.
//

import StoreKit
import SwiftUI
import UIKit

struct AboutSettingsView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(appVersion) (\(buildNumber))")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("ℹ️ About")
            }

            Section {
                Button {
                    requestReview()
                } label: {
                    Label("Rate eDuo", systemImage: "star.fill")
                }
                Link(destination: INDSConstants.supportURL) {
                    Label("Support", systemImage: "questionmark.circle")
                }
                Link(destination: INDSConstants.privacyPolicyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: INDSConstants.termsURL) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
                Button {
                    NotificationCenter.default.post(name: .welcomeGuideRequested, object: nil)
                } label: {
                    Label("Welcome Guide", systemImage: "sparkles")
                }
            }

            // Tucked at the very bottom on purpose: license details and
            // source availability for whoever goes looking for them, without
            // turning About into a licensing billboard.
            Section {
                Link(destination: INDSConstants.sourceCodeURL) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.subheadline)
                }
                Link(destination: INDSConstants.melonDSURL) {
                    Label("melonDS Project", systemImage: "link")
                        .font(.subheadline)
                }
                // The licence itself, bundled — not merely a link to where it
                // lives. Works offline, and it is the first thing anyone
                // checking a GPL claim goes looking for.
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                        .font(.subheadline)
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("eDuo is open-source software licensed under the GNU General Public License v3 (GPLv3). It is powered by the melonDS emulation core, © Arisotura and the melonDS team, also GPLv3. eDuo is not affiliated with or endorsed by the melonDS team or by any console manufacturer.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
    }

    /// Opens the App Store review sheet directly instead of asking the system
    /// to decide. `SKStoreReviewController.requestReview` is throttled to about
    /// three prompts a year and silently does nothing once that budget is
    /// spent — so somebody who deliberately went looking for a Rate button
    /// taps it and watches nothing happen. For an explicit tap the user has
    /// already consented; the system prompt is for the unsolicited case.
    private func requestReview() {
        guard let url = URL(string: "https://apps.apple.com/app/id6797155513?action=write-review") else { return }
        UIApplication.shared.open(url)
    }
}
