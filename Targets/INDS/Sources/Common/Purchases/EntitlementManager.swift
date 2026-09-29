//
//  EntitlementManager.swift
//  eDuo
//
//  Ported from iGBA's `EntitlementManager`
//  (App/SwiftUI/Common/PurchaseManager/EntitlementManager.swift). Same
//  revocation check as iGBA — a real bug paid for elsewhere in this
//  developer's apps: reading `Transaction.currentEntitlements` without
//  filtering out transactions with a non-nil `revocationDate` keeps granting
//  Pro after a refund/chargeback.
//
//  Adaptation vs. iGBA: no `@objc`/`NSObject` ObjC-visibility — eDuo has no
//  Objective-C layer to bridge through. `updateProStatus(isPro: true)` also
//  persists a one-way "ever had Pro" flag itself (iGBA sets the equivalent
//  `hasPro_ever` only at the exact moment `PurchaseModel.purchaseSubscription`
//  succeeds, which misses restores / family-shared / transaction-listener
//  grants); centralizing it here in the single "we just confirmed this
//  device has Pro" choke point keeps `shouldOfferLifetime` (see
//  `PurchaseView`) correct for every path, not just a fresh purchase.
//

import Foundation
import StoreKit
import SwiftUI

final class EntitlementManager: ObservableObject {
    static let shared = EntitlementManager()

    private static let userDefaults = UserDefaults.standard
    private static let hasProKey = "eNDSHasPro"
    private static let hasProEverKey = "eNDSHasProEver"

    @Published var hasPro: Bool = EntitlementManager.userDefaults.bool(forKey: EntitlementManager.hasProKey)
    /// Pro came from the pay-once unlock: there is no subscription to manage,
    /// so Settings must not send the user to an empty subscriptions sheet.
    @Published var hasLifetime: Bool = EntitlementManager.userDefaults.bool(forKey: "eNDSHasLifetime")

    /// Background task that listens for transaction updates from StoreKit.
    /// Started by `startTransactionListener()`.
    private var transactionListenerTask: Task<Void, Never>?

    private init() {}

    static let productIDs = ["iNDSPRO", "iNDSPROYearly", "iNDSPROLifetime"]

    /// `currentEntitlements` omits expired and revoked transactions, so an
    /// empty stream reads the same for "never paid", "subscription lapsed" and
    /// "offline". `Transaction.latest(for:)` still returns the lapsed/refunded
    /// one — that is the evidence that lets us downgrade a lapsed subscriber
    /// without punishing a paying customer who is merely offline.
    static func hasLapsedTransaction() async -> Bool {
        for id in productIDs {
            if await StoreKit.Transaction.latest(for: id) != nil { return true }
        }
        return false
    }

    func updateProStatus(isPro: Bool) {
        hasPro = isPro
        Self.userDefaults.set(isPro, forKey: Self.hasProKey)
        if isPro {
            Self.userDefaults.set(true, forKey: Self.hasProEverKey)
        }
    }

    /// True if this device has ever held Pro (even if it lapsed). Drives the
    /// lifetime win-back targeting in `PurchaseView.shouldOfferLifetime`.
    static var hasEverBeenPro: Bool {
        userDefaults.bool(forKey: hasProEverKey)
    }

    /// Starts a global StoreKit transaction listener so offer-code
    /// redemptions and other out-of-band purchases activate Pro
    /// automatically without the user needing to open Settings or
    /// `PurchaseView`. Safe to call multiple times — only the first call
    /// starts the task.
    func startTransactionListener() {
        guard transactionListenerTask == nil else { return }
        transactionListenerTask = Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                switch result {
                case .verified(let transaction):
                    // Refresh on revocations too — a refund must take PRO away.
                    await self?.refreshEntitlements()
                    await transaction.finish()
                case .unverified(let transaction, _):
                    await transaction.finish()
                }
            }
        }
    }

    /// Refreshes Pro entitlement by reading current transactions from
    /// StoreKit. Call this on `applicationWillEnterForeground` to catch
    /// redemptions made while the app was backgrounded (e.g. the user
    /// redeemed an offer code in the App Store and returned to the app).
    func refreshEntitlements() async {
        var verified = false
        var lifetime = false
        var sawAnyTransaction = false
        for await result in StoreKit.Transaction.currentEntitlements {
            sawAnyTransaction = true
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                verified = true
                if transaction.productID == "iNDSPROLifetime" { lifetime = true }
            }
        }

        // An empty result is ambiguous: it means "this user never paid" OR "we
        // could not reach the App Store just now". Treating both as a lapse
        // takes PRO away from someone on a plane, on bad Wi-Fi, or while
        // Apple's servers hiccup — a paying customer punished for our
        // uncertainty. Only ever downgrade on evidence: if StoreKit gave us
        // nothing at all and we currently believe the user is PRO, keep
        // believing it and try again next foreground — unless StoreKit can
        // show us the lapsed/refunded transaction, which *is* evidence.
        if !sawAnyTransaction, await MainActor.run(body: { self.hasPro }),
           await Self.hasLapsedTransaction() == false {
            return
        }
        // Captured as a `let` — a `var` referenced from inside this
        // concurrently-executing closure is a Swift 6 mode error, not just
        // a style nit.
        let isVerified = verified
        let isLifetime = lifetime
        await MainActor.run {
            if self.hasPro != isVerified {
                self.updateProStatus(isPro: isVerified)
            }
            if self.hasLifetime != isLifetime {
                self.hasLifetime = isLifetime
                Self.userDefaults.set(isLifetime, forKey: "eNDSHasLifetime")
            }
        }
    }

    /// Fire-and-forget refresh for use from `AppDelegate`.
    func refreshEntitlementsAsync() {
        Task { await refreshEntitlements() }
    }
}
