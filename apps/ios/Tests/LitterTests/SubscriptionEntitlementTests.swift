import XCTest
@testable import Litter

// MARK: - Fakes

/// A StoreKit stand-in. Tests drive entitlements, purchase outcomes and the
/// transaction-update stream directly, so nothing here touches the App Store.
private final class FakeSubscriptionBackend: SubscriptionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _entitlements: [HeldEntitlement] = []
    private var _offers: [PlanOffer] = []
    private var _purchaseResult: Result<PlanPurchaseResult, Error> = .success(.purchased)
    private var _purchaseGrants: HeldEntitlement?
    private var _restoreGrants: HeldEntitlement?
    private var _restoreError: Error?
    private var _offersError: Error?
    private var continuation: AsyncStream<Void>.Continuation?
    private(set) var purchasedPlans: [LearnfoldPlan] = []
    private(set) var restoreCalls = 0

    var entitlements: [HeldEntitlement] {
        get { lock.withLock { _entitlements } }
        set { lock.withLock { _entitlements = newValue } }
    }
    var offerList: [PlanOffer] {
        get { lock.withLock { _offers } }
        set { lock.withLock { _offers = newValue } }
    }
    var offersError: Error? {
        get { lock.withLock { _offersError } }
        set { lock.withLock { _offersError = newValue } }
    }
    var purchaseResult: Result<PlanPurchaseResult, Error> {
        get { lock.withLock { _purchaseResult } }
        set { lock.withLock { _purchaseResult = newValue } }
    }
    var purchaseGrants: HeldEntitlement? {
        get { lock.withLock { _purchaseGrants } }
        set { lock.withLock { _purchaseGrants = newValue } }
    }
    var restoreGrants: HeldEntitlement? {
        get { lock.withLock { _restoreGrants } }
        set { lock.withLock { _restoreGrants = newValue } }
    }
    var restoreError: Error? {
        get { lock.withLock { _restoreError } }
        set { lock.withLock { _restoreError = newValue } }
    }

    func offers() async throws -> [PlanOffer] {
        if let offersError { throw offersError }
        return offerList
    }

    func currentEntitlements() async -> [HeldEntitlement] { entitlements }

    func purchase(_ plan: LearnfoldPlan) async throws -> PlanPurchaseResult {
        lock.withLock { purchasedPlans.append(plan) }
        let result = try purchaseResult.get()
        if result == .purchased, let grant = purchaseGrants { entitlements = [grant] }
        return result
    }

    func restore() async throws {
        lock.withLock { restoreCalls += 1 }
        if let restoreError { throw restoreError }
        if let grant = restoreGrants { entitlements = [grant] }
    }

    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func emitUpdate() { lock.withLock { continuation }?.yield() }
}

private func held(_ plan: LearnfoldPlan, expires: TimeInterval = 86_400) -> HeldEntitlement {
    HeldEntitlement(plan: plan, expirationDate: Date(timeIntervalSinceNow: expires), willAutoRenew: true)
}

private func offer(_ plan: LearnfoldPlan, price: String) -> PlanOffer {
    PlanOffer(plan: plan, displayName: plan.title, displayPrice: price, periodDescription: "month")
}

@MainActor
private final class FakeEntitlements: EntitlementProviding {
    var plans: Set<LearnfoldPlan> = []
    init(_ plans: Set<LearnfoldPlan> = []) { self.plans = plans }
    func hasAccess(to plan: LearnfoldPlan) -> Bool { plans.contains { $0.includes(plan) } }
}

// MARK: - Plans and policy

final class LearnfoldPlanTests: XCTestCase {
    func testProductIdentifiersMatchAppStoreConnect() {
        XCTAssertEqual(LearnfoldPlan.plus.productID, "com.chirag.learnfold.plus.monthly")
        XCTAssertEqual(LearnfoldPlan.hosted.productID, "com.chirag.learnfold.hosted.monthly")
        XCTAssertEqual(LearnfoldPlan.plan(forProductID: "com.chirag.learnfold.hosted.monthly"), .hosted)
        XCTAssertNil(LearnfoldPlan.plan(forProductID: "com.chirag.learnfold.unknown"))
    }

