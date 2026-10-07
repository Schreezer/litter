import Foundation
import Security
import CryptoKit

/// A portable locator, never a credential. The secret stays in iCloud Keychain.
struct HostedCourseIdentityBinding: Codable, Equatable, Sendable {
    let serviceBaseURL: String
    let ownerSubject: String
}

/// Transient presentation of a Hosted request, never persisted as runtime state.
struct HostedReplyProgress: Equatable {
    var id = UUID()
    var lastProgressAt = Date()
    var isRecovering = false

    func label(at date: Date) -> String? {
        if isRecovering { return "Hosted is retrying…" }
        if date.timeIntervalSince(lastProgressAt) >= 30 { return "Waiting for Hosted…" }
        return nil
    }
}

struct HostedCourseAgentAvailability: Equatable {
    let available: Bool
    let reason: String
}

struct HostedCourseAgentStoredMessage: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case learner
        case agent
    }

    /// Think's message id. For learner messages it is the optimistic id the
    /// phone sent, so a restored transcript proves which sends arrived.
    let id: String?
    let role: Role
    let text: String

    init(id: String? = nil, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

@MainActor
protocol HostedCourseAgentRuntime: AnyObject {
    func availability() -> HostedCourseAgentAvailability
    func identityBinding() throws -> HostedCourseIdentityBinding?
    func configureSession(sessionID: UUID, binding: HostedCourseIdentityBinding?) throws
    func recoverInterruptedSession(sessionID: UUID, workspaceID: String, courseDirectory: URL) async throws -> Bool
    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage]
    func review(sessionID: UUID, workspaceID: String, prompt: String) async throws -> String
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
    ) async throws
    func cancel(sessionID: UUID)
}

extension HostedCourseAgentRuntime {
    func identityBinding() throws -> HostedCourseIdentityBinding? { nil }
    func configureSession(sessionID: UUID, binding: HostedCourseIdentityBinding?) throws {}
    func recoverInterruptedSession(sessionID: UUID, workspaceID: String, courseDirectory: URL) async throws -> Bool { false }

    func review(sessionID: UUID, workspaceID: String, prompt: String) async throws -> String {
        throw CourseAssessmentReviewRuntimeError.unavailable(
            "This Hosted runtime does not support exercise review."
        )
    }
}

@MainActor
final class SystemHostedCourseAgentRuntime: HostedCourseAgentRuntime {
    static let modelID = "muse-spark-1.3-contributor"
    // Each Mac window owns a runtime instance. Native work must remain owned
    // across all of them so opening another window cannot abort a live tool.
    private static var processActiveSessions: [UUID: UUID] = [:]

