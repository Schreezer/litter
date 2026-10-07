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

private func held(
    _ plan: LearnfoldPlan,
    expires: TimeInterval = 86_400,
    jws: String? = nil
) -> HeldEntitlement {
    HeldEntitlement(
        plan: plan,
        expirationDate: Date(timeIntervalSinceNow: expires),
        willAutoRenew: true,
        signedTransaction: jws ?? "jws-\(plan.rawValue)-\(Int(expires))"
    )
}

private func offer(_ plan: LearnfoldPlan, price: String) -> PlanOffer {
    PlanOffer(plan: plan, displayName: plan.title, displayPrice: price, periodDescription: "month")
}

@MainActor
private final class FakeEntitlements: EntitlementProviding {
    var plans: Set<LearnfoldPlan> = []
    var hosted: String?
    init(_ plans: Set<LearnfoldPlan> = []) { self.plans = plans }
    func hasAccess(to plan: LearnfoldPlan) -> Bool { plans.contains { $0.includes(plan) } }
    func hostedSignedTransaction() async -> String? { hosted }
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
        backend.purchaseResult = .failure(SubscriptionError.unverifiedTransaction)
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
        XCTAssertEqual(store.notice, "No active subscription was found for this Apple ID.")
    }

    func testRestoreFailureIsReported() async {
        struct Offline: Error {}
        let backend = FakeSubscriptionBackend()
        backend.restoreError = Offline()
        let store = SubscriptionStore(backend: backend)
        await store.restore()
        XCTAssertNotNil(store.actionError)
    }

    func testHostedSignedTransactionIsTheFreshestHostedOne() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [
            held(.hosted, expires: 100, jws: "old"),
            held(.hosted, expires: 900, jws: "new"),
            held(.plus, expires: 5_000, jws: "plus"),
        ]
        let store = SubscriptionStore(backend: backend)
        let jws = await store.hostedSignedTransaction()
        XCTAssertEqual(jws, "new")
    }

    func testPlusAloneNeverProducesAHostedTransaction() async {
        let backend = FakeSubscriptionBackend()
        backend.entitlements = [held(.plus)]
        let store = SubscriptionStore(backend: backend)
        let jws = await store.hostedSignedTransaction()
        XCTAssertNil(jws)
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
            coursesRootURL: root
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

// MARK: - Hosted token exchange

final class HostedSubscriptionExchangeTests: XCTestCase {
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                stream.close()
                Self.lastBody = data
            } else {
                Self.lastBody = request.httpBody
            }
            let (status, body) = Self.handler?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func exchange() -> HostedSubscriptionExchange {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HostedSubscriptionExchange(session: URLSession(configuration: configuration))
    }

    private let secret = String(repeating: "a", count: 64)

    func testEndpointMirrorsTheRustGuestExchange() throws {
        XCTAssertEqual(
            try HostedSubscriptionExchange.endpoint(serviceURL: "wss://agent.example/runtime", sessionID: "s1").absoluteString,
            "https://agent.example/guest-session?sessionId=s1"
        )
        XCTAssertEqual(
            try HostedSubscriptionExchange.endpoint(serviceURL: "http://localhost:8787", sessionID: "s1").absoluteString,
            "http://localhost:8787/guest-session?sessionId=s1"
        )
        XCTAssertThrowsError(try HostedSubscriptionExchange.endpoint(serviceURL: "http://agent.example", sessionID: "s1"))
    }

    func testSuccessfulExchangeSendsGuestSecretAndTransaction() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"accessToken":"minted"}"#.utf8)) }
        let token = try await exchange().accessToken(
            serviceURL: "https://agent.example", guestSecret: secret, sessionID: "session-1", signedTransaction: "a.b.c"
        )
        XCTAssertEqual(token, "minted")
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "Guest \(secret)")
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["signedTransaction": "a.b.c"])
    }

    func testPaymentRequiredMapsToSubscriptionRequired() async {
        StubProtocol.handler = { _ in (402, Data(#"{"error":"subscription_invalid"}"#.utf8)) }
        do {
            _ = try await exchange().accessToken(
                serviceURL: "https://agent.example", guestSecret: secret, sessionID: "s", signedTransaction: "x"
            )
            XCTFail("Expected a subscription error")
        } catch let error as HostedCourseAgentRuntimeError {
            guard case .subscriptionRequired = error else { return XCTFail("Wrong error \(error)") }
        } catch {
            XCTFail("Wrong error \(error)")
        }
    }

    @MainActor
    func testSubscriptionRefusalKeepsItsMessage() {
        let error = HostedCourseAgentRuntimeError.subscriptionRequired("needs plan")
        XCTAssertEqual(CourseExperienceStore.hostedAgentFailureMessage(error), "needs plan")
    }
}
