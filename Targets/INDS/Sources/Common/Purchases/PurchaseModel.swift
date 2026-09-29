//
//  PurchaseModel.swift
//  eDuo
//
//  Ported from iGBA
//  (App/SwiftUI/Modules/PurchaseView/PurchaseModel.swift) — the `PurchaseView`
//  view model. Same rule as iGBA: `productDetails` starts empty and
//  `isFetchingProducts` starts `true`, so the paywall can only ever show a
//  loading placeholder or a real StoreKit-localized price — never a
//  hardcoded fallback (a real, paid-for App Review rejection: a literal
//  "$X.XX" string doesn't match regional pricing).
//

import Foundation
import StoreKit
import SwiftUI

@MainActor
class PurchaseModel: ObservableObject {

    @Published var productDetails: [PurchaseProductDetails] = []
    @Published var isSubscribed: Bool = false
    @Published var isPurchasing: Bool = false
    @Published var isRestoring: Bool = false
    // Starts TRUE: the paywall must show the loading placeholder until
    // StoreKit returns real localized prices.
    @Published var isFetchingProducts: Bool = true
    @Published var purchaseError: String? = nil
    @Published var restoreSuccess: Bool = false
    @Published var purchaseSuccess: Bool = false

    /// Whether the user was previously subscribed (for win-back messaging).
    @Published var wasFormerSubscriber: Bool = false

    private var purchaseManager: PurchaseManager

    init() {
        self.purchaseManager = PurchaseManager(entitlementManager: EntitlementManager.shared)
        self.productDetails = []

        Task {
            await self.fetchProducts()
            self.isSubscribed = EntitlementManager.shared.hasPro
            self.wasFormerSubscriber = !self.isSubscribed && EntitlementManager.hasEverBeenPro
        }
    }

    func purchaseSubscription(productId: String) {
        Task {
            isPurchasing = true
            purchaseError = nil
            defer { isPurchasing = false }

            guard let product = await purchaseManager.fetchProduct(withId: productId) else {
                purchaseError = NSLocalizedString("Product not found. Please try again later.", comment: "")
                return
            }

            do {
                if case .pending = try await purchaseManager.purchase(product) {
                    purchaseError = NSLocalizedString("Purchase pending approval. PRO will unlock once it is approved.", comment: "")
                    return
                }
                self.isSubscribed = EntitlementManager.shared.hasPro
                if self.isSubscribed {
                    purchaseSuccess = true
                }
            } catch {
                if let storeKitError = error as? StoreKitError, case .userCancelled = storeKitError {
                    // User cancelled — no error needed
                } else {
                    purchaseError = String(format: NSLocalizedString("Purchase failed: %@", comment: ""), error.localizedDescription)
                }
            }
        }
    }

    func restorePurchases() {
        Task {
            isRestoring = true
            purchaseError = nil
            defer { isRestoring = false }

            do {
                try await purchaseManager.restorePurchases()
            } catch {
                purchaseError = String(format: NSLocalizedString("Restore failed: %@. Check your internet connection and try again.", comment: ""), error.localizedDescription)
                return
            }
            self.isSubscribed = EntitlementManager.shared.hasPro

            if self.isSubscribed {
                restoreSuccess = true
            } else {
                purchaseError = NSLocalizedString("No previous purchases found for this Apple ID.", comment: "")
            }
        }
    }

    /// Retry hook for the paywall's "Plans couldn't be loaded" state — StoreKit
    /// returns an empty set when offline, when the products aren't approved
    /// yet, or on a mis-signed sandbox account, and all three are recoverable
    /// without relaunching the app.
    func reloadProducts() {
        Task { await fetchProducts() }
    }

    private func fetchProducts() async {
        isFetchingProducts = true
        defer { isFetchingProducts = false }

        await purchaseManager.loadProducts()
        self.productDetails = purchaseManager.products.map { product in
            PurchaseProductDetails(
                price: product.displayPrice,
                productId: product.id,
                // Non-subscription products (the lifetime unlock) have no
                // subscription info — tag them explicitly so the paywall can
                // render them as the discreet pay-once option.
                duration: Self.durationLabel(for: product.subscription?.subscriptionPeriod),
                durationPlanName: product.displayName,
                // Only a FREE trial counts as a trial. An introductoryOffer can just
                // as easily be .payUpFront or .payAsYouGo — discounted paid intros —
                // and billing one of those as a "free trial" is a false claim made
                // inside the purchase flow, which is the worst place to make one.
                hasTrial: product.subscription?.introductoryOffer?.paymentMode == .freeTrial,
                rawPrice: product.price
            )
        }
    }

    /// The billing period as a word the user should read.
    ///
    /// This used to be `subscriptionPeriod.debugDescription` — an undocumented
    /// Apple debug string that is English-only and free to change between OS
    /// releases, printed straight into the paywall in all 10 languages. The
    /// literals below are the app's own, and `PurchaseView` localizes them.
    private static func durationLabel(for period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "lifetime" }
        switch period.unit {
        case .day:   return period.value == 7 ? "week" : "day"
        case .week:  return "week"
        case .month: return period.value == 12 ? "year" : "month"
        case .year:  return "year"
        @unknown default: return "period"
        }
    }
}