    func testHostedIncludesPlusButNotTheReverse() {
        XCTAssertTrue(LearnfoldPlan.hosted.includes(.plus))
        XCTAssertTrue(LearnfoldPlan.hosted.includes(.hosted))
        XCTAssertTrue(LearnfoldPlan.plus.includes(.plus))
        XCTAssertFalse(LearnfoldPlan.plus.includes(.hosted))
    }

    func testHighestPlanWins() {
        XCTAssertNil(LearnfoldPlan.highest(of: [LearnfoldPlan]()))
        XCTAssertEqual(LearnfoldPlan.highest(of: [.plus]), .plus)
        XCTAssertEqual(LearnfoldPlan.highest(of: [.plus, .hosted]), .hosted)
    }

    func testAccessPolicyGatesHostedAndBringYourOwnButNotApple() {
        XCTAssertEqual(AgentAccessPolicy.requiredPlan(forRuntimeID: CourseAgentProvider.hosted), .hosted)
        XCTAssertEqual(AgentAccessPolicy.requiredPlan(forRuntimeID: CourseAgentProvider.codex), .plus)
        XCTAssertEqual(AgentAccessPolicy.requiredPlan(forRuntimeID: "hermes"), .plus)
        XCTAssertEqual(AgentAccessPolicy.requiredPlan(forRuntimeID: "some-future-runtime"), .plus)
        XCTAssertNil(AgentAccessPolicy.requiredPlan(forRuntimeID: CourseAgentProvider.appleOnDevice))
        XCTAssertNil(AgentAccessPolicy.requiredPlan(forRuntimeID: CourseAgentProvider.applePrivateCloud))
    }

    func testEnforcementConfiguration() {
        let bundle = Bundle(for: LearnfoldPlanTests.self)
        XCTAssertTrue(SubscriptionConfiguration.isEnforced(
            environment: ["LEARNFOLD_SUBSCRIPTIONS_ENFORCED": "1"], bundle: bundle, isDirectDistMac: false
        ))
        XCTAssertFalse(SubscriptionConfiguration.isEnforced(
            environment: ["LEARNFOLD_SUBSCRIPTIONS_ENFORCED": "0"], bundle: bundle, isDirectDistMac: false
        ))
        // The notarized Mac build is outside the App Store, whatever the flag says.
        XCTAssertFalse(SubscriptionConfiguration.isEnforced(
            environment: ["LEARNFOLD_SUBSCRIPTIONS_ENFORCED": "1"], bundle: bundle, isDirectDistMac: true
        ))
        // Absent key and no override: not enforced.
        XCTAssertFalse(SubscriptionConfiguration.isEnforced(environment: [:], bundle: bundle, isDirectDistMac: false))
    }

    func testPaywallCopyUsesStoreKitPricesAndStatesRenewalTerms() {
        XCTAssertEqual(SubscriptionPaywallCopy.priceLine(for: offer(.plus, price: "€0,99")), "€0,99 / month")
        let terms = SubscriptionPaywallCopy.renewalTerms
        XCTAssertTrue(terms.contains("renews automatically"))
        XCTAssertTrue(terms.contains("at least 24 hours"))
        XCTAssertTrue(terms.contains("Apple ID"))
        // Prices must come from StoreKit, never from copy.
        XCTAssertFalse(terms.contains("$"))
        XCTAssertFalse(SubscriptionPaywallCopy.reason(for: .plus).contains("$"))
        XCTAssertFalse(SubscriptionPaywallCopy.reason(for: .hosted).contains("$"))
    }

    func testLegalLinksPointAtTheSite() {
        XCTAssertEqual(SubscriptionLinks.terms.absoluteString, "https://learnfold.pages.dev/terms")
        XCTAssertEqual(SubscriptionLinks.privacy.absoluteString, "https://learnfold.pages.dev/privacy")
    }
}

