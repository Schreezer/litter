import Foundation
import Observation

/// A purchasable plan as the store reports it. Prices are always the
/// localized price string from the App Store (through RevenueCat); the app
/// never formats or hardcodes one.
struct PlanOffer: Equatable, Identifiable, Sendable {
    let plan: LearnfoldPlan
    let displayName: String
    let displayPrice: String
    /// For example "month". Empty if the store gave no period.
    let periodDescription: String

    var id: String { plan.id }
}

/// A subscription the user currently holds.
struct HeldEntitlement: Equatable, Sendable {
    let plan: LearnfoldPlan
    let expirationDate: Date?
    let willAutoRenew: Bool?
}

enum PlanPurchaseResult: Equatable, Sendable {
    case purchased
    /// Ask to Buy or SCA: the purchase completes later via `transactionUpdates`.
    case pending
    case cancelled
}

/// The purchase seam. The live implementation talks to RevenueCat; tests and
/// local development inject a fake or the local StoreKit configuration, so
/// entitlement and gating logic never depends on a network.
protocol SubscriptionBackend: Sendable {
    /// `false` when this build can't sell anything (for example it was built
    /// without a RevenueCat SDK key). Gating is not enforced in that case, and
    /// the paywall says purchases are unavailable instead of failing.
    var isAvailable: Bool { get }
    func offers() async throws -> [PlanOffer]
    func currentEntitlements() async -> [HeldEntitlement]
    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult
    /// Re-syncs purchases with the App Store (Restore Purchases).
    func restore() async throws
    /// Yields whenever the entitlement set may have changed.
    func transactionUpdates() -> AsyncStream<Void>
}

extension SubscriptionBackend {
    var isAvailable: Bool { true }
}

enum SubscriptionError: LocalizedError {
    case productUnavailable
    case purchasesUnavailable
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "This plan isn't available from the App Store right now. Please try again later."
        case .purchasesUnavailable:
            SubscriptionStore.purchasesUnavailableMessage
        case .identityUnavailable:
            "Couldn't prepare your Hosted identity. Unlock your device, check iCloud Keychain, and try again."
        }
    }
}

/// What a build without a RevenueCat SDK key uses. It never touches the
/// network and never crashes; every purchase surface reports unavailability.
struct UnavailableSubscriptionBackend: SubscriptionBackend {
    var isAvailable: Bool { false }
    func offers() async throws -> [PlanOffer] { throw SubscriptionError.purchasesUnavailable }
    func currentEntitlements() async -> [HeldEntitlement] { [] }
    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult { throw SubscriptionError.purchasesUnavailable }
    func restore() async throws { throw SubscriptionError.purchasesUnavailable }
    func transactionUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@MainActor
@Observable
final class SubscriptionStore: EntitlementProviding {
    static let purchasesUnavailableMessage = "Purchases are unavailable right now. Apple's on-device and Private Cloud Compute agents stay free."
    static let plansUnavailableMessage = "Plans can't be loaded right now. Check your connection and try again."

    static let shared = SubscriptionStore(backend: SubscriptionBackendFactory.live())

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

    init(backend: any SubscriptionBackend) {
        self.backend = backend
    }

    /// Whether this build can sell plans at all. When `false` the paywall shows
    /// that purchases are unavailable and gating is not enforced, so a build
    /// shipped without a SDK key can't lock anyone out of an agent.
    var purchasesAvailable: Bool { backend.isAvailable }

    /// The best plan the user holds right now.
    var activePlan: LearnfoldPlan? {
        LearnfoldPlan.highest(of: held.map(\.plan))
    }

    var activeEntitlement: HeldEntitlement? {
        guard let activePlan else { return nil }
        return held
            .filter { $0.plan == activePlan }
            .max { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
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
            if offers.isEmpty { offersError = Self.plansUnavailableMessage }
        } catch {
            offers = []
            offersError = backend.isAvailable ? Self.plansUnavailableMessage : Self.purchasesUnavailableMessage
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
                ? "No active subscription was found for this Apple Account."
                : "Your subscription was restored."
        } catch SubscriptionError.purchasesUnavailable {
            actionError = Self.purchasesUnavailableMessage
        } catch {
            actionError = "Couldn't restore purchases: \(error.localizedDescription)"
        }
    }

    deinit {
        updatesTask?.cancel()
    }
}
