#if DEBUG
import SwiftUI

/// Hosts the real paywall on a bare screen so an XCUITest can verify it
/// without driving the whole course flow or reaching the App Store.
struct SubscriptionPaywallUITestHarness: View {
    static let argument = "--ui-test-subscription-paywall"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @State private var showsPaywall = true

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .sheet(isPresented: $showsPaywall) {
                SubscriptionPaywallView(requiredPlan: .hosted)
            }
            .onAppear { SubscriptionStore.shared.start() }
    }
}

/// UI-test stand-in for the store: serves plan offers and lets a tap on
/// Subscribe "purchase" locally. It exists so UI tests exercise the real
/// paywall with no Apple Account, sandbox, or network (simulators otherwise
/// show a sign-in alert instead of the paywall). Prices here are test data;
/// the shipped app only ever shows prices the App Store reports, which
/// `StoreKitSubscriptionBackendIntegrationTests` pins against Learnfold.storekit.
final class FixtureSubscriptionBackend: SubscriptionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [HeldEntitlement] = []

    func offers() async throws -> [PlanOffer] {
        [
            PlanOffer(plan: .plus, displayName: "Learnfold Plus", displayPrice: "$1.00", periodDescription: "month"),
            PlanOffer(plan: .hosted, displayName: "Learnfold Hosted", displayPrice: "$5.00", periodDescription: "month"),
        ]
    }

    func currentEntitlements() async -> [HeldEntitlement] {
        lock.withLock { held }
    }

    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult {
        lock.withLock {
            held = [HeldEntitlement(
                plan: plan,
                expirationDate: Date(timeIntervalSinceNow: 30 * 86_400),
                willAutoRenew: true
            )]
        }
        return .purchased
    }

    func restore() async throws {}

    func transactionUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
#endif