// MARK: - SubscriptionStore

@MainActor
final class SubscriptionStoreTests: XCTestCase {
    func testStartsWithNoAccess() {
        let store = SubscriptionStore(backend: FakeSubscriptionBackend())
        XCTAssertNil(store.activePlan)
        XCTAssertFalse(store.hasAccess(to: .plus))
        XCTAssertFalse(store.hasAccess(to: .hosted))
    }

    func testPlusUnlocksOnlyBringYourOwn() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [held(.plus)]
        let store = SubscriptionStore(backend: backend)
        await store.refreshEntitlements()
        XCTAssertEqual(store.activePlan, .plus)
        XCTAssertTrue(store.hasAccess(to: .plus))
        XCTAssertFalse(store.hasAccess(to: .hosted))
        XCTAssertTrue(store.hasLoadedEntitlements)
    }

    func testHostedIncludesBringYourOwn() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [held(.hosted)]
        let store = SubscriptionStore(backend: backend)
        await store.refreshEntitlements()
        XCTAssertTrue(store.hasAccess(to: .hosted))
        XCTAssertTrue(store.hasAccess(to: .plus))
    }

    func testUpgradeOverlapReportsTheHigherPlan() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [held(.plus, expires: 100), held(.hosted, expires: 200)]
        let store = SubscriptionStore(backend: backend)
        await store.refreshEntitlements()
        XCTAssertEqual(store.activePlan, .hosted)
    }

    func testLapsedOrRevokedSubscriptionRemovesAccessOnRefresh() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [held(.hosted)]
        let store = SubscriptionStore(backend: backend)
        await store.refreshEntitlements()
        XCTAssertTrue(store.hasAccess(to: .hosted))
        backend.entitlements = []
        await store.refreshEntitlements()
        XCTAssertFalse(store.hasAccess(to: .hosted))
        XCTAssertFalse(store.hasAccess(to: .plus))
    }

    func testTransactionUpdatesRefreshEntitlements() async throws {
        let backend = FakeSubscriptionBackend()
        let store = SubscriptionStore(backend: backend)
        store.start()
        try await waitUntil { store.hasLoadedEntitlements }
        XCTAssertNil(store.activePlan)
        backend.entitlements = [held(.plus)]
        backend.emitUpdate()
        try await waitUntil { store.activePlan == .plus }
    }

    func testOffersExposeLocalizedStoreKitPricesInPlanOrder() async {
        let backend = FakeSubscriptionBackend()
        backend.offerList = [offer(.hosted, price: "CHF 4.90"), offer(.plus, price: "CHF 0.90")]
        let store = SubscriptionStore(backend: backend)
        await store.loadOffers()
        XCTAssertEqual(store.offers.map(\.plan), [.plus, .hosted])
        XCTAssertEqual(store.offer(for: .hosted)?.displayPrice, "CHF 4.90")
        XCTAssertNil(store.offersError)
    }

    func testMissingOrFailedProductsSurfaceAnErrorInsteadOfFakePrices() async {
        let backend = FakeSubscriptionBackend()
        let store = SubscriptionStore(backend: backend)
        await store.loadOffers()
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertNotNil(store.offersError)

        struct Offline: Error {}
        backend.offersError = Offline()
        await store.loadOffers()
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertNotNil(store.offersError)
    }

    func testPurchaseGrantsAccess() async {
        let backend = FakeSubscriptionBackend()
        backend.purchaseGrants = held(.hosted)
        let store = SubscriptionStore(backend: backend)
        let result = await store.purchase(.hosted)
        XCTAssertEqual(result, .purchased)
        XCTAssertEqual(backend.purchasedPlans, [.hosted])
        XCTAssertTrue(store.hasAccess(to: .hosted))
        XCTAssertNil(store.actionError)
    }

    func testPendingPurchaseDoesNotGrantAccess() async {
        let backend = FakeSubscriptionBackend()
        backend.purchaseResult = .success(.pending)
        let store = SubscriptionStore(backend: backend)
        let result = await store.purchase(.plus)
        XCTAssertEqual(result, .pending)
        XCTAssertFalse(store.hasAccess(to: .plus))
        XCTAssertNotNil(store.notice)
    }

    func testCancelledPurchaseIsSilent() async {
        let backend = FakeSubscriptionBackend()
        backend.purchaseResult = .success(.cancelled)
        let store = SubscriptionStore(backend: backend)
        let result = await store.purchase(.plus)
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(store.actionError)
        XCTAssertNil(store.notice)
        XCTAssertFalse(store.hasAccess(to: .plus))
    }

    func testFailedPurchaseReportsAnError() async {
        let backend = FakeSubscriptionBackend()
        backend.purchaseResult = .failure(SubscriptionError.productUnavailable)
        let store = SubscriptionStore(backend: backend)
        let result = await store.purchase(.plus)
        XCTAssertNil(result)
        XCTAssertNotNil(store.actionError)
        XCTAssertFalse(store.hasAccess(to: .plus))
    }

    func testRestoreFindsAnExistingSubscription() async {
        let backend = FakeSubscriptionBackend()
        backend.restoreGrants = held(.plus)
        let store = SubscriptionStore(backend: backend)
        await store.restore()
        XCTAssertEqual(backend.restoreCalls, 1)
        XCTAssertTrue(store.hasAccess(to: .plus))
        XCTAssertEqual(store.notice, "Your subscription was restored.")
    }

    func testRestoreWithNothingToRestoreSaysSo() async {
        let store = SubscriptionStore(backend: FakeSubscriptionBackend())
        await store.restore()
        XCTAssertNil(store.activePlan)
        XCTAssertEqual(store.notice, "No active subscription was found for this Apple Account.")
    }

    func testRestoreFailureIsReported() async {
        struct Offline: Error {}
        let backend = FakeSubscriptionBackend()
        backend.restoreError = Offline()
        let store = SubscriptionStore(backend: backend)
        await store.restore()
        XCTAssertNotNil(store.actionError)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Gating in the course store

@MainActor
final class CourseAgentEntitlementGateTests: XCTestCase {
    private func makeStore(
        selected agentID: String,
        entitlements: FakeEntitlements?,
        enforced: Bool
    ) throws -> (CourseExperienceStore, cleanup: () -> Void) {
        let suite = "EntitlementGate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(agentID, forKey: "snappy.course.selectedAgent")
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: [:],
            hostedRuntime: GateHostedRuntime(),
            entitlements: entitlements,
            enforcesEntitlements: enforced,
            coursesRootURL: root,
            courseControlRootURL: root.appendingPathComponent("control", isDirectory: true)
        )
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        })
    }

    func testFreeUserSendingToHostedSeesTheHostedPaywallAndNothingIsSent() throws {
        let (store, cleanup) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements(), enforced: true)
        defer { cleanup() }
        let sent = store.sendMessage("Teach me biology", appModel: AppModel(), appState: AppState())
        XCTAssertFalse(sent)
        XCTAssertEqual(store.paywallRequest?.requiredPlan, .hosted)
        XCTAssertTrue(store.messages.isEmpty, "A gated send must not leave an optimistic learner message behind")
    }

    func testFreeUserSendingToCodexSeesThePlusPaywall() throws {
        let (store, cleanup) = try makeStore(selected: CourseAgentProvider.codex, entitlements: FakeEntitlements(), enforced: true)
        defer { cleanup() }
        XCTAssertFalse(store.sendMessage("Teach me biology", appModel: AppModel(), appState: AppState()))
        XCTAssertEqual(store.paywallRequest?.requiredPlan, .plus)
    }

    func testDenialMatrix() throws {
        let free = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements(), enforced: true)
        let plus = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements([.plus]), enforced: true)
        let hosted = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements([.hosted]), enforced: true)
        defer { free.cleanup(); plus.cleanup(); hosted.cleanup() }

        XCTAssertEqual(free.0.entitlementDenial(forRuntimeID: CourseAgentProvider.hosted), .hosted)
        XCTAssertEqual(free.0.entitlementDenial(forRuntimeID: CourseAgentProvider.codex), .plus)
        XCTAssertNil(free.0.entitlementDenial(forRuntimeID: CourseAgentProvider.appleOnDevice))
        XCTAssertNil(free.0.entitlementDenial(forRuntimeID: CourseAgentProvider.applePrivateCloud))

        XCTAssertEqual(plus.0.entitlementDenial(forRuntimeID: CourseAgentProvider.hosted), .hosted)
        XCTAssertNil(plus.0.entitlementDenial(forRuntimeID: CourseAgentProvider.codex))
        XCTAssertNil(plus.0.entitlementDenial(forRuntimeID: "hermes"))

        XCTAssertNil(hosted.0.entitlementDenial(forRuntimeID: CourseAgentProvider.hosted))
        XCTAssertNil(hosted.0.entitlementDenial(forRuntimeID: CourseAgentProvider.codex))
    }

    func testFirstRunSetupWithAPaidAgentIsNeverPaywalledAndShowsThePracticeCourse() async throws {
        let (store, cleanup) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements(), enforced: true)
        defer { cleanup() }
        XCTAssertFalse(store.setupComplete)

        // A reviewer with no plan (and no Apple Intelligence) picks Hosted at setup.
        let connected = await store.connectLocalAgent(appModel: AppModel(), agentID: CourseAgentProvider.hosted)
        XCTAssertTrue(connected)
        XCTAssertNil(store.paywallRequest, "Setup must not open a paywall before any value is shown")
        XCTAssertTrue(store.setupComplete)

        // The bundled practice course needs no agent turn, so it is readable now.
        await store.installStarterCourseIfNeeded()
        XCTAssertTrue(store.courses.contains { $0.workspaceID == LearnfoldStarterCourse.workspaceID })
        XCTAssertNil(store.paywallRequest)

        // The first send is where the plan is required.
        XCTAssertFalse(store.sendMessage("Teach me biology", appModel: AppModel(), appState: AppState()))
        XCTAssertEqual(store.paywallRequest?.requiredPlan, .hosted)

        // After setup, choosing another paid agent is gated at selection.
        store.paywallRequest = nil
        let switched = await store.connectLocalAgent(appModel: AppModel(), agentID: CourseAgentProvider.codex)
        XCTAssertFalse(switched)
        XCTAssertEqual(store.paywallRequest?.requiredPlan, .plus)
    }

    func testUnenforcedBuildsNeverGate() throws {
        let (store, cleanup) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements(), enforced: false)
        defer { cleanup() }
        XCTAssertNil(store.entitlementDenial(forRuntimeID: CourseAgentProvider.hosted))
        XCTAssertNil(store.entitlementDenial(forRuntimeID: CourseAgentProvider.codex))
        XCTAssertNil(store.paywallRequest)
    }

    func testEnforcementWithoutAnEntitlementSourceIsIgnored() throws {
        let (store, cleanup) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: nil, enforced: true)
        defer { cleanup() }
        XCTAssertNil(store.entitlementDenial(forRuntimeID: CourseAgentProvider.hosted))
    }

    func testPickerSubtitleNamesTheRequiredPlanOnlyWhenGated() throws {
        let (gated, c1) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements(), enforced: true)
        let (entitled, c2) = try makeStore(selected: CourseAgentProvider.hosted, entitlements: FakeEntitlements([.hosted]), enforced: true)
        defer { c1(); c2() }
        let option = CourseAgentOption(id: CourseAgentProvider.hosted, title: "Hosted", available: true, availabilityDescription: "Ready")
        XCTAssertEqual(gated.subtitle(for: option), "Ready · Requires Learnfold Hosted")
        XCTAssertEqual(entitled.subtitle(for: option), "Ready")
    }
}

