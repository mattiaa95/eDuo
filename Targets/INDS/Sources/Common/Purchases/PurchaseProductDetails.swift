//
//  PurchaseProductDetails.swift
//  eDuo
//
//  Ported verbatim from iGBA
//  (App/SwiftUI/Common/PurchaseManager/PurchaseProductDetails.swift) — a
//  plain display-ready mirror of a StoreKit `Product`, built by
//  `PurchaseModel.fetchProducts()` so `PurchaseView` never touches
//  `StoreKit.Product` directly.
//

import Foundation

class PurchaseProductDetails: ObservableObject, Identifiable {
    let id: UUID

    @Published var price: String
    @Published var productId: String
    @Published var duration: String
    @Published var durationPlanName: String
    @Published var hasTrial: Bool

    /// StoreKit's own `Product.price`, kept alongside the display string.
    /// Re-parsing `displayPrice` with a NumberFormatter is locale-fragile — it
    /// fails outright in plenty of storefronts — and the paywall used to paper
    /// over that failure by claiming a fixed "SAVE 24%". Comparisons work off
    /// this; when it's absent the claim simply isn't made.
    @Published var rawPrice: Decimal?

    init(price: String = "", productId: String = "", duration: String = "",
         durationPlanName: String = "", hasTrial: Bool = false, rawPrice: Decimal? = nil) {
        self.id = UUID()
        self.price = price
        self.productId = productId
        self.duration = duration
        self.durationPlanName = durationPlanName
        self.hasTrial = hasTrial
        self.rawPrice = rawPrice
    }
}
