import XCTest
@testable import Litter

final class HostedCourseContinuationTests: XCTestCase {
    private let service = "https://agent.learnfold.test"

    func testLegacyIdentityMigratesWithoutChangingHostedNamespaceAndTransfersToAnotherDevice() throws {
        let cloud = SharedCredentials()
        let phone = MemoryCredentials(cloud: cloud)
        phone.local[.init(service: HostedGuestIdentityRepository.legacyService, account: service)] = Data(String(repeating: "a", count: 64).utf8)
        let original = try repository(phone).identity(serviceURL: service)
        XCTAssertEqual(original.ownerSubject, "guest-\(HostedGuestIdentity.fingerprint(String(repeating: "a", count: 64)))")
        let mac = MemoryCredentials(cloud: cloud)
        let transferred = try repository(mac).identity(serviceURL: service, ownerSubject: original.ownerSubject)
        XCTAssertEqual(transferred.ownerSubject, original.ownerSubject)
        XCTAssertEqual(transferred.secret, original.secret)
        XCTAssertEqual(try repository(mac).identity(serviceURL: service).ownerSubject, original.ownerSubject)
        XCTAssertEqual(phone.local.count, 1, "Migration must preserve the legacy identity until every old course has its locator.")
    }

    func testMissingSyncedOwnerFailsClosedWithoutCreatingAnEmptyConversation() {
        let storage = MemoryCredentials(cloud: SharedCredentials())
        var generated = false
        let repository = HostedGuestIdentityRepository(storage: storage, makeSecret: {
            generated = true
            return String(repeating: "b", count: 64)
        })
        XCTAssertThrowsError(try repository.identity(serviceURL: service, ownerSubject: "guest-\(String(repeating: "a", count: 64))")) {
            XCTAssertTrue($0.localizedDescription.contains("iCloud Keychain"))
        }
        XCTAssertFalse(generated)
        XCTAssertTrue(storage.cloud.values.isEmpty)
    }

    func testBothExistingDeviceOwnersRemainAvailableAfterSynchronization() throws {
        let cloud = SharedCredentials()
        let phone = MemoryCredentials(cloud: cloud)
        let mac = MemoryCredentials(cloud: cloud)
        phone.local[.init(service: HostedGuestIdentityRepository.legacyService, account: service)] = Data(String(repeating: "a", count: 64).utf8)
        mac.local[.init(service: HostedGuestIdentityRepository.legacyService, account: service)] = Data(String(repeating: "b", count: 64).utf8)
        let phoneOwner = try repository(phone).identity(serviceURL: service)
        let macOwner = try repository(mac).identity(serviceURL: service)
        XCTAssertNotEqual(phoneOwner.ownerSubject, macOwner.ownerSubject)
        XCTAssertEqual(try repository(mac).identity(serviceURL: service, ownerSubject: phoneOwner.ownerSubject).secret, phoneOwner.secret)
        XCTAssertEqual(try repository(phone).identity(serviceURL: service, ownerSubject: macOwner.ownerSubject).secret, macOwner.secret)
    }

    func testPreferenceArrivingBeforeCredentialWaitsInsteadOfMintingAnotherOwner() {
        let cloud = SharedCredentials()
        cloud.values[.init(service: HostedGuestIdentityRepository.preferenceService, account: HostedGuestIdentity.fingerprint(service))] = Data("guest-\(String(repeating: "a", count: 64))".utf8)
        let storage = MemoryCredentials(cloud: cloud)
        XCTAssertThrowsError(try repository(storage).identity(serviceURL: service)) {
            XCTAssertTrue($0.localizedDescription.contains("iCloud Keychain"))
        }
        XCTAssertEqual(cloud.values.count, 1)
    }

    func testBoundOwnerRejectsCredentialWithAnotherFingerprint() {
        let cloud = SharedCredentials()
        let subject = "guest-\(String(repeating: "c", count: 64))"
        cloud.values[.init(service: HostedGuestIdentityRepository.identityService, account: "\(HostedGuestIdentity.fingerprint(service))|\(subject)")] = Data(String(repeating: "a", count: 64).utf8)
        XCTAssertThrowsError(try repository(MemoryCredentials(cloud: cloud)).identity(serviceURL: service, ownerSubject: subject)) {
            XCTAssertTrue($0.localizedDescription.contains("doesn't match"))
        }
    }

    func testPortableBindingContainsNoGuestSecret() throws {
        let secret = String(repeating: "a", count: 64)
        let binding = HostedCourseIdentityBinding(serviceBaseURL: service, ownerSubject: "guest-\(HostedGuestIdentity.fingerprint(secret))")
        let json = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertEqual(try JSONDecoder().decode(HostedCourseIdentityBinding.self, from: Data(json.utf8)), binding)
    }

