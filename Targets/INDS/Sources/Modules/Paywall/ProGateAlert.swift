//
//  ProGateAlert.swift
//  eDuo
//
//  Reusable "you hit a Pro limit" offer: a Go Pro / Not Now alert shared by
//  every gate (save-state slots 2–4, the scanlines filter, custom
//  backgrounds). A Pro purchase doesn't get its own callback: it just closes the
//  paywall, and the caller's own `EntitlementManager.shared.hasPro` check
//  unlocks the gate on the next tap.
//

import SwiftUI

struct ProGateOffer: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: ProGateOffer, rhs: ProGateOffer) -> Bool { lhs.id == rhs.id }
}

extension View {
    /// Presents `offer` (when non-nil) as a Go Pro / Not Now alert. Clears
    /// `offer` itself on dismissal.
    func proGateAlert(offer: Binding<ProGateOffer?>) -> some View {
        modifier(ProGateAlertModifier(offer: offer))
    }
}

private struct ProGateAlertModifier: ViewModifier {
    @Binding var offer: ProGateOffer?

    @State private var showPaywall = false

    private var isPresented: Binding<Bool> {
        Binding(get: { offer != nil }, set: { if !$0 { offer = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(offer?.title ?? "", isPresented: isPresented) {
                Button(NSLocalizedString("Go Pro", comment: "Pro gate alert action")) {
                    showPaywall = true
                }
                Button(NSLocalizedString("Not Now", comment: "Pro gate alert action"), role: .cancel) {}
            } message: {
                Text(offer?.message ?? "")
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PurchaseView(isPresented: $showPaywall)
            }
    }
}
