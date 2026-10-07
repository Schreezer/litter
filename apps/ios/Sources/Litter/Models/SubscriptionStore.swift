import Foundation
import Observation
import StoreKit

/// A purchasable plan as StoreKit reports it. Prices are always the
/// localized `displayPrice` from the App Store; the app never formats one.
struct PlanOffer: Equatable, Identifiable, Sendable {
    let plan: LearnfoldPlan
    let displayName: String
    let displayPrice: String
    /// For example "month". Empty if StoreKit gave no period.
    let periodDescription: String

    var id: String { plan.id }
}

/// A subscription the user currently holds, verified by StoreKit on device.
struct HeldEntitlement: Equatable, Sendable {
    let plan: LearnfoldPlan
    let expirationDate: Date?
    let willAutoRenew: Bool?
    /// The StoreKit 2 signed transaction (JWS) the Worker verifies.
    let signedTransaction: String
}

enum PlanPurchaseResult: Equatable, Sendable {
    case purchased
    /// Ask to Buy or SCA: the purchase completes later via `transactionUpdates`.
    case pending
    case cancelled
}

/// The StoreKit seam. The live implementation talks to StoreKit 2; tests
/// inject a fake so entitlement and gating logic never touches the App Store.
protocol SubscriptionBackend: Sendable {
    func offers() async throws -> [PlanOffer]
    func currentEntitlements() async -> [HeldEntitlement]
    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult
    /// Re-syncs purchases with the App Store (Restore Purchases).
    func restore() async throws
    /// Yields whenever the transaction set may have changed.
    func transactionUpdates() -> AsyncStream<Void>
}

enum SubscriptionError: LocalizedError {
    case productUnavailable
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "This plan isn't available from the App Store right now. Please try again later."
        case .unverifiedTransaction:
            "The App Store couldn't verify this purchase. Please try again."
        }
    }
}

@MainActor
@Observable
final class SubscriptionStore: EntitlementProviding {
    static let shared = SubscriptionStore()

    private(set) var offers: [PlanOffer] = []
    private(set) var held: [HeldEntitlement] = []
    private(set) var isLoadingOffers = false
    private(set) var isWorking = false
    private(set) var hasLoadedEntitlements = false
    private(set) var offersError: String?
    private(set) var actionError: String?
    private(set) var notice: String?

    @ObservationIgnored private let backend: any SubscriptionBackend
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(backend: any SubscriptionBackend = StoreKitSubscriptionBackend()) {
        self.backend = backend
    }

    /// The best plan the user holds right now.
    var activePlan: LearnfoldPlan? {
        LearnfoldPlan.highest(of: held.map(\.plan))
    }

    var activeEntitlement: HeldEntitlement? {
        guard let activePlan else { return nil }
        return held
            .filter { $0.plan == activePlan }
            .max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }
    }

    func offer(for plan: LearnfoldPlan) -> PlanOffer? {
        offers.first { $0.plan == plan }
    }

    func hasAccess(to plan: LearnfoldPlan) -> Bool {
        activePlan?.includes(plan) == true
    }

    /// Begin observing purchases made elsewhere (renewals, Ask to Buy
    /// approvals, other devices, refunds). Safe to call repeatedly.
    func start() {
        guard updatesTask == nil else { return }
        let updates = backend.transactionUpdates()
        updatesTask = Task { [weak self] in
            for await _ in updates {
                await self?.refreshEntitlements()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlements()
            await self?.loadOffers()
        }
    }

    func refreshEntitlements() async {
        held = await backend.currentEntitlements()
        hasLoadedEntitlements = true
    }

    func loadOffers() async {
        guard !isLoadingOffers else { return }
        isLoadingOffers = true
        offersError = nil
        defer { isLoadingOffers = false }
        do {
            let loaded = try await backend.offers()
            offers = LearnfoldPlan.allCases.compactMap { plan in loaded.first { $0.plan == plan } }
            if offers.isEmpty {
                offersError = "Plans can't be loaded right now. Check your connection and try again."
            }
        } catch {
            offers = []
            offersError = "Plans can't be loaded right now. Check your connection and try again."
        }
    }

    @discardableResult
    func purchase(_ plan: LearnfoldPlan) async -> PlanPurchaseResult? {
        guard !isWorking else { return nil }
        isWorking = true
        actionError = nil
        notice = nil
        defer { isWorking = false }
        do {
            let result = try await backend.purchase(plan)
            switch result {
            case .purchased:
                await refreshEntitlements()
            case .pending:
                notice = "Your purchase is waiting for approval. It will unlock automatically once approved."
            case .cancelled:
                break
            }
            return result
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        notice = nil
        defer { isWorking = false }
        do {
            try await backend.restore()
            await refreshEntitlements()
            notice = activePlan == nil
                ? "No active subscription was found for this Apple ID."
                : "Your subscription was restored."
        } catch {
            actionError = "Couldn't restore purchases: \(error.localizedDescription)"
        }
    }

    func hostedSignedTransaction() async -> String? {
        // Always ask StoreKit again: the freshest signed transaction carries
        // the latest renewal, and a revoked one is simply absent.
        let current = await backend.currentEntitlements()
        held = current
        hasLoadedEntitlements = true
        return current
            .filter { $0.plan == .hosted }
            .max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) }?
            .signedTransaction
    }

    deinit {
        updatesTask?.cancel()
    }
}

// MARK: - StoreKit 2

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
                willAutoRenew: await willAutoRenew(productID: transaction.productID),
                signedTransaction: entry.jwsRepresentation
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
                throw SubscriptionError.unverifiedTransaction
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