    private let baseURL: String?
    private let accessToken: String?
    private let clientFactory: (() throws -> HostedAgentClient)?
    private var activeTasks: [UUID: Task<HostedAgentTurnResult, Error>] = [:]
    private var activeClients: [UUID: HostedAgentClient] = [:]
    private var sessionBindings: [UUID: HostedCourseIdentityBinding] = [:]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        clientFactory: (() throws -> HostedAgentClient)? = nil
    ) {
        self.clientFactory = clientFactory
        baseURL = Self.configurationValue(
            environmentKey: "LEARNFOLD_HOSTED_AGENT_URL",
            bundleKey: "LearnfoldHostedAgentURL",
            environment: environment,
            bundle: bundle
        )
        accessToken = Self.configurationValue(
            environmentKey: "LEARNFOLD_HOSTED_ACCESS_TOKEN",
            bundleKey: "LearnfoldHostedAccessToken",
            environment: environment,
            bundle: bundle
        )
    }

    func availability() -> HostedCourseAgentAvailability {
        guard baseURL != nil else {
            return .init(
                available: false,
                reason: "Hosted isn't available in this build. Choose another agent."
            )
        }
        return .init(
            available: true,
            reason: accessToken == nil
                ? "Ready to use. No login needed."
                : "Cloud-hosted · \(Self.modelID) · durable session"
        )
    }

    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] {
        try await client(sessionID: sessionID).loadMessages(sessionId: sessionID.uuidString.lowercased()).compactMap {
            switch $0.role {
            case "user": .init(id: $0.id, role: .learner, text: $0.text)
            case "assistant": .init(id: $0.id, role: .agent, text: $0.text)
            default: nil
            }
        }
    }

    func recoverInterruptedSession(sessionID: UUID, workspaceID: String, courseDirectory: URL) async throws -> Bool {
        guard Self.processActiveSessions[sessionID] == nil else { return false }
        let ownership = try claimSession(sessionID)
        defer { releaseSession(sessionID, ownership: ownership) }
        let client = try client(sessionID: sessionID)
        let session = try await client.loadSession(sessionId: sessionID.uuidString.lowercased())
        guard session.active, session.originatingDevice, session.waitingForTools else { return false }
        let databaseURL = courseDirectory.appendingPathComponent(".course/course-library.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw HostedCourseAgentRuntimeError.unavailable(
                "Open and sync this course's native pages on its original device before recovering its interrupted Hosted task."
            )
        }
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID, databaseURL: databaseURL, rootTitle: "Course"
        )
        _ = try await repository.flushPendingUserEdits()
        let pages = try await repository.workspaceSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipt = SHA256.hash(data: try encoder.encode(pages)).map { String(format: "%02x", $0) }.joined()
        guard Self.processActiveSessions[sessionID] == ownership, activeTasks[sessionID] == nil else { return false }
        return try await client.recoverInterruptedSession(
            sessionId: sessionID.uuidString.lowercased(), workspaceId: workspaceID,
            refreshedPagesReceipt: receipt
        )
    }

    /// Reviews one submitted answer in its own session. No course editor tools
    /// or callbacks are available, and no visible discussion is reused.
    func review(sessionID: UUID, workspaceID: String, prompt: String) async throws -> String {
        let ownership = try claimSession(sessionID)
        defer { releaseSession(sessionID, ownership: ownership) }
        let client = try client(sessionID: sessionID)
        let task = Task {
            try await client.send(
                sessionId: sessionID.uuidString.lowercased(),
                workspaceId: workspaceID,
                prompt: prompt,
                messageId: nil,
                tools: [],
                toolHandler: HostedAssessmentReviewToolHandler(),
                listener: HostedAssessmentReviewEventListener()
            )
        }
        activeClients[sessionID] = client
        activeTasks[sessionID] = task
        defer {
            activeTasks[sessionID] = nil
            activeClients[sessionID] = nil
        }
        return try await task.value.responseText
    }

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
    ) async throws {
        let ownership = try claimSession(sessionID)
        defer { releaseSession(sessionID, ownership: ownership) }
        // The hosted service reads a missing plan tool as a discussion inside
        // an existing course and swaps in its no-replanning instructions.
        let definitions = try CourseAgentTools.mcpToolDefinitions(
            includePresentPlan: role == .course
        ).map { definition in
            let schema = try JSONSerialization.data(
                withJSONObject: definition.inputSchema,
                options: [.sortedKeys]
            )
            return HostedAgentToolDefinition(
                name: definition.name,
                description: definition.description,
                parametersJson: String(decoding: schema, as: UTF8.self)
            )
        }
        let handler = HostedCourseToolHandler(
            workspaceID: workspaceID,
            courseDirectory: courseDirectory,
            onCoursePlan: onCoursePlan
        )
        let listener = HostedCourseEventListener(
            onPartialResponse: onPartialResponse,
            onRecoveringChanged: onRecoveringChanged
        )
        let client = try client(sessionID: sessionID)
        let task = Task {
            try await client.send(
                sessionId: sessionID.uuidString.lowercased(),
                workspaceId: workspaceID,
                prompt: prompt,
                messageId: messageID?.uuidString.lowercased(),
                tools: definitions,
                toolHandler: handler,
                listener: listener
            )
        }
        activeClients[sessionID] = client
        activeTasks[sessionID] = task
        defer {
            activeTasks[sessionID] = nil
            activeClients[sessionID] = nil
        }
        do {
            _ = try await task.value
            await listener.finishDelivery()
        } catch {
            // Deliver received text before the caller decides whether the
            // request was accepted. The stream can fail right after a delta.
            await listener.finishDelivery()
            throw error
        }
    }

    func cancel(sessionID: UUID) {
        _ = try? activeClients[sessionID]?.cancel(
            sessionId: sessionID.uuidString.lowercased()
        )
        activeTasks[sessionID]?.cancel()
        activeTasks[sessionID] = nil
        activeClients[sessionID] = nil
    }

    private func claimSession(_ sessionID: UUID) throws -> UUID {
        guard Self.processActiveSessions[sessionID] == nil else {
            throw HostedCourseAgentRuntimeError.unavailable(
                "This Hosted conversation is already working in another Learnfold window. Wait for that task to finish before continuing here."
            )
        }
        let ownership = UUID()
        Self.processActiveSessions[sessionID] = ownership
        return ownership
    }

    private func releaseSession(_ sessionID: UUID, ownership: UUID) {
        if Self.processActiveSessions[sessionID] == ownership { Self.processActiveSessions[sessionID] = nil }
    }

    func identityBinding() throws -> HostedCourseIdentityBinding? {
        guard let baseURL else {
            throw HostedCourseAgentRuntimeError.unavailable(availability().reason)
        }
        let ownerSubject: String
        if let accessToken {
            ownerSubject = "access-\(HostedGuestIdentity.fingerprint(accessToken))"
        } else {
            ownerSubject = try HostedGuestIdentity.identity(serviceURL: baseURL).ownerSubject
        }
        return .init(serviceBaseURL: baseURL, ownerSubject: ownerSubject)
    }

    func configureSession(sessionID: UUID, binding: HostedCourseIdentityBinding?) throws {
        // Install the locator before resolving it so a delayed credential can
        // never make a subsequent retry fall back to a fresh guest identity.
        sessionBindings[sessionID] = binding
        if binding != nil { _ = try client(sessionID: sessionID) }
    }

    private func client(sessionID: UUID) throws -> HostedAgentClient {
        guard let baseURL else {
            throw HostedCourseAgentRuntimeError.unavailable(availability().reason)
        }
        if let clientFactory { return try clientFactory() }
        let binding = sessionBindings[sessionID]
        if let binding, binding.serviceBaseURL != baseURL {
            throw HostedCourseAgentRuntimeError.unavailable(
                "This conversation uses a different Hosted service. Reconnect that service to continue its saved history."
            )
        }
        let client: HostedAgentClient
        if let accessToken {
            if let binding, binding.ownerSubject != "access-\(HostedGuestIdentity.fingerprint(accessToken))" {
                throw HostedCourseAgentRuntimeError.unavailable(
                    "This conversation belongs to a different Hosted account. Reconnect its original account to continue."
                )
            }
            client = try HostedAgentClient(baseUrl: baseURL, accessToken: accessToken)
        } else {
            let identity = try HostedGuestIdentity.identity(
                serviceURL: baseURL,
                ownerSubject: binding?.ownerSubject
            )
            client = try HostedAgentClient.guest(baseUrl: baseURL, guestSecret: identity.secret)
        }
        try client.setOriginId(originId: HostedGuestIdentity.deviceOriginID())
        return client
    }

    private static func configurationValue(
        environmentKey: String,
        bundleKey: String,
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        if let value = environment[environmentKey] {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return (bundle.object(forInfoDictionaryKey: bundleKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private final class HostedAssessmentReviewToolHandler: HostedAgentToolHandler, Sendable {
    func executeHostedTool(invocation: HostedAgentToolInvocation) -> HostedAgentToolResult {
        HostedAgentToolResult(
            success: false,
            output: "{}",
            errorMessage: "Exercise review has no tools. Return the review directly."
        )
    }
}

private final class HostedAssessmentReviewEventListener: HostedAgentEventListener, Sendable {
    func onResponseDelta(delta: String) {}
    func onRecoveringChanged(recovering: Bool) {}
}

/// Platform persistence only. Token minting and authentication stay in Rust.
/// Per-owner entries let two devices keep their earlier identities side by side.
struct HostedGuestIdentityCredential {
    let ownerSubject: String
    let secret: String
}

protocol HostedGuestIdentityStorage {
    func read(service: String, account: String, synchronizable: Bool) throws -> Data?
    func insert(_ data: Data, service: String, account: String, synchronizable: Bool) throws
}

struct HostedGuestIdentityRepository {
    static let legacyService = "com.chirag.learnfold.hosted-guest"
    static let identityService = "com.chirag.learnfold.hosted-guest.identities"
    static let preferenceService = "com.chirag.learnfold.hosted-guest.preferred"

    let storage: any HostedGuestIdentityStorage
    var makeSecret: () throws -> String = HostedGuestIdentity.randomSecret

    func identity(serviceURL: String, ownerSubject: String? = nil) throws -> HostedGuestIdentityCredential {
        let serviceKey = HostedGuestIdentity.fingerprint(serviceURL)
        if let ownerSubject {
            guard ownerSubject.range(of: "^guest-[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw HostedCourseAgentRuntimeError.unavailable("This saved Hosted conversation has an invalid account binding.")
            }
            if let data = try storage.read(
                service: Self.identityService, account: "\(serviceKey)|\(ownerSubject)", synchronizable: true
            ) {
                return try credential(data, expectedSubject: ownerSubject)
            }
            // A local course predating synchronization still owns its original
            // device secret. Promote it without changing the hosted namespace.
            if let legacy = try legacyIdentity(serviceURL: serviceURL), legacy.ownerSubject == ownerSubject {
                try promote(legacy, serviceKey: serviceKey)
                return legacy
            }
            throw HostedCourseAgentRuntimeError.unavailable(
                "Waiting for this conversation's iCloud Keychain identity. Enable iCloud Keychain on both devices, unlock them, and retry. Its saved history will remain in the original Hosted account."
            )
        }

        if let legacy = try legacyIdentity(serviceURL: serviceURL) {
            try promote(legacy, serviceKey: serviceKey)
            return legacy
        }
        if let preference = try storage.read(
            service: Self.preferenceService, account: serviceKey, synchronizable: true
        ) {
            guard let subject = String(data: preference, encoding: .utf8) else {
                throw HostedCourseAgentRuntimeError.unavailable("Couldn't read your saved Hosted account binding.")
            }
            // A preference can arrive before its secret. This must wait rather
            // than silently open a new account and empty conversation.
            return try identity(serviceURL: serviceURL, ownerSubject: subject)
        }
        let secret = try makeSecret()
        let created = try credential(Data(secret.utf8), expectedSubject: nil)
        try promote(created, serviceKey: serviceKey)
        // Insert-only preference: concurrent installs may discover different
        // legacy accounts, but never overwrite their other owner entries.
        if let preference = try storage.read(
            service: Self.preferenceService, account: serviceKey, synchronizable: true
        ), let subject = String(data: preference, encoding: .utf8), subject != created.ownerSubject {
            return try identity(serviceURL: serviceURL, ownerSubject: subject)
        }
        return created
    }

    private func legacyIdentity(serviceURL: String) throws -> HostedGuestIdentityCredential? {
        guard let data = try storage.read(
            service: Self.legacyService, account: serviceURL, synchronizable: false
        ) else { return nil }
        return try credential(data, expectedSubject: nil)
    }

    private func credential(_ data: Data, expectedSubject: String?) throws -> HostedGuestIdentityCredential {
        guard let secret = String(data: data, encoding: .utf8),
              secret.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw HostedCourseAgentRuntimeError.unavailable("Couldn't read your Hosted identity. Unlock your device and retry.")
        }
        let subject = "guest-\(HostedGuestIdentity.fingerprint(secret))"
        guard expectedSubject == nil || expectedSubject == subject else {
            throw HostedCourseAgentRuntimeError.unavailable("The Hosted credential doesn't match this conversation's original account.")
        }
        return .init(ownerSubject: subject, secret: secret)
    }

    private func promote(_ identity: HostedGuestIdentityCredential, serviceKey: String) throws {
        try storage.insert(
            Data(identity.secret.utf8), service: Self.identityService,
            account: "\(serviceKey)|\(identity.ownerSubject)", synchronizable: true
        )
        try storage.insert(
            Data(identity.ownerSubject.utf8), service: Self.preferenceService,
            account: serviceKey, synchronizable: true
        )
    }
}

enum HostedGuestIdentity {
    static func identity(serviceURL: String, ownerSubject: String? = nil) throws -> HostedGuestIdentityCredential {
        try HostedGuestIdentityRepository(storage: HostedGuestKeychainStorage()).identity(
            serviceURL: serviceURL, ownerSubject: ownerSubject
        )
    }

    static func loadOrCreate(serviceURL: String) throws -> String {
        try identity(serviceURL: serviceURL).secret
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func deviceOriginID(defaults: UserDefaults = .standard) -> String {
        let key = "learnfold.hosted.deviceOriginID"
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw HostedGuestKeychainStorage.error(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct HostedGuestKeychainStorage: HostedGuestIdentityStorage {
    func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        var item: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Self.error(status == errSecSuccess ? errSecDecode : status)
        }
        return data
    }

    func insert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw Self.error(status) }
        // Never overwrite a credential selected by a portable owner locator.
        if status == errSecDuplicateItem {
            guard try read(service: service, account: account, synchronizable: synchronizable) == data
                    || service == HostedGuestIdentityRepository.preferenceService else {
                throw HostedCourseAgentRuntimeError.unavailable("Your Hosted identity could not be safely restored. Unlock your device and retry.")
            }
        }
    }

    static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "Couldn't access your Hosted identity. Unlock your device and check that iCloud Keychain is enabled, then retry.",
        ])
    }
}

