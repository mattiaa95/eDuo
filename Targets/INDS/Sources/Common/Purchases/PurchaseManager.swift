//
//  PurchaseManager.swift
//  eDuo
//
//  Ported from iGBA
//  (App/SwiftUI/Common/PurchaseManager/PurchaseManager.swift). StoreKit 2
//  product loading + purchase/restore, unchanged apart from eDuo's own
//  product IDs. Owns the revocation-safe entitlement bookkeeping alongside
//  `EntitlementManager` (see that file's header for the bug this guards).
//

import Foundation
import StoreKit

@MainActor
class PurchaseManager: ObservableObject {

    private let productIds: [String]
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs = Set<String>()
    private var transactionListenerTask: Task<Void, Never>?

    public let entitlementManager: EntitlementManager

    init(entitlementManager: EntitlementManager) {
        self.entitlementManager = entitlementManager
        self.productIds = EntitlementManager.productIDs

        Task {
            await self.loadProducts()
            await self.updatePurchasedProducts()
        }

        listenForTransactionUpdates()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    func loadProducts() async {
        do {
            let storeProducts = try await Product.products(for: productIds)
            self.products = storeProducts
        } catch {
            #if DEBUG
            print("Failed to load products: \(error)")
            #endif
        }
    }

    /// Returns the raw StoreKit result so callers can tell `.pending`
    /// (Ask to Buy) apart from a cancel — both used to be silent.
    @discardableResult
    func purchase(_ product: Product) async throws -> Product.PurchaseResult {
        let result = try await product.purchase()
        if case .success(let verification) = result {
            switch verification {
            case .verified(let transaction):
                await self.handlePurchasedTransaction(transaction)
            case .unverified(_, let error):
                throw error
            }
        }
        return result
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await self.updatePurchasedProducts()
    }

    func fetchProduct(withId id: String) async -> Product? {
        return products.first { $0.id == id }
    }

    private func updatePurchasedProducts() async {
        var verifiedIDs = Set<String>()
        var sawAnyTransaction = false
        for await result in Transaction.currentEntitlements {
            // A refund leaves the transaction in `currentEntitlements` with its
            // revocation date set: without this, whoever asked for the refund
            // keeps Pro.
            if case .verified(let revocationCheck) = result,
               revocationCheck.revocationDate != nil { continue }
            sawAnyTransaction = true
            switch result {
            case .verified(let transaction):
                if transaction.revocationDate == nil {
                    verifiedIDs.insert(transaction.productID)
                }
            case .unverified(_, let error):
                NSLog("[PurchaseManager] Unverified entitlement: %@", error.localizedDescription)
            }
        }

        // Same rule as EntitlementManager.refreshEntitlements: an empty result
        // can mean "never paid" or "could not reach the App Store", and the two
        // must not be treated alike. Never revoke PRO on silence — only on a
        // readable answer that genuinely lacks a live entitlement (a lapsed or
        // refunded transaction that `latest(for:)` can still show us counts).
        if !sawAnyTransaction && self.entitlementManager.hasPro,
           await EntitlementManager.hasLapsedTransaction() == false {
            return
        }

        self.purchasedProductIDs = verifiedIDs
        self.entitlementManager.updateProStatus(isPro: !verifiedIDs.isEmpty)
    }

    private func handlePurchasedTransaction(_ transaction: StoreKit.Transaction) async {
        self.purchasedProductIDs.insert(transaction.productID)
        self.entitlementManager.updateProStatus(isPro: true)
        await transaction.finish()
        // `hasLifetime` is derived from `currentEntitlements` in one place
        // only; re-read them now so a fresh lifetime purchase is reflected
        // immediately instead of at the next foreground.
        await self.entitlementManager.refreshEntitlements()
    }

    private func listenForTransactionUpdates() {
        // `Transaction.updates` never completes: a strong `self` here would
        // keep the manager (and its listener) alive for the process lifetime.
        transactionListenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                switch result {
                case .verified(let transaction):
                    if transaction.revocationDate != nil {
                        self.purchasedProductIDs.remove(transaction.productID)
                        self.entitlementManager.updateProStatus(isPro: !self.purchasedProductIDs.isEmpty)
                        await transaction.finish()
                    } else {
                        await self.handlePurchasedTransaction(transaction)
                    }
                case .unverified(let transaction, _):
                    await transaction.finish()
                }
            }
        }
    }
}
