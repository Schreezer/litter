#if DEBUG
import StoreKitTest
import XCTest
@testable import Litter

/// Exercises the debug `StoreKitSubscriptionBackend` through StoreKitTest with
/// `Support/Learnfold.storekit`, the same file the Debug scheme uses.
@MainActor
final class StoreKitSubscriptionBackendIntegrationTests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Learnfold.storekit")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: configuration.path),
            "Local StoreKit configuration not found"
        )
        session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
    }

    func testOffersCarryTheStoreKitPriceAndPeriod() async throws {
        let offers = try await StoreKitSubscriptionBackend().offers()
        let byPlan = Dictionary(uniqueKeysWithValues: offers.map { ($0.plan, $0) })
        XCTAssertEqual(byPlan[.plus]?.displayPrice, "$1.00")
        XCTAssertEqual(byPlan[.hosted]?.displayPrice, "$5.00")
        XCTAssertEqual(byPlan[.plus]?.periodDescription, "month")
        XCTAssertEqual(byPlan[.hosted]?.displayName, "Learnfold Hosted")
    }

    func testPurchaseRestoreUpgradeAndExpiry() async throws {
        let store = SubscriptionStore(backend: StoreKitSubscriptionBackend())
        await store.refreshEntitlements()
        XCTAssertNil(store.activePlan)

        let first = await store.purchase(.plus)
        XCTAssertEqual(first, .purchased)
        XCTAssertEqual(store.activePlan, .plus)
        XCTAssertTrue(store.hasAccess(to: .plus))
        XCTAssertFalse(store.hasAccess(to: .hosted))

        let upgrade = await store.purchase(.hosted)
        XCTAssertEqual(upgrade, .purchased)
        XCTAssertEqual(store.activePlan, .hosted)
        XCTAssertTrue(store.hasAccess(to: .plus), "Hosted includes Plus")

        await store.restore()
        XCTAssertEqual(store.activePlan, .hosted)

        // A refund revokes every transaction; access must disappear.
        for transaction in session.allTransactions() {
            try session.refundTransaction(identifier: transaction.identifier)
        }
        // StoreKit applies the refund asynchronously; poll briefly.
        for _ in 0..<50 {
            await store.refreshEntitlements()
            if store.activePlan == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(store.activePlan, "A refunded subscription must stop granting access: \(store.held)")
    }
}
#endif