@MainActor
private final class GateHostedRuntime: HostedCourseAgentRuntime {
    func availability() -> HostedCourseAgentAvailability { .init(available: true, reason: "Ready") }
    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] { [] }
    func send(
        sessionID: UUID,
        workspaceID: String,
        courseDirectory: URL,
        prompt: String,
        messageID: UUID?,
        role: CourseAgentThreadRole,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) async throws {}
    func cancel(sessionID: UUID) {}
}

// MARK: - RevenueCat identity and configuration

final class HostedSubscriptionIdentityTests: XCTestCase {
    func testAppUserIDMatchesTheWorkerTestVector() {
        // Pinned by services/hosted-agent/test/revenuecat.test.ts. If this
        // fails, the Worker would look subscribers up under a different ID.
        let secret = String(repeating: "0123456789abcdef", count: 4)
        XCTAssertEqual(
            HostedGuestIdentity.revenueCatAppUserID(secret: secret),
            "lf1_66f345ab9622be22e4a3762e6d7609f6da48c3e45ca3bb1df0246e943d6e0756"
        )
    }

    func testAppUserIDIsOneWayAndDiffersFromTheConversationNamespace() {
        let secret = String(repeating: "ab", count: 32)
        let id = HostedGuestIdentity.revenueCatAppUserID(secret: secret)
        XCTAssertFalse(id.contains(secret))
        XCTAssertFalse(id.contains(HostedGuestIdentity.fingerprint(secret)))
        XCTAssertNotEqual(id, "guest-\(HostedGuestIdentity.fingerprint(secret))")
        XCTAssertNotEqual(id, HostedGuestIdentity.revenueCatAppUserID(secret: String(repeating: "cd", count: 32)))
        XCTAssertNotNil(id.range(of: "^lf1_[0-9a-f]{64}$", options: .regularExpression))
    }

