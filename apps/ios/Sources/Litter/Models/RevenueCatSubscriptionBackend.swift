import Foundation

/// Where the pseudonymous RevenueCat app user ID comes from: the Hosted guest
/// identity, hashed one-way (`HostedGuestIdentity.revenueCatAppUserID`). The
/// Worker derives the same ID from the secret it already authenticates, so it
/// can find a subscriber without any account system.
struct HostedSubscriptionIdentity: Sendable {
    /// The ID for an identity that already exists. Never creates one, so it is
    /// safe at launch (it can't race iCloud Keychain into forking an identity).
    var existingAppUserID: @Sendable () -> String?
    /// The ID, creating the Hosted guest identity first if this install has
    /// none. Used right before a Hosted purchase.
    var createAppUserID: @Sendable () throws -> String

    static let none = HostedSubscriptionIdentity(
        existingAppUserID: { nil },
        createAppUserID: { throw SubscriptionError.identityUnavailable }
    )

    static func live(hostedServiceURL: String?) -> HostedSubscriptionIdentity {
        guard let hostedServiceURL, !hostedServiceURL.isEmpty else { return .none }
        return HostedSubscriptionIdentity(
            existingAppUserID: {
                guard let identity = try? HostedGuestIdentity.existingIdentity(serviceURL: hostedServiceURL) else { return nil }
                return HostedGuestIdentity.revenueCatAppUserID(secret: identity.secret)
            },
            createAppUserID: {
                do {
                    let identity = try HostedGuestIdentity.identity(serviceURL: hostedServiceURL)
                    return HostedGuestIdentity.revenueCatAppUserID(secret: identity.secret)
                } catch {
                    throw SubscriptionError.identityUnavailable
                }
            }
        )
    }
}

enum SubscriptionBackendFactory {
    /// Chooses the purchase backend for this process.
    ///
    /// - UI tests (debug only) use a local fixture store, or the unavailable
    ///   backend when asked, and never RevenueCat or the App Store.
    /// - With a RevenueCat public SDK key: RevenueCat.
    /// - Without one: debug builds fall back to the local StoreKit
    ///   configuration; release builds get the unavailable backend, which shows
    ///   "purchases unavailable" and doesn't enforce gating.
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundle: Bundle = .main
    ) -> any SubscriptionBackend {
        #if DEBUG
        if environment["LEARNFOLD_UI_TESTING"] == "1" {
            return arguments.contains(unavailableArgument) ? UnavailableSubscriptionBackend() : FixtureSubscriptionBackend()
        }
        #endif
        #if canImport(RevenueCat)
        if let key = RevenueCatConfiguration.publicSDKKey(environment: environment, bundle: bundle) {
            let hostedURL = (environment["LEARNFOLD_HOSTED_AGENT_URL"]
                ?? bundle.object(forInfoDictionaryKey: "LearnfoldHostedAgentURL") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RevenueCatSubscriptionBackend(
                apiKey: key,
                identity: .live(hostedServiceURL: hostedURL)
            )
        }
        #endif
        #if DEBUG
        return StoreKitSubscriptionBackend()
        #else
        return UnavailableSubscriptionBackend()
        #endif
    }

    /// Debug UI-test launch argument that forces the "purchases unavailable" state.
    static let unavailableArgument = "--ui-test-subscriptions-unavailable"
}

#if canImport(RevenueCat)
import RevenueCat

/// The production purchase backend. RevenueCat owns receipts, entitlements
/// and the server-side record; this class only maps them onto `LearnfoldPlan`.
///
/// Identity: the SDK is configured with the Hosted-derived app user ID when an
/// install already has a Hosted guest identity, and anonymously otherwise. It
/// logs in to the derived ID as soon as one exists (always before a Hosted
/// purchase), which merges any anonymous purchases into it.
final class RevenueCatSubscriptionBackend: SubscriptionBackend, @unchecked Sendable {
    private let apiKey: String
    private let identity: HostedSubscriptionIdentity
    private let lock = NSLock()
    private var lastKnownEntitlements: [HeldEntitlement] = []

    init(apiKey: String, identity: HostedSubscriptionIdentity) {
        self.apiKey = apiKey
        self.identity = identity
    }

    var isAvailable: Bool { true }

    private func purchases() -> Purchases {
        lock.lock()
        defer { lock.unlock() }
        if !Purchases.isConfigured {
            #if DEBUG
            Purchases.logLevel = .debug
            #endif
            Purchases.configure(with: Configuration.Builder(withAPIKey: apiKey)
                .with(appUserID: identity.existingAppUserID())
                // The ID is already a pseudonym. Don't also send IDFV/IDFA.
                .with(automaticDeviceIdentifierCollectionEnabled: false)
                .build())
        }
        return Purchases.shared
    }

    /// Makes the SDK's user match the Hosted-derived ID once one exists.
    private func syncIdentity(create: Bool) async throws {
        let purchases = purchases()
        let desired = create ? try identity.createAppUserID() : identity.existingAppUserID()
        guard let desired, purchases.appUserID != desired else { return }
        _ = try await purchases.logIn(desired)
    }

    func offers() async throws -> [PlanOffer] {
        let offerings = try await purchases().offerings()
        guard let current = offerings.current else { throw SubscriptionError.productUnavailable }
        return current.availablePackages.compactMap { package in
            let product = package.storeProduct
            guard let plan = LearnfoldPlan.plan(forProductID: product.productIdentifier) else { return nil }
            return PlanOffer(
                plan: plan,
                displayName: product.localizedTitle,
                displayPrice: product.localizedPriceString,
                periodDescription: Self.periodDescription(product.subscriptionPeriod)
            )
        }
    }

    func currentEntitlements() async -> [HeldEntitlement] {
        try? await syncIdentity(create: false)
        do {
            let info = try await purchases().customerInfo()
            let held = LearnfoldPlan.allCases.compactMap { plan -> HeldEntitlement? in
                guard let entitlement = info.entitlements.active[plan.entitlementID] else { return nil }
                return HeldEntitlement(plan: plan, expirationDate: entitlement.expirationDate, willAutoRenew: entitlement.willRenew)
            }
            lock.withLock { lastKnownEntitlements = held }
            return held
        } catch {
            // Offline or a transient error says nothing about the plan. Keep
            // what was last confirmed rather than revoking access.
            return lock.withLock { lastKnownEntitlements }
        }
    }

    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult {
        // Hosted entitlements are looked up by the Worker through the derived
        // ID, so make sure the purchase lands on it.
        try await syncIdentity(create: plan == .hosted)
        let offerings = try await purchases().offerings()
        guard let package = offerings.current?.availablePackages.first(where: {
            $0.storeProduct.productIdentifier == plan.productID
        }) else { throw SubscriptionError.productUnavailable }
        do {
            let result = try await purchases().purchase(package: package)
            return result.userCancelled ? .cancelled : .purchased
        } catch {
            switch (error as NSError).code {
            case ErrorCode.purchaseCancelledError.rawValue: return .cancelled
            case ErrorCode.paymentPendingError.rawValue: return .pending
            default: throw error
            }
        }
    }

    func restore() async throws {
        try? await syncIdentity(create: false)
        _ = try await purchases().restorePurchases()
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { [self] in
                for await _ in purchases().customerInfoStream {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func periodDescription(_ period: SubscriptionPeriod?) -> String {
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