enum HostedCourseAgentRuntimeError: LocalizedError {
    case unavailable(String)
    case invalidTool(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidTool(let message), .toolFailed(let message):
            message
        }
    }
}

final class HostedCourseEventListener: HostedAgentEventListener, @unchecked Sendable {
    private let lock = NSLock()
    private var response = ""
    private var pendingDelivery: Task<Void, Never>?
    private let onPartialResponse: @MainActor (String) -> Void

    private let onRecoveringChanged: @MainActor (Bool) -> Void

    init(
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.onPartialResponse = onPartialResponse
        self.onRecoveringChanged = onRecoveringChanged
    }

    func onResponseDelta(delta: String) {
        lock.lock()
        response += delta
        let partial = response
        let previous = pendingDelivery
        pendingDelivery = Task { @MainActor [onPartialResponse] in
            await previous?.value
            onPartialResponse(partial)
        }
        lock.unlock()
    }

    func finishDelivery() async {
        await latestDelivery()?.value
    }

    private func latestDelivery() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return pendingDelivery
    }

    func onRecoveringChanged(recovering: Bool) {
        lock.lock()
        let previous = pendingDelivery
        pendingDelivery = Task { @MainActor [onRecoveringChanged] in
            await previous?.value
            onRecoveringChanged(recovering)
        }
        lock.unlock()
    }
}