    func testExistingIdentityNeverCreatesOneAndSeesAPromotedIdentity() throws {
        let storage = MemoryStorage()
        let secret = String(repeating: "7", count: 64)
        let repository = HostedGuestIdentityRepository(storage: storage, makeSecret: { secret })
        XCTAssertNil(try repository.existingIdentity(serviceURL: "https://agent.example"))
        XCTAssertTrue(storage.values.isEmpty, "A launch-time lookup must not write to the keychain")

        let created = try repository.identity(serviceURL: "https://agent.example")
        XCTAssertEqual(created.secret, secret)
        let existing = try XCTUnwrap(try repository.existingIdentity(serviceURL: "https://agent.example"))
        XCTAssertEqual(existing.secret, secret)
        XCTAssertEqual(existing.ownerSubject, created.ownerSubject)
        XCTAssertNil(try repository.existingIdentity(serviceURL: "https://other.example"))
    }

    private struct Key: Hashable { let service: String; let account: String }
    private final class MemoryStorage: HostedGuestIdentityStorage {
        var values: [Key: Data] = [:]
        func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
            values[Key(service: service, account: account)]
        }
        func insert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
            let key = Key(service: service, account: account)
            if values[key] == nil { values[key] = data }
        }
    }
}

final class RevenueCatConfigurationTests: XCTestCase {
    private let bundle = Bundle(for: RevenueCatConfigurationTests.self)

