#if DEBUG
import Foundation
import StoreKit

/// Debug-only backend that talks to StoreKit 2 directly, so the paywall and
/// purchase flow can run against the local `Support/Learnfold.storekit`
/// configuration (scheme Run action, or StoreKitTest) with no RevenueCat
/// account or network. Release builds never contain it; they use RevenueCat.
final class StoreKitSubscriptionBackend: SubscriptionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var products: [String: Product] = [:]

    private func cached(_ productID: String) -> Product? {
        lock.lock()
        defer { lock.unlock() }
        return products[productID]
    }

    private func store(_ loaded: [Product]) {
        lock.lock()
        defer { lock.unlock() }
        for product in loaded { products[product.id] = product }
    }

    func offers() async throws -> [PlanOffer] {
        let loaded = try await Product.products(for: LearnfoldPlan.productIDs)
        store(loaded)
        return loaded.compactMap { product in
            guard let plan = LearnfoldPlan.plan(forProductID: product.id) else { return nil }
            return PlanOffer(
                plan: plan,
                displayName: product.displayName,
                displayPrice: product.displayPrice,
                periodDescription: Self.periodDescription(product.subscription?.subscriptionPeriod)
            )
        }
    }

    func currentEntitlements() async -> [HeldEntitlement] {
        var result: [HeldEntitlement] = []
        for await entry in Transaction.currentEntitlements {
            // StoreKit verifies the JWS signature chain on device. Anything
            // unverified is ignored rather than trusted.
            guard case .verified(let transaction) = entry,
                  let plan = LearnfoldPlan.plan(forProductID: transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.productType == .autoRenewable else { continue }
            result.append(HeldEntitlement(
                plan: plan,
                expirationDate: transaction.expirationDate,
                willAutoRenew: await willAutoRenew(productID: transaction.productID)
            ))
        }
        return result
    }

    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult {
        if cached(plan.productID) == nil { store(try await Product.products(for: LearnfoldPlan.productIDs)) }
        guard let product = cached(plan.productID) else { throw SubscriptionError.productUnavailable }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw SubscriptionError.productUnavailable
            }
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        try await StoreKit.AppStore.sync()
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await update in Transaction.updates {
                    if case .verified(let transaction) = update { await transaction.finish() }
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func willAutoRenew(productID: String) async -> Bool? {
        guard let product = cached(productID),
              let statuses = try? await product.subscription?.status else { return nil }
        for status in statuses {
            if case .verified(let renewal) = status.renewalInfo { return renewal.willAutoRenew }
        }
        return nil
    }

    private static func periodDescription(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "" }
        let unit: String
        switch period.unit {
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: return ""
        }
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }
}
#endif