private final class HostedCourseToolHandler: HostedAgentToolHandler, @unchecked Sendable {
    private let workspaceID: String
    private let courseDirectory: URL
    private let onCoursePlan: @MainActor (CourseBrief) async throws -> Void

    init(
        workspaceID: String,
        courseDirectory: URL,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) {
        self.workspaceID = workspaceID
        self.courseDirectory = courseDirectory
        self.onCoursePlan = onCoursePlan
    }

    func executeHostedTool(invocation: HostedAgentToolInvocation) -> HostedAgentToolResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = HostedToolResultBox()
        Task.detached(priority: .userInitiated) { [self] in
            defer { semaphore.signal() }
            box.store(await execute(invocation))
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            return HostedAgentToolResult(
                success: false,
                output: "{}",
                errorMessage: "The native course tool timed out before returning a result."
            )
        }
        return box.load()
    }

    private func execute(_ invocation: HostedAgentToolInvocation) async -> HostedAgentToolResult {
        do {
            guard var arguments = try JSONSerialization.jsonObject(
                with: Data(invocation.argumentsJson.utf8)
            ) as? [String: Any],
            arguments.removeValue(forKey: CourseAgentTools.workspaceIDArgument) as? String == workspaceID else {
                throw HostedCourseAgentRuntimeError.invalidTool(
                    "The tool call did not target the active course workspace."
                )
            }

            if invocation.toolName == CourseAgentTools.presentPlan {
                let data = try JSONSerialization.data(withJSONObject: arguments)
                let plan = try JSONDecoder().decode(CourseBrief.self, from: data)
                if let issue = AppleCoursePlanValidator.issue(in: plan) {
                    throw HostedCourseAgentRuntimeError.invalidTool(issue)
                }
                try await onCoursePlan(plan)
                return success(arguments)
            }

            guard CourseAgentTools.isEditorTool(invocation.toolName) else {
                throw HostedCourseAgentRuntimeError.invalidTool(
                    "Unknown Learnfold course tool: \(invocation.toolName)"
                )
            }
            if CourseAgentTools.isMutatingEditorTool(invocation.toolName) {
                let approvedPlan = courseDirectory
                    .appendingPathComponent(".course", isDirectory: true)
                    .appendingPathComponent(AppleCourseApprovalPolicy.approvedPlanFilename)
                guard FileManager.default.fileExists(atPath: approvedPlan.path) else {
                    throw HostedCourseAgentRuntimeError.invalidTool(
                        "The course plan must be approved before native pages can be changed."
                    )
                }
            }

            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            guard let result = await CourseDocumentRegistry.shared.handle(
                workspaceID: workspaceID,
                tool: invocation.toolName,
                argumentsJSON: String(decoding: data, as: UTF8.self)
            ) else {
                throw HostedCourseAgentRuntimeError.toolFailed(
                    "The native course document is not open."
                )
            }
            let output = String(decoding: try JSONEncoder().encode(result.value), as: UTF8.self)
            return HostedAgentToolResult(
                success: !result.isError,
                output: output,
                errorMessage: result.isError ? "The native editor rejected the tool call." : nil
            )
        } catch {
            return HostedAgentToolResult(
                success: false,
                output: "{}",
                errorMessage: error.localizedDescription
            )
        }
    }

    private func success(_ object: [String: Any]) -> HostedAgentToolResult {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HostedAgentToolResult(
            success: true,
            output: data.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
            errorMessage: nil
        )
    }
}

private final class HostedToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result = HostedAgentToolResult(
        success: false,
        output: "{}",
        errorMessage: "The native tool did not return a result."
    )

    func store(_ value: HostedAgentToolResult) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> HostedAgentToolResult {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