    func testEmptyOrMissingKeyMeansNoRevenueCat() {
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(environment: [:], bundle: bundle))
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(environment: ["LEARNFOLD_REVENUECAT_API_KEY": ""], bundle: bundle))
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(environment: ["LEARNFOLD_REVENUECAT_API_KEY": "  \n"], bundle: bundle))
    }

    func testAnUnexpandedBuildSettingIsTreatedAsEmpty() {
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(
            environment: ["LEARNFOLD_REVENUECAT_API_KEY": "$(LEARNFOLD_REVENUECAT_API_KEY)"], bundle: bundle
        ))
    }

    func testSecretKeysAreNeverUsedInTheApp() {
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(
            environment: ["LEARNFOLD_REVENUECAT_API_KEY": "sk_not_for_the_app"], bundle: bundle
        ))
    }

    func testAPublicKeyIsTrimmedAndAccepted() {
        XCTAssertEqual(
            RevenueCatConfiguration.publicSDKKey(environment: ["LEARNFOLD_REVENUECAT_API_KEY": " appl_abc123 \n"], bundle: bundle),
            "appl_abc123"
        )
    }

    func testTheCheckedInProjectShipsNoKey() {
        // The test bundle inherits the app's build settings; the source tree
        // must hold an empty key so no secret or real key is ever committed.
        XCTAssertNil(RevenueCatConfiguration.publicSDKKey(environment: [:], bundle: Bundle(for: SubscriptionStore.self)))
    }

    func testEntitlementIdentifiersAreStable() {
        XCTAssertEqual(LearnfoldPlan.plus.entitlementID, "plus")
        XCTAssertEqual(LearnfoldPlan.hosted.entitlementID, "hosted")
    }
}