    @MainActor
    func testConfiguredAccountRequiresTheExactPortableOwnerAndService() throws {
        let runtime = SystemHostedCourseAgentRuntime(environment: [
            "LEARNFOLD_HOSTED_AGENT_URL": service,
            "LEARNFOLD_HOSTED_ACCESS_TOKEN": "test-credential",
        ])
        let binding = try XCTUnwrap(runtime.identityBinding())
        XCTAssertEqual(binding.ownerSubject, "access-\(HostedGuestIdentity.fingerprint("test-credential"))")
        XCTAssertNoThrow(try runtime.configureSession(sessionID: UUID(), binding: binding))
        XCTAssertThrowsError(try runtime.configureSession(sessionID: UUID(), binding: .init(serviceBaseURL: "https://another.test", ownerSubject: binding.ownerSubject)))
        XCTAssertThrowsError(try runtime.configureSession(sessionID: UUID(), binding: .init(serviceBaseURL: service, ownerSubject: "guest-\(String(repeating: "b", count: 64))")))
    }

    @MainActor
    func testOpeningAnotherMacWindowCannotRecoverOrReplaceTheFirstWindowsLiveTurn() async throws {
        let gate = SuspendedTurn()
        let client = PausedHostedClient(gate: gate)
        let environment = ["LEARNFOLD_HOSTED_AGENT_URL": service, "LEARNFOLD_HOSTED_ACCESS_TOKEN": "test-credential"]
        let firstWindow = SystemHostedCourseAgentRuntime(environment: environment, clientFactory: { client })
        let secondWindow = SystemHostedCourseAgentRuntime(environment: environment, clientFactory: { client })
        let sessionID = UUID()
        let running = Task { try await firstWindow.review(sessionID: sessionID, workspaceID: "course-a", prompt: "Review") }
        await gate.waitUntilStarted()
        let recovered = try await secondWindow.recoverInterruptedSession(
            sessionID: sessionID, workspaceID: "course-a", courseDirectory: URL(fileURLWithPath: "/unused-test-course")
        )
        XCTAssertFalse(recovered)
        let readsDuringTurn = await gate.historyReads
        XCTAssertEqual(readsDuringTurn, 0, "A second window must not even start recovery/history refresh while native work is live.")
        do {
            _ = try await secondWindow.review(sessionID: sessionID, workspaceID: "course-a", prompt: "Duplicate")
            XCTFail("A second window replaced a live Hosted turn.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("another Learnfold window"))
        }
        await gate.finish()
        _ = try await running.value
        let recoveredIdle = try await secondWindow.recoverInterruptedSession(
            sessionID: sessionID, workspaceID: "course-a", courseDirectory: URL(fileURLWithPath: "/unused-test-course")
        )
        XCTAssertFalse(recoveredIdle)
        let readsAfterTurn = await gate.historyReads
        XCTAssertEqual(readsAfterTurn, 1, "The other window can inspect authoritative idle state once the first turn finishes.")
    }

    private func repository(_ storage: MemoryCredentials) -> HostedGuestIdentityRepository {
        HostedGuestIdentityRepository(storage: storage, makeSecret: {
            XCTFail("These continuation scenarios must not mint a replacement guest identity.")
            return String(repeating: "f", count: 64)
        })
    }

    private struct CredentialKey: Hashable {
        let service: String
        let account: String
    }

    private final class SharedCredentials {
        var values: [CredentialKey: Data] = [:]
    }

    private final class MemoryCredentials: HostedGuestIdentityStorage {
        let cloud: SharedCredentials
        var local: [CredentialKey: Data] = [:]
        init(cloud: SharedCredentials) { self.cloud = cloud }
        func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
            let key = CredentialKey(service: service, account: account)
            return synchronizable ? cloud.values[key] : local[key]
        }
        func insert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
            let key = CredentialKey(service: service, account: account)
            if synchronizable {
                if cloud.values[key] == nil { cloud.values[key] = data }
            } else if local[key] == nil { local[key] = data }
        }
    }

    private actor SuspendedTurn {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var completion: CheckedContinuation<Void, Never>?
        var historyReads = 0
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func pause() async {
            started = true
            waiter?.resume()
            waiter = nil
            await withCheckedContinuation { completion = $0 }
        }
        func finish() { completion?.resume(); completion = nil }
        func recordHistoryRead() { historyReads += 1 }
    }

    private final class PausedHostedClient: HostedAgentClient, @unchecked Sendable {
        let gate: SuspendedTurn
        init(gate: SuspendedTurn) {
            self.gate = gate
            super.init(noHandle: HostedAgentClient.NoHandle())
        }
        required init(unsafeFromHandle handle: UInt64) { fatalError("Test client has no Rust handle") }
        override func send(
            sessionId: String, workspaceId: String, prompt: String, messageId: String?,
            tools: [HostedAgentToolDefinition], toolHandler: HostedAgentToolHandler, listener: HostedAgentEventListener
        ) async throws -> HostedAgentTurnResult {
            await gate.pause()
            return .init(sessionId: sessionId, responseText: "Review saved")
        }
        override func loadSession(sessionId: String) async throws -> HostedAgentSessionSnapshot {
            await gate.recordHistoryRead()
            return .init(messages: [], active: false, originatingDevice: false, waitingForTools: false)
        }
    }
}
