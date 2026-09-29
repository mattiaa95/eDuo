//
//  LicensesView.swift
//  eDuo
//
//  Settings → About → Licenses. The GPLv3 text and the third-party notices,
//  bundled inside the app rather than only linked.
//
//  This matters beyond tidiness: eDuo links melonDS (GPLv3), and GPLv3 §4/§6
//  expect the licence to travel with the work. Someone with no network, or
//  reading on a plane, still has to be able to see the terms the app ships
//  under — a hyperlink to GitHub is not the licence, and it is exactly the
//  detail a reviewer or a licence-conscious user checks first.
//

import SwiftUI

struct LicensesView: View {
    /// `nil` while the file is being read; the read is trivial (35 KB) but it
    /// happens off the main thread anyway so pushing this screen never stalls
    /// the navigation animation.
    @State private var licenseText: String?
    @State private var thirdPartyText: String?
    @State private var noticesText: String?

    var body: some View {
        List {
            Section {
                Text(thirdPartyText ?? NSLocalizedString("Loading…", comment: ""))
                    .font(.footnote)
                    .textSelection(.enabled)
            } header: {
                Text("Third-Party Components")
            }

            Section {
                Text(licenseText ?? NSLocalizedString("Loading…", comment: ""))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("GNU General Public License v3")
            } footer: {
                Text("eDuo and the melonDS core it uses are both released under these terms.")
            }

            // BSD/MIT/zlib/LGPL all require their notice to accompany binary
            // distributions — the App Store binary is one, so the notices are
            // readable here, not just kept in the repository.
            Section {
                Text(noticesText ?? NSLocalizedString("Loading…", comment: ""))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("Third-Party License Notices")
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .tint(INDSAppearanceStore.shared.accentColor)
        .task {
            let (license, thirdParty, notices) = await Task.detached(priority: .userInitiated) {
                (Self.bundledText(named: "GPLv3", ext: "txt"),
                 Self.bundledText(named: "THIRD_PARTY", ext: "md"),
                 Self.bundledText(named: "NOTICES", ext: "txt"))
            }.value
            licenseText = license
            thirdPartyText = thirdParty
            noticesText = notices
        }
    }

    // `nonisolated`: `View` types are main-actor isolated, so without it the
    // detached task above would hop back to the main actor for each read —
    // the exact stall the detached task exists to avoid.
    private nonisolated static func bundledText(named name: String, ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Should be impossible (both files are bundled resources), but a
            // licence screen that renders empty is worse than one that says so.
            return NSLocalizedString("This document could not be loaded. You can also read it at github.com/mattiaa95/eDuo.",
                                     comment: "Licenses screen: bundled file missing")
        }
        return text
    }
}