/// With no RevenueCat key the app must degrade, never crash.
@MainActor
final class UnavailablePurchasesTests: XCTestCase {
    func testWithoutAKeyReleaseStyleBuildsGetTheUnavailableBackend() {
        // Outside UI-test mode and with no key, the factory returns either the
        // unavailable backend (release) or the local StoreKit one (debug).
        let backend = SubscriptionBackendFactory.live(environment: [:], arguments: [], bundle: Bundle(for: SubscriptionStore.self))
        #if DEBUG
        XCTAssertTrue(backend is StoreKitSubscriptionBackend)
        #else
        XCTAssertTrue(backend is UnavailableSubscriptionBackend)
        #endif
    }

    func testUITestingCanForceTheUnavailableBackend() {
        let backend = SubscriptionBackendFactory.live(
            environment: ["LEARNFOLD_UI_TESTING": "1"],
            arguments: [SubscriptionBackendFactory.unavailableArgument],
            bundle: Bundle(for: SubscriptionStore.self)
        )
        #if DEBUG
        XCTAssertFalse(backend.isAvailable)
        #endif
    }

    func testUnavailableStoreSaysSoAndOffersNothing() async {
        let store = SubscriptionStore(backend: UnavailableSubscriptionBackend())
        XCTAssertFalse(store.purchasesAvailable)
        await store.loadOffers()
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertEqual(store.offersError, SubscriptionStore.purchasesUnavailableMessage)
        XCTAssertNil(store.offer(for: .hosted))
    }

    func testUnavailablePurchaseAndRestoreReportAndGrantNothing() async {
        let store = SubscriptionStore(backend: UnavailableSubscriptionBackend())
        let result = await store.purchase(.plus)
        XCTAssertNil(result)
        XCTAssertEqual(store.actionError, SubscriptionStore.purchasesUnavailableMessage)
        XCTAssertFalse(store.hasAccess(to: .plus))
        await store.restore()
        XCTAssertEqual(store.actionError, SubscriptionStore.purchasesUnavailableMessage)
        XCTAssertNil(store.activePlan)
        store.start()
        await store.refreshEntitlements()
        XCTAssertTrue(store.hasLoadedEntitlements)
        XCTAssertNil(store.activePlan)
    }

    func testAnUnavailableBuildNeverEnforcesGating() throws {
        // Mirrors ContentView: enforcement requires a store that can sell.
        let store = SubscriptionStore(backend: UnavailableSubscriptionBackend())
        let enforces = SubscriptionConfiguration.isEnforced(
            environment: ["LEARNFOLD_SUBSCRIPTIONS_ENFORCED": "1"],
            bundle: Bundle(for: SubscriptionStore.self),
            isDirectDistMac: false
        ) && store.purchasesAvailable
        XCTAssertFalse(enforces)
    }
}
