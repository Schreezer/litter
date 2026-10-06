import CloudKit
import CryptoKit
import Foundation
#if targetEnvironment(macCatalyst)
import Darwin
#endif

enum CourseCloudRecordType {
    static let workspaceGeneration = "LFWorkspaceGenerationV1"
    static let generationCommit = "LFGenerationCommitV1"
    static let catalogEntry = "LFCourseCatalogEntryV1"
}

struct CourseCloudRecordEnvelope: Codable, Equatable, Sendable {
    let recordType: String
    let fields: [String: String]
    let assetPayload: Data?
    let systemFields: Data?

    init(
        recordType: String,
        fields: [String: String],
        assetPayload: Data?,
        systemFields: Data? = nil
    ) {
        self.recordType = recordType
        self.fields = fields
        self.assetPayload = assetPayload
        self.systemFields = systemFields
    }
}

enum CourseCloudSyncAvailability: Equatable, Sendable {
    case available
    case missingEntitlement
    case noAccount
    case failed(String)
}

enum CourseCloudSyncFailurePolicy {
    static func isWorkspaceSpecific(_ error: Error) -> Bool {
        error is CourseCloudSyncModelError
            || error is CourseCloudSyncRepositoryError
            || error is DecodingError
            || error is EncodingError
            || (error as NSError).domain == NSCocoaErrorDomain
    }
}

enum CourseCloudSyncEngineError: LocalizedError {
    case notStarted
    case staleEngine
    case invalidEnvelope(String)
    case missingAsset(String)
    case checksumMismatch(String)
    case missingMergeBase(String)
    case accountQuarantined(String)
    case waitingForHeadContent(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "Course iCloud sync has not started."
        case .staleEngine:
            "The iCloud account changed while the course was being queued."
        case .invalidEnvelope(let recordName):
            "The queued CloudKit record \(recordName) is invalid."
        case .missingAsset(let recordName):
            "The CloudKit record \(recordName) is missing its course payload."
        case .checksumMismatch(let recordName):
            "The CloudKit payload checksum did not match for \(recordName)."
        case .missingMergeBase(let workspaceID):
            "Course \(workspaceID) exists locally but has no trusted cloud merge base."
        case .accountQuarantined(let workspaceID):
            "Course \(workspaceID) belongs to a different iCloud account and remains local-only until it is explicitly copied."
        case .waitingForHeadContent(let workspaceID):
            "Course \(workspaceID) is waiting for its accepted iCloud generation to arrive."
        }
    }
}

enum CourseCloudEntitlement {
    static let containerIdentifier = "iCloud.com.chirag.learnfold"

    /// CloudKit is not available to this course-sync transport in Simulator.
    /// Keep this compile-time capability separate from the entitlement flag so
    /// an ordinary simulator launch never constructs a `CKContainer`.
    static var isRuntimeCloudKitAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #elseif targetEnvironment(macCatalyst)
        // A local Catalyst build can advertise iCloud in Info.plist while its
        // ad-hoc signature has no CloudKit entitlement. CKContainer raises an
        // Objective-C exception in that case. Read the process signature first.
        signedProcessHasCloudKitEntitlement()
        #else
        true
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private static func signedProcessHasCloudKitEntitlement() -> Bool {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return false }
        defer { dlclose(security) }
        typealias CreateTask = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias CopyEntitlement = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?
        guard let createSymbol = dlsym(security, "SecTaskCreateFromSelf"),
              let copySymbol = dlsym(security, "SecTaskCopyValueForEntitlement") else { return false }
        let create = unsafeBitCast(createSymbol, to: CreateTask.self)
        let copy = unsafeBitCast(copySymbol, to: CopyEntitlement.self)
        guard let task = create(nil)?.takeRetainedValue(),
              let containers = copy(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)?.takeRetainedValue() as? [String],
              containers.contains(containerIdentifier),
              let services = copy(task, "com.apple.developer.icloud-services" as CFString, nil)?.takeRetainedValue() as? [String] else { return false }
        return services.contains("CloudKit")
    }
    #endif

    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "LearnfoldCourseCloudSyncEnabled") as? Bool == true
    }
}

/// Owns CKSyncEngine transport for the private CloudKit database.
///
/// Local course SQLite remains authoritative. This actor only moves immutable,
/// checksummed workspace generations through CloudKit and durably journals
/// fetched changes before the CKSyncEngine cursor is advanced.
actor CourseCloudSyncEngine: CKSyncEngineDelegate {
    static let shared = CourseCloudSyncEngine()

    private struct DeferredEngineContext: Equatable {
        let epoch: UInt64
        let accountID: String
    }

    private var container: CKContainer?
    private let stateStore: CourseCloudSyncStateStore?
    private let stagingDirectory: URL?
    private var engine: CKSyncEngine?
    private var accountID: String?
    private var bufferedFetchedEntries: [CourseCloudInboxEntry] = []
    private var bufferedCreatedAssetPaths: [String] = []
    private var fetchedBatchFailed = false
    private var workspacesBeingQueued: Set<String> = []
    private var workspacesNeedingAnotherQueue: Set<String> = []
    private var delegateEventDepth = 0
    private var engineEpoch: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var deferredRestart = false
    private var deferredFetchAfterRestart = false
    private var deferredFetch: DeferredEngineContext?
    private var deferredDrain: DeferredEngineContext?
    private var deferredSend: DeferredEngineContext?
    private var deferredEngineWorkerScheduled = false
    private(set) var availability: CourseCloudSyncAvailability = .missingEntitlement
    private(set) var workspaceErrors: [String: String] = [:]

    func workspaceError(workspaceID: String) -> String? {
        workspaceErrors[workspaceID]
    }

    func recordWorkspaceQueueFailure(_ error: Error, workspaceID: String) {
        if CourseCloudSyncFailurePolicy.isWorkspaceSpecific(error) {
            workspaceErrors[workspaceID] = error.localizedDescription
        } else {
            availability = .failed(error.localizedDescription)
        }
    }

    init(
        container: CKContainer? = nil,
        stateStore: CourseCloudSyncStateStore? = nil,
        stagingDirectory: URL? = nil
    ) {
        self.container = container
        if let stateStore, let stagingDirectory {
            self.stateStore = stateStore
            self.stagingDirectory = stagingDirectory
            return
        }

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let root = support.appendingPathComponent("Learnfold/CourseCloudSync", isDirectory: true)
        self.stagingDirectory = root.appendingPathComponent("Staging", isDirectory: true)
        self.stateStore = try? CourseCloudSyncStateStore(
            url: root.appendingPathComponent("course-cloud-sync.sqlite")
        )
    }

    func startIfAvailable() async {
        guard CourseCloudEntitlement.isRuntimeCloudKitAvailable,
              CourseCloudEntitlement.isEnabled else {
            availability = .missingEntitlement
            return
        }
        guard let stateStore, let stagingDirectory else {
            availability = .failed("Could not open the course sync state database.")
            return
        }
        if engine != nil, accountID != nil, availability == .available {
            return
        }

        lifecycleGeneration &+= 1
        let startupGeneration = lifecycleGeneration

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let resolvedContainer = container
                ?? CKContainer(identifier: CourseCloudEntitlement.containerIdentifier)
            container = resolvedContainer
            let userRecordID = try await resolvedContainer.userRecordID()
            guard startupGeneration == lifecycleGeneration else { return }
            let resolvedAccountID = userRecordID.recordName
            try await stateStore.activateAccount(resolvedAccountID)
            guard startupGeneration == lifecycleGeneration else { return }
            let serializedData = try await stateStore.engineState(accountID: resolvedAccountID)
            guard startupGeneration == lifecycleGeneration else { return }
            let serializedState = try serializedData.map {
                try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }

            var configuration = CKSyncEngine.Configuration(
                database: resolvedContainer.privateCloudDatabase,
                stateSerialization: serializedState,
                delegate: self
            )
            configuration.automaticallySync = true
            configuration.subscriptionID = "learnfold-course-sync-v1"

            let syncEngine = CKSyncEngine(configuration)
            guard startupGeneration == lifecycleGeneration else { return }
            engineEpoch &+= 1
            accountID = resolvedAccountID
            engine = syncEngine
            availability = .available

            if serializedState == nil {
                syncEngine.state.add(
                    pendingDatabaseChanges: Self.zoneIDs.map {
                        .saveZone(CKRecordZone(zoneID: $0))
                    }
                )
            }
            try await restorePendingOutbox(into: syncEngine, accountID: resolvedAccountID)
            guard startupGeneration == lifecycleGeneration,
                  syncEngine === engine else { return }
            let repositories = await CourseDocumentRegistry.shared.openRepositories()
            guard startupGeneration == lifecycleGeneration,
                  syncEngine === engine else { return }
            for repository in repositories {
                await queueRepositoryChangesIfNeeded(repository: repository)
                guard startupGeneration == lifecycleGeneration,
                      syncEngine === engine else { return }
            }
        } catch let error as CKError where error.code == .notAuthenticated {
            if startupGeneration == lifecycleGeneration {
                availability = .noAccount
            }
        } catch {
            if startupGeneration == lifecycleGeneration {
                availability = .failed(error.localizedDescription)
            }
        }
    }

    func fetchChanges() async -> Bool {
        guard let engine else { return false }
        if delegateEventDepth > 0 {
            enqueueDeferredFetch()
            return true
        }
        let capturedEpoch = engineEpoch
        do {
            try await engine.fetchChanges()
            guard capturedEpoch == engineEpoch, engine === self.engine else { return false }
            return true
        } catch {
            if capturedEpoch == engineEpoch, engine === self.engine {
                availability = .failed(error.localizedDescription)
            }
            return false
        }
    }

    func applyPendingFetchedChanges() async {
        guard let context = currentDeferredContext() else { return }
        do {
            try await drainInbox(context: context)
            if isCurrent(context) {
                availability = .available
            }
        } catch CourseCloudSyncEngineError.staleEngine {
            return
        } catch {
            if isCurrent(context) {
                availability = .failed(error.localizedDescription)
            }
        }
    }

    func queueWorkspaceGeneration(
        repository: CourseDocumentRepository,
        title: String? = nil
    ) async throws {
        do {
            try await queueWorkspaceGenerationContent(repository: repository, title: title)
            workspaceErrors.removeValue(forKey: repository.workspaceID)
        } catch {
            if CourseCloudSyncFailurePolicy.isWorkspaceSpecific(error) {
                workspaceErrors[repository.workspaceID] = error.localizedDescription
            }
            throw error
        }
    }

    private func queueWorkspaceGenerationContent(
        repository: CourseDocumentRepository,
        title: String?
    ) async throws {
        guard repository.allowsCloudSync else { return }
        guard let engine, let accountID, let stateStore else {
            throw CourseCloudSyncEngineError.notStarted
        }
        let capturedEpoch = engineEpoch
        let capturedAccountID = accountID

        let mutationReceipts = try await repository.pendingSyncMutationReceipts(limit: 10_000)
        let draft = try await repository.exportSyncSnapshot(generationID: "checksum-probe")
        let workspaceID = draft.manifest.workspaceID
        if let provenance = try await stateStore.courseProvenance(workspaceID: workspaceID),
           let ownerAccountID = provenance.accountID,
           ownerAccountID != accountID {
            throw CourseCloudSyncEngineError.accountQuarantined(workspaceID)
        }
        let baseData = try await stateStore.cloudBase(
            accountID: accountID,
            workspaceID: workspaceID
        )
        let acceptedHead = try await stateStore.cloudHead(
            accountID: accountID,
            workspaceID: workspaceID
        )
        let decodedBase = try baseData.map {
            try Self.decoder.decode(CourseSyncWorkspaceSnapshot.self, from: $0)
        }
        if let acceptedHead, decodedBase?.checksum != acceptedHead.head.checksum {
            throw CourseCloudSyncEngineError.waitingForHeadContent(workspaceID)
        }
        if let acceptedHead {
            try await stateStore.observeWorkspaceVector(
                accountID: accountID,
                workspaceID: workspaceID,
                vector: acceptedHead.head.version
            )
        }
        let ancestorChecksum = decodedBase?.checksum
        let mutationVersion = try await stateStore.nextMutationVersion(
            accountID: accountID,
            workspaceID: workspaceID,
            ancestorChecksum: ancestorChecksum
        )
        let receiptSeed = mutationReceipts.map(\.id).sorted().joined(separator: "\u{0}")
        let causalSeed = try CourseSyncChecksum.value(for: mutationVersion.resultingVector)
        let generationID = String(
            Self.sha256(
                Data(
                    "\(workspaceID)\u{0}\(draft.checksum)\u{0}\(receiptSeed)\u{0}\(causalSeed)\u{0}\(CourseCloudSyncSchema.version)".utf8
                )
            ).prefix(32)
        )
        let snapshot = try await repository.exportSyncSnapshot(
            generationID: generationID,
            previousGenerationID: acceptedHead?.head.generationID,
            version: mutationVersion.resultingVector
        )
        let resolvedTitle = title
            ?? snapshot.items.first(where: { $0.id == snapshot.manifest.rootPageID })?.title
            ?? "Course"
        let payload = try Self.encoder.encode(snapshot)
        guard payload.count <= 50 * 1024 * 1024 else {
            throw CourseCloudSyncModelError.invalidContinuation("The complete course generation exceeds the 50 MB sync asset limit.")
        }
        let generationBaseName = CourseSyncRecordName.generation(
            workspaceID: workspaceID,
            generationID: generationID
        )
        let generationRecordName = "\(generationBaseName).workspace.\(snapshot.checksum)"
        let commitRecordName = "\(generationBaseName).commit"
        let catalogRecordName = CourseSyncRecordName.course(workspaceID: workspaceID)
        let commit = try CourseSyncGenerationCommit(
            workspaceID: workspaceID,
            generationID: generationID,
            previousGenerationID: snapshot.manifest.previousGenerationID,
            manifestShardNames: [],
            records: [
                .init(
                    recordName: generationRecordName,
                    kind: .workspaceManifest,
                    checksum: snapshot.checksum
                ),
            ],
            version: snapshot.manifest.version,
            createdAt: .now
        )

        let contentZone = CourseCloudSyncSchema.contentZoneName
        let catalogZone = CourseCloudSyncSchema.catalogZoneName
        let head = CourseCloudHead(
            workspaceID: workspaceID,
            generationID: generationID,
            generationRecordName: generationRecordName,
            commitRecordName: commitRecordName,
            checksum: snapshot.checksum,
            title: resolvedTitle,
            previousGenerationID: snapshot.manifest.previousGenerationID,
            version: snapshot.manifest.version
        )
        let entries = [
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: contentZone,
                recordName: generationRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.workspaceGeneration,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "checksum": snapshot.checksum,
                    ],
                    assetPayload: payload
                ),
                mutationVersion: mutationVersion
            ),
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: contentZone,
                recordName: commitRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.generationCommit,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "checksum": snapshot.checksum,
                    ],
                    assetPayload: try Self.encoder.encode(commit)
                ),
                mutationVersion: mutationVersion
            ),
            try Self.outboxEntry(
                accountID: accountID,
                workspaceID: workspaceID,
                zoneName: catalogZone,
                recordName: catalogRecordName,
                envelope: CourseCloudRecordEnvelope(
                    recordType: CourseCloudRecordType.catalogEntry,
                    fields: [
                        "workspaceID": workspaceID,
                        "generationID": generationID,
                        "generationRecordName": generationRecordName,
                        "commitRecordName": commitRecordName,
                        "checksum": snapshot.checksum,
                        "title": resolvedTitle,
                        "previousGenerationID": snapshot.manifest.previousGenerationID ?? "",
                        "versionJSON": Self.encoder.encode(snapshot.manifest.version).base64EncodedString(),
                    ],
                    assetPayload: nil,
                    systemFields: acceptedHead?.systemFields
                ),
                mutationVersion: mutationVersion,
                candidateID: head.generationID
            ),
        ]

        try await stateStore.supersedePendingHead(
            accountID: accountID,
            workspaceID: workspaceID,
            recordName: catalogRecordName
        )
        for entry in entries {
            try await stateStore.enqueue(entry)
        }
        try await repository.acknowledgeSyncMutationReceipts(ids: mutationReceipts.map(\.id))
        guard capturedEpoch == engineEpoch,
              capturedAccountID == self.accountID,
              engine === self.engine else {
            throw CourseCloudSyncEngineError.staleEngine
        }
        engine.state.add(
            pendingRecordZoneChanges: entries.map {
                .saveRecord(Self.recordID(zoneName: $0.zoneName, recordName: $0.recordName))
            }
        )
        enqueueDeferredSend()
        try await stateStore.recordMigrationReceipt(
            accountID: accountID,
            workspaceID: workspaceID,
            contentChecksum: snapshot.checksum
        )
        try await stateStore.setCourseProvenance(
            workspaceID: workspaceID,
            provenance: .cloudAccount,
            accountID: accountID
        )
    }

    func queueRepositoryChangesIfNeeded(
        repository: CourseDocumentRepository
    ) async {
        guard repository.allowsCloudSync, availability == .available else { return }
        let workspaceID = repository.workspaceID
        guard !workspacesBeingQueued.contains(workspaceID) else {
            workspacesNeedingAnotherQueue.insert(workspaceID)
            return
        }
        workspacesBeingQueued.insert(workspaceID)
        defer {
            workspacesBeingQueued.remove(workspaceID)
            if workspacesNeedingAnotherQueue.remove(workspaceID) != nil {
                Task { await self.queueRepositoryChangesIfNeeded(repository: repository) }
            }
        }
        do {
            guard let accountID, let stateStore else { return }
            let draft = try await repository.exportSyncSnapshot(generationID: "metadata-change-probe")
            let pending = try await stateStore.pendingOutbox(
                accountID: accountID,
                recordName: CourseSyncRecordName.course(workspaceID: workspaceID)
            )
            let pendingChecksum = try pending.flatMap { entry -> String? in
                guard let payload = entry.payload else { return nil }
                return try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
                    .fields["checksum"]
            }
            if pendingChecksum == draft.checksum {
                workspaceErrors.removeValue(forKey: workspaceID)
                return
            }
            let accepted = try await stateStore.cloudHead(accountID: accountID, workspaceID: workspaceID)
            if pending == nil, accepted?.head.checksum == draft.checksum {
                let receipts = try await repository.pendingSyncMutationReceipts(limit: 10_000)
                try await repository.acknowledgeSyncMutationReceipts(ids: receipts.map(\.id))
                workspaceErrors.removeValue(forKey: workspaceID)
                return
            }
            try await queueWorkspaceGeneration(repository: repository)
        } catch CourseCloudSyncEngineError.staleEngine,
                CourseCloudSyncEngineError.accountQuarantined,
                CourseCloudSyncEngineError.waitingForHeadContent {
            // A workspace owned by another iCloud account remains local and
            // must not disable sync for unrelated courses.
        } catch {
            recordWorkspaceQueueFailure(error, workspaceID: workspaceID)
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let stateStore else { return }
        guard syncEngine === engine else { return }
        guard let callbackContext = currentDeferredContext() else { return }
        delegateEventDepth += 1
        defer {
            delegateEventDepth -= 1
            scheduleDeferredEngineWorkerIfNeeded()
        }
        do {
            switch event {
            case .stateUpdate(let update):
                guard let accountID else { return }
                if fetchedBatchFailed {
                    fetchedBatchFailed = false
                    bufferedFetchedEntries.removeAll(keepingCapacity: true)
                    for path in bufferedCreatedAssetPaths {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                    bufferedCreatedAssetPaths.removeAll(keepingCapacity: true)
                    invalidateEngine()
                    enqueueDeferredRestart(fetchAfterStart: true)
                    return
                }
                let stateData = try Self.encoder.encode(update.stateSerialization)
                try await stateStore.commitFetchedBatch(
                    accountID: accountID,
                    stateSerialization: stateData,
                    entries: bufferedFetchedEntries
                )
                try ensureCurrent(callbackContext, engine: syncEngine)
                bufferedFetchedEntries.removeAll(keepingCapacity: true)
                bufferedCreatedAssetPaths.removeAll(keepingCapacity: true)
                enqueueDeferredDrain()

            case .accountChange(let change):
                try await handleAccountChange(change, syncEngine: syncEngine)

            case .fetchedRecordZoneChanges(let changes):
                guard let accountID else { return }
                guard !fetchedBatchFailed else { return }
                var eventEntries: [CourseCloudInboxEntry] = []
                var eventCreatedAssetPaths: [String] = []
                do {
                    for modification in changes.modifications {
                        let staged = try stageFetchedRecord(
                            modification.record,
                            accountID: accountID
                        )
                        eventEntries.append(staged.entry)
                        if let path = staged.createdAssetPath {
                            eventCreatedAssetPaths.append(path)
                        }
                    }
                    for deletion in changes.deletions {
                        eventEntries.append(
                            CourseCloudInboxEntry(
                                id: Self.changeID(
                                    recordID: deletion.recordID,
                                    version: "delete-\(deletion.recordType)"
                                ),
                                accountID: accountID,
                                zoneName: deletion.recordID.zoneID.zoneName,
                                recordName: deletion.recordID.recordName,
                                changeKind: .delete,
                                payload: nil,
                                durableAssetPath: nil,
                                checksum: nil,
                                receivedAt: .now
                            )
                        )
                    }
                    bufferedFetchedEntries.append(contentsOf: eventEntries)
                    bufferedCreatedAssetPaths.append(contentsOf: eventCreatedAssetPaths)
                } catch {
                    for path in bufferedCreatedAssetPaths + eventCreatedAssetPaths {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                    bufferedFetchedEntries.removeAll(keepingCapacity: true)
                    bufferedCreatedAssetPaths.removeAll(keepingCapacity: true)
                    fetchedBatchFailed = true
                    throw error
                }

            case .fetchedDatabaseChanges(let changes):
                guard let accountID else { return }
                guard !fetchedBatchFailed else { return }
                for deletion in changes.deletions where Self.zoneIDs.contains(deletion.zoneID) {
                    let kind: CourseCloudChangeKind
                    switch deletion.reason {
                    case .deleted: kind = .zoneDelete
                    case .purged: kind = .zonePurge
                    case .encryptedDataReset: kind = .encryptedDataReset
                    @unknown default: kind = .zonePurge
                    }
                    bufferedFetchedEntries.append(
                        CourseCloudInboxEntry(
                            id: Self.sha256(
                                Data(
                                    "\(accountID)\u{0}\(deletion.zoneID.zoneName)\u{0}\(kind.rawValue)".utf8
                                )
                            ),
                            accountID: accountID,
                            zoneName: deletion.zoneID.zoneName,
                            recordName: "__zone__",
                            changeKind: kind,
                            payload: nil,
                            durableAssetPath: nil,
                            checksum: nil,
                            receivedAt: .now
                        )
                    )
                }

            case .sentRecordZoneChanges(let changes):
                guard let accountID else { return }
                try await acceptSavedRecords(changes.savedRecords, accountID: accountID)
                try ensureCurrent(callbackContext, engine: syncEngine)
                try await resolveFailedRecordSaves(
                    changes.failedRecordSaves,
                    accountID: accountID,
                    syncEngine: syncEngine
                )
                try ensureCurrent(callbackContext, engine: syncEngine)
                syncEngine.state.remove(
                    pendingRecordZoneChanges: changes.deletedRecordIDs.map {
                        .deleteRecord($0)
                    }
                )

            default:
                break
            }
        } catch CourseCloudSyncEngineError.staleEngine {
            return
        } catch {
            if isCurrent(callbackContext, engine: syncEngine) {
                availability = .failed(error.localizedDescription)
            }
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        guard let accountID, let stateStore else { return nil }
        do {
            let outbox = try await stateStore.pendingOutbox(accountID: accountID, limit: 500)
            // Two outbox rows can name the same record. Prefer the newest
            // instead of trapping inside a CKSyncEngine delegate callback.
            let byID = Dictionary(
                outbox.map {
                    (Self.recordID(zoneName: $0.zoneName, recordName: $0.recordName), $0)
                },
                uniquingKeysWith: { _, newest in newest }
            )
            let pending = syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
            return await CKSyncEngine.RecordZoneChangeBatch(
                pendingChanges: pending
            ) { recordID in
                guard let entry = byID[recordID] else { return nil }
                return try? await self.makeRecord(from: entry)
            }
        } catch {
            availability = .failed(error.localizedDescription)
            return nil
        }
    }

    private func restorePendingOutbox(
        into engine: CKSyncEngine,
        accountID: String
    ) async throws {
        guard let stateStore else { return }
        let outbox = try await stateStore.pendingOutbox(accountID: accountID, limit: 10_000)
        let alreadyPending = Set(engine.state.pendingRecordZoneChanges)
        let missing = outbox.compactMap { entry -> CKSyncEngine.PendingRecordZoneChange? in
            let change: CKSyncEngine.PendingRecordZoneChange
            let recordID = Self.recordID(zoneName: entry.zoneName, recordName: entry.recordName)
            switch entry.changeKind {
            case .save: change = .saveRecord(recordID)
            case .delete: change = .deleteRecord(recordID)
            default: return nil
            }
            return alreadyPending.contains(change) ? nil : change
        }
        engine.state.add(pendingRecordZoneChanges: missing)
    }

    private func makeRecord(from entry: CourseCloudOutboxEntry) async throws -> CKRecord? {
        guard entry.changeKind == .save, let payload = entry.payload else { return nil }
        let envelope = try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
        let recordID = Self.recordID(zoneName: entry.zoneName, recordName: entry.recordName)
        let record: CKRecord
        if let systemFields = envelope.systemFields {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            unarchiver.requiresSecureCoding = true
            guard let restored = CKRecord(coder: unarchiver) else {
                throw CourseCloudSyncEngineError.invalidEnvelope(entry.recordName)
            }
            unarchiver.finishDecoding()
            guard restored.recordID == recordID, restored.recordType == envelope.recordType else {
                throw CourseCloudSyncEngineError.invalidEnvelope(entry.recordName)
            }
            record = restored
        } else {
            record = CKRecord(recordType: envelope.recordType, recordID: recordID)
        }
        for (key, value) in envelope.fields {
            record[key] = value as CKRecordValue
        }
        record["schemaVersion"] = CourseCloudSyncSchema.version as CKRecordValue
        if let assetPayload = envelope.assetPayload {
            guard let stagingDirectory else { throw CourseCloudSyncEngineError.missingAsset(entry.recordName) }
            let outgoing = stagingDirectory
                .appendingPathComponent("Outgoing", isDirectory: true)
                .appendingPathComponent(entry.accountID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: outgoing,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let assetURL = outgoing.appendingPathComponent("\(entry.id).payload")
            if !FileManager.default.fileExists(atPath: assetURL.path) {
                try assetPayload.write(to: assetURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            record["payload"] = CKAsset(fileURL: assetURL)
            record["payloadChecksum"] = Self.sha256(assetPayload) as CKRecordValue
        }
        return record
    }

    private func stageFetchedRecord(
        _ record: CKRecord,
        accountID: String
    ) throws -> (entry: CourseCloudInboxEntry, createdAssetPath: String?) {
        let checksum = record["payloadChecksum"] as? String
        var durableAssetPath: String?
        var createdAssetPath: String?
        if let asset = record["payload"] as? CKAsset {
            guard let sourceURL = asset.fileURL, let stagingDirectory else {
                throw CourseCloudSyncEngineError.missingAsset(record.recordID.recordName)
            }
            let incoming = stagingDirectory
                .appendingPathComponent("Incoming", isDirectory: true)
                .appendingPathComponent(accountID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: incoming,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let destination = incoming.appendingPathComponent(
                "\(Self.changeID(recordID: record.recordID, version: record.recordChangeTag ?? "new")).payload"
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                createdAssetPath = destination.path
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
            }
            if let checksum {
                let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                guard Self.sha256(data) == checksum else {
                    try? FileManager.default.removeItem(at: destination)
                    throw CourseCloudSyncEngineError.checksumMismatch(record.recordID.recordName)
                }
            }
            durableAssetPath = destination.path
        }

        let metadata = CourseCloudFetchedRecordMetadata(
            recordType: record.recordType,
            fields: record.allKeys().reduce(into: [:]) { result, key in
                if let string = record[key] as? String { result[key] = string }
            },
            systemFields: try Self.archivedSystemFields(for: record)
        )
        return (
            CourseCloudInboxEntry(
                id: Self.changeID(
                    recordID: record.recordID,
                    version: record.recordChangeTag ?? checksum ?? "new"
                ),
                accountID: accountID,
                zoneName: record.recordID.zoneID.zoneName,
                recordName: record.recordID.recordName,
                changeKind: .save,
                payload: try Self.encoder.encode(metadata),
                durableAssetPath: durableAssetPath,
                checksum: checksum,
                receivedAt: .now
            ),
            createdAssetPath
        )
    }

    private func handleAccountChange(
        _ event: CKSyncEngine.Event.AccountChange,
        syncEngine _: CKSyncEngine
    ) async throws {
        guard let stateStore else { return }
        let previous = accountID
        let current: String?
        switch event.changeType {
        case .signIn(let currentUser):
            current = currentUser.recordName
        case .signOut:
            current = nil
        case .switchAccounts(_, let currentUser):
            current = currentUser.recordName
        @unknown default:
            current = nil
        }
        if previous == current {
            availability = current == nil ? .noAccount : .available
            return
        }
        if let previous, previous != current {
            try await stateStore.sealAccount(
                previous,
                change: CourseCloudAccountChange(
                    previousAccountID: previous,
                    currentAccountID: current,
                    occurredAt: .now
                )
            )
        }
        bufferedFetchedEntries.removeAll()
        for path in bufferedCreatedAssetPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        bufferedCreatedAssetPaths.removeAll()
        fetchedBatchFailed = false
        if current != nil {
            invalidateEngine()
            enqueueDeferredRestart(fetchAfterStart: false)
        } else {
            invalidateEngine()
            availability = .noAccount
        }
    }

    private func resolveFailedRecordSaves(
        _ failures: [CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave],
        accountID: String,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let stateStore else { return }
        for failure in failures {
            guard failure.error.code == .serverRecordChanged,
                  let server = failure.error.serverRecord,
                  let localChecksum = failure.record["checksum"] as? String else {
                continue
            }
            let recordID = failure.record.recordID
            if failure.record.recordType == CourseCloudRecordType.catalogEntry {
                try await resolveHeadConflict(
                    local: failure.record,
                    server: server,
                    accountID: accountID,
                    syncEngine: syncEngine
                )
                continue
            }
            guard server["checksum"] as? String == localChecksum else { continue }
            try await stateStore.markOutboxSent(
                accountID: accountID,
                recordIDs: [recordID.recordName]
            )
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        }
    }

    private func acceptSavedRecords(
        _ records: [CKRecord],
        accountID: String
    ) async throws {
        guard let stateStore else { return }
        for record in records.sorted(by: {
            ($0.recordType == CourseCloudRecordType.catalogEntry ? 1 : 0)
                < ($1.recordType == CourseCloudRecordType.catalogEntry ? 1 : 0)
        }) {
            guard record.recordType == CourseCloudRecordType.catalogEntry else {
                if let entry = try await stateStore.pendingOutbox(
                    accountID: accountID,
                    recordName: record.recordID.recordName
                ) {
                    try await stateStore.markOutboxSent(accountID: accountID, entryIDs: [entry.id])
                }
                continue
            }
            let head = try Self.decodeHead(record)
            guard let pending = try await pendingHeadEntry(
                matching: head,
                accountID: accountID
            ) else {
                // A success callback for a superseded head must never
                // acknowledge the newer candidate sharing this record ID.
                continue
            }
            let snapshotData = try await localSnapshotData(
                for: head,
                accountID: accountID
            )
            try await stateStore.acceptSavedHead(
                accountID: accountID,
                entryID: pending.id,
                head: head,
                systemFields: Self.archivedSystemFields(for: record),
                snapshot: snapshotData
            )
        }
    }

    private func resolveHeadConflict(
        local: CKRecord,
        server: CKRecord,
        accountID: String,
        syncEngine: CKSyncEngine
    ) async throws {
        guard let stateStore else { return }
        let localHead = try Self.decodeHead(local)
        let serverHead = try Self.decodeHead(server)
        guard localHead.workspaceID == serverHead.workspaceID,
              local.recordID == server.recordID else {
            throw CourseCloudSyncEngineError.invalidEnvelope(local.recordID.recordName)
        }
        let pending = try await stateStore.pendingOutbox(
            accountID: accountID,
            recordName: local.recordID.recordName
        )

        if localHead.generationID == serverHead.generationID,
           localHead.checksum == serverHead.checksum {
            guard let pending = try await pendingHeadEntry(
                matching: localHead,
                accountID: accountID
            ) else { return }
            try await stateStore.acceptSavedHead(
                accountID: accountID,
                entryID: pending.id,
                head: serverHead,
                systemFields: Self.archivedSystemFields(for: server),
                snapshot: try await localSnapshotData(for: localHead, accountID: accountID)
            )
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
            return
        }

        switch localHead.version.relation(to: serverHead.version) {
        case .after:
            guard let pending, let payload = pending.payload else { return }
            var envelope = try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
            envelope = CourseCloudRecordEnvelope(
                recordType: envelope.recordType,
                fields: envelope.fields,
                assetPayload: envelope.assetPayload,
                systemFields: try Self.archivedSystemFields(for: server)
            )
            try await stateStore.replaceOutboxPayload(
                entryID: pending.id,
                payload: Self.encoder.encode(envelope)
            )
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])

        case .before, .concurrent:
            if let pending {
                try await stateStore.markOutboxSent(accountID: accountID, entryIDs: [pending.id])
            }
            try await stateStore.setCloudHead(
                accountID: accountID,
                head: serverHead,
                systemFields: Self.archivedSystemFields(for: server)
            )
            try await stateStore.observeWorkspaceVector(
                accountID: accountID,
                workspaceID: serverHead.workspaceID,
                vector: serverHead.version
            )
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
            enqueueDeferredFetch()

        case .equal:
            throw CourseCloudSyncEngineError.invalidEnvelope(local.recordID.recordName)
        }
    }

    private func invalidateEngine() {
        lifecycleGeneration &+= 1
        engineEpoch &+= 1
        engine = nil
        accountID = nil
        deferredFetch = nil
        deferredDrain = nil
        deferredSend = nil
    }

    private func currentDeferredContext() -> DeferredEngineContext? {
        guard engine != nil, let accountID else { return nil }
        return DeferredEngineContext(epoch: engineEpoch, accountID: accountID)
    }

    private func isCurrent(_ context: DeferredEngineContext, engine: CKSyncEngine) -> Bool {
        context.epoch == engineEpoch
            && context.accountID == accountID
            && engine === self.engine
    }

    private func isCurrent(_ context: DeferredEngineContext) -> Bool {
        context.epoch == engineEpoch && context.accountID == accountID
    }

    private func ensureCurrent(
        _ context: DeferredEngineContext,
        engine: CKSyncEngine? = nil
    ) throws {
        let valid = if let engine {
            isCurrent(context, engine: engine)
        } else {
            isCurrent(context)
        }
        guard valid else { throw CourseCloudSyncEngineError.staleEngine }
    }

    private func enqueueDeferredRestart(fetchAfterStart: Bool) {
        deferredRestart = true
        deferredFetchAfterRestart = deferredFetchAfterRestart || fetchAfterStart
        scheduleDeferredEngineWorkerIfNeeded()
    }

    private func enqueueDeferredFetch() {
        guard let context = currentDeferredContext() else { return }
        deferredFetch = context
        scheduleDeferredEngineWorkerIfNeeded()
    }

    private func enqueueDeferredDrain() {
        guard let context = currentDeferredContext() else { return }
        deferredDrain = context
        scheduleDeferredEngineWorkerIfNeeded()
    }

    private func enqueueDeferredSend() {
        guard let context = currentDeferredContext() else { return }
        deferredSend = context
        scheduleDeferredEngineWorkerIfNeeded()
    }

    private var hasDeferredEngineWork: Bool {
        deferredRestart || deferredFetch != nil || deferredDrain != nil || deferredSend != nil
    }

    private func scheduleDeferredEngineWorkerIfNeeded() {
        guard delegateEventDepth == 0,
              hasDeferredEngineWork,
              !deferredEngineWorkerScheduled else {
            return
        }
        deferredEngineWorkerScheduled = true
        Task.detached(priority: .utility) { [weak self] in
            await self?.runDeferredEngineOperations()
        }
    }

    private func runDeferredEngineOperations() async {
        while true {
            guard delegateEventDepth == 0 else { break }
            if deferredRestart {
                let fetchAfterStart = deferredFetchAfterRestart
                deferredRestart = false
                deferredFetchAfterRestart = false
                await startIfAvailable()
                if fetchAfterStart {
                    enqueueDeferredFetch()
                }
                continue
            }

            guard delegateEventDepth == 0 else { break }
            if let context = deferredFetch {
                deferredFetch = nil
                if let engine, isCurrent(context, engine: engine) {
                    do {
                        try await engine.fetchChanges()
                    } catch {
                        if isCurrent(context, engine: engine) {
                            availability = .failed(error.localizedDescription)
                        }
                    }
                }
                continue
            }

            guard delegateEventDepth == 0 else { break }
            if let context = deferredDrain {
                deferredDrain = nil
                if isCurrent(context) {
                    do {
                        try await drainInbox(context: context)
                    } catch CourseCloudSyncEngineError.staleEngine {
                        // The replacement engine/account owns any later drain.
                    } catch {
                        if isCurrent(context) {
                            availability = .failed(error.localizedDescription)
                        }
                    }
                }
                continue
            }

            guard delegateEventDepth == 0 else { break }
            if let context = deferredSend {
                deferredSend = nil
                if let engine, isCurrent(context, engine: engine) {
                    do {
                        try await engine.sendChanges()
                    } catch {
                        if isCurrent(context, engine: engine) {
                            availability = .failed(error.localizedDescription)
                        }
                    }
                }
                continue
            }

            break
        }

        deferredEngineWorkerScheduled = false
        scheduleDeferredEngineWorkerIfNeeded()
    }

    private func drainInbox(context: DeferredEngineContext) async throws {
        guard let stateStore else { return }
        try ensureCurrent(context)
        let accountID = context.accountID
        let pending = try await stateStore.pendingInbox(accountID: accountID, limit: 10_000)
        try ensureCurrent(context)
        guard !pending.isEmpty else { return }

        let zoneEvents = pending.filter {
            $0.changeKind == .zoneDelete
                || $0.changeKind == .zonePurge
                || $0.changeKind == .encryptedDataReset
        }
        if !zoneEvents.isEmpty, let engine {
            try ensureCurrent(context, engine: engine)
            let zones = Set(zoneEvents.map(\.zoneName))
            engine.state.add(
                pendingDatabaseChanges: Self.zoneIDs
                    .filter { zones.contains($0.zoneName) }
                    .map { .saveZone(CKRecordZone(zoneID: $0)) }
            )
            try await stateStore.markInboxApplied(
                accountID: accountID,
                entryIDs: zoneEvents.map(\.id)
            )
            try ensureCurrent(context, engine: engine)
            for repository in await CourseDocumentRegistry.shared.openRepositories() {
                try ensureCurrent(context, engine: engine)
                try await queueWorkspaceGeneration(repository: repository)
                try ensureCurrent(context, engine: engine)
            }
        }
        let recordDeletionIDs = pending
            .filter { $0.changeKind == .delete }
            .map(\.id)
        if !recordDeletionIDs.isEmpty {
            // Immutable generation records are historical transport objects.
            // Their deletion never authorizes deleting the authoritative local
            // course; a later local mutation or zone recovery can re-upload.
            try await stateStore.markInboxApplied(
                accountID: accountID,
                entryIDs: recordDeletionIDs
            )
            try ensureCurrent(context)
        }

        struct DecodedEntry {
            let entry: CourseCloudInboxEntry
            let metadata: CourseCloudFetchedRecordMetadata
        }
        let decoded: [DecodedEntry] = pending.compactMap { entry in
            guard entry.changeKind == .save,
                  let payload = entry.payload,
                  let metadata = try? Self.decoder.decode(
                    CourseCloudFetchedRecordMetadata.self,
                    from: payload
                  ) else {
                return nil
            }
            return DecodedEntry(entry: entry, metadata: metadata)
        }
        let commits = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.generationCommit
        }
        let generations = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.workspaceGeneration
        }
        let catalogs = decoded.filter {
            $0.metadata.recordType == CourseCloudRecordType.catalogEntry
        }

        let stableCatalogs = catalogs.filter {
            guard let workspaceID = $0.metadata.fields["workspaceID"] else { return false }
            return $0.entry.recordName == CourseSyncRecordName.course(workspaceID: workspaceID)
        }
        let legacyCatalogIDs = catalogs
            .filter { catalog in !stableCatalogs.contains(where: { $0.entry.id == catalog.entry.id }) }
            .map(\.entry.id)
        try await stateStore.markInboxApplied(accountID: accountID, entryIDs: legacyCatalogIDs)
        try ensureCurrent(context)

        var workspaceIDs = Set(generations.compactMap { $0.metadata.fields["workspaceID"] })
        workspaceIDs.formUnion(stableCatalogs.compactMap { $0.metadata.fields["workspaceID"] })

        for workspaceID in workspaceIDs.sorted() {
            let workspaceCatalogs = stableCatalogs
                .filter { $0.metadata.fields["workspaceID"] == workspaceID }
                .sorted { $0.entry.receivedAt < $1.entry.receivedAt }
            var ignoredCatalogIDs: [String] = []
            for catalog in workspaceCatalogs {
                guard let fetchedHead = try? Self.decodeHead(
                    metadata: catalog.metadata,
                    recordName: catalog.entry.recordName
                ),
                      let systemFields = catalog.metadata.systemFields else {
                    ignoredCatalogIDs.append(catalog.entry.id)
                    continue
                }
                if let accepted = try await stateStore.cloudHead(
                    accountID: accountID,
                    workspaceID: workspaceID
                ) {
                    try ensureCurrent(context)
                    switch CourseCloudHeadResolver.resolve(
                        accepted: accepted.head,
                        incoming: fetchedHead
                    ) {
                    case .ignoreHistorical:
                        ignoredCatalogIDs.append(catalog.entry.id)
                        continue
                    case .invalidEqualVersion:
                        throw CourseCloudSyncEngineError.invalidEnvelope(catalog.entry.recordName)
                    case .accept, .mergeConcurrent:
                        break
                    }
                }
                try await stateStore.setCloudHead(
                    accountID: accountID,
                    head: fetchedHead,
                    systemFields: systemFields
                )
                try ensureCurrent(context)
                try await stateStore.observeWorkspaceVector(
                    accountID: accountID,
                    workspaceID: workspaceID,
                    vector: fetchedHead.version
                )
                try ensureCurrent(context)
            }
            try await stateStore.markInboxApplied(
                accountID: accountID,
                entryIDs: ignoredCatalogIDs
            )
            try ensureCurrent(context)

            guard let storedHead = try await stateStore.cloudHead(
                accountID: accountID,
                workspaceID: workspaceID
            ) else {
                continue
            }
            try ensureCurrent(context)
            let head = storedHead.head
            guard let generation = generations.first(where: {
                      $0.entry.recordName == head.generationRecordName
                  }),
                  let assetPath = generation.entry.durableAssetPath,
                  let commitEntry = commits.first(where: {
                      $0.entry.recordName == head.commitRecordName
                  }),
                  let commitPath = commitEntry.entry.durableAssetPath else {
                continue
            }
            let snapshotData = try Data(contentsOf: URL(fileURLWithPath: assetPath))
            let commitData = try Data(contentsOf: URL(fileURLWithPath: commitPath))
            let snapshot = try Self.decoder.decode(
                CourseSyncWorkspaceSnapshot.self,
                from: snapshotData
            )
            let commit = try Self.decoder.decode(CourseSyncGenerationCommit.self, from: commitData)
            _ = try snapshot.validatedWorkspace()
            guard snapshot.manifest.workspaceID == workspaceID,
                  snapshot.manifest.generationID == head.generationID,
                  snapshot.manifest.version == head.version,
                  snapshot.checksum == head.checksum,
                  commit.workspaceID == workspaceID,
                  commit.generationID == head.generationID,
                  commit.version == head.version,
                  commit.records.contains(where: {
                      $0.recordName == generation.entry.recordName
                          && $0.checksum == snapshot.checksum
                  }) else {
                throw CourseCloudSyncEngineError.invalidEnvelope(generation.entry.recordName)
            }

            let base = try await stateStore.cloudBase(
                accountID: accountID,
                workspaceID: workspaceID
            ).map {
                try Self.decoder.decode(CourseSyncWorkspaceSnapshot.self, from: $0)
            }
            try ensureCurrent(context)
            if let provenance = try await stateStore.courseProvenance(workspaceID: workspaceID),
               let ownerAccountID = provenance.accountID,
               ownerAccountID != accountID {
                continue
            }
            try ensureCurrent(context)
            let repository: CourseDocumentRepository?
            if base?.checksum == snapshot.checksum {
                repository = nil
            } else {
                repository = try await CourseCloudSyncApplyBridge.shared.apply(
                    snapshot: snapshot,
                    base: base,
                    title: head.title
                )
                try ensureCurrent(context)
            }
            try ensureCurrent(context)
            try await stateStore.setCloudBase(
                accountID: accountID,
                workspaceID: workspaceID,
                checksum: snapshot.checksum,
                snapshot: snapshotData
            )
            try ensureCurrent(context)
            try await stateStore.setCourseProvenance(
                workspaceID: workspaceID,
                provenance: .cloudAccount,
                accountID: accountID
            )
            try ensureCurrent(context)
            var appliedIDs = [generation.entry.id, commitEntry.entry.id]
            appliedIDs.append(
                contentsOf: workspaceCatalogs
                    .filter { $0.metadata.fields["generationID"] == head.generationID }
                    .map(\.entry.id)
            )
            try await stateStore.markInboxApplied(accountID: accountID, entryIDs: appliedIDs)
            try ensureCurrent(context)
            for path in [assetPath, commitPath] {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let repository {
                await queueRepositoryChangesIfNeeded(repository: repository)
                try ensureCurrent(context)
            }
        }
    }

    private static let zoneIDs = [
        CKRecordZone.ID(zoneName: CourseCloudSyncSchema.catalogZoneName, ownerName: CKCurrentUserDefaultName),
        CKRecordZone.ID(zoneName: CourseCloudSyncSchema.contentZoneName, ownerName: CKCurrentUserDefaultName),
    ]

    private func pendingHeadEntry(
        matching head: CourseCloudHead,
        accountID: String
    ) async throws -> CourseCloudOutboxEntry? {
        guard let stateStore,
              let entry = try await stateStore.pendingOutbox(
                  accountID: accountID,
                  recordName: CourseSyncRecordName.course(workspaceID: head.workspaceID)
              ),
              let payload = entry.payload else {
            return nil
        }
        let envelope = try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
        return envelope.fields["generationID"] == head.generationID ? entry : nil
    }

    private func localSnapshotData(
        for head: CourseCloudHead,
        accountID: String
    ) async throws -> Data {
        guard let stateStore,
              let generationEntry = try await stateStore.outboxEntry(
                  accountID: accountID,
                  recordName: head.generationRecordName
              ),
              let payload = generationEntry.payload else {
            throw CourseCloudSyncEngineError.missingAsset(head.generationRecordName)
        }
        let envelope = try Self.decoder.decode(CourseCloudRecordEnvelope.self, from: payload)
        guard let snapshotData = envelope.assetPayload else {
            throw CourseCloudSyncEngineError.missingAsset(head.generationRecordName)
        }
        let snapshot = try Self.decoder.decode(CourseSyncWorkspaceSnapshot.self, from: snapshotData)
        guard snapshot.manifest.workspaceID == head.workspaceID,
              snapshot.manifest.generationID == head.generationID,
              snapshot.checksum == head.checksum,
              snapshot.manifest.version == head.version else {
            throw CourseCloudSyncEngineError.invalidEnvelope(head.generationRecordName)
        }
        return snapshotData
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static func outboxEntry(
        accountID: String,
        workspaceID: String,
        zoneName: String,
        recordName: String,
        envelope: CourseCloudRecordEnvelope,
        mutationVersion: CourseSyncMutationVersion?,
        candidateID: String? = nil
    ) throws -> CourseCloudOutboxEntry {
        CourseCloudOutboxEntry(
            id: sha256(
                Data(
                    "\(accountID)\u{0}\(zoneName)\u{0}\(recordName)\u{0}\(candidateID ?? "")".utf8
                )
            ),
            accountID: accountID,
            workspaceID: workspaceID,
            zoneName: zoneName,
            recordName: recordName,
            changeKind: .save,
            payload: try encoder.encode(envelope),
            mutationVersion: mutationVersion,
            createdAt: .now
        )
    }

    private static func recordID(zoneName: String, recordName: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: recordName,
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        )
    }

    private static func changeID(recordID: CKRecord.ID, version: String) -> String {
        sha256(
            Data(
                "\(recordID.zoneID.zoneName)\u{0}\(recordID.recordName)\u{0}\(version)".utf8
            )
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func archivedSystemFields(for record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeHead(_ record: CKRecord) throws -> CourseCloudHead {
        guard record.recordType == CourseCloudRecordType.catalogEntry,
              let workspaceID = record["workspaceID"] as? String,
              record.recordID.recordName == CourseSyncRecordName.course(workspaceID: workspaceID),
              let generationID = record["generationID"] as? String,
              let generationRecordName = record["generationRecordName"] as? String,
              let commitRecordName = record["commitRecordName"] as? String,
              let checksum = record["checksum"] as? String,
              let title = record["title"] as? String,
              let encodedVersion = record["versionJSON"] as? String,
              let versionData = Data(base64Encoded: encodedVersion) else {
            throw CourseCloudSyncEngineError.invalidEnvelope(record.recordID.recordName)
        }
        return CourseCloudHead(
            workspaceID: workspaceID,
            generationID: generationID,
            generationRecordName: generationRecordName,
            commitRecordName: commitRecordName,
            checksum: checksum,
            title: title,
            previousGenerationID: (record["previousGenerationID"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            },
            version: try decoder.decode(CourseSyncVersionVector.self, from: versionData)
        )
    }

    private static func decodeHead(
        metadata: CourseCloudFetchedRecordMetadata,
        recordName: String
    ) throws -> CourseCloudHead {
        let fields = metadata.fields
        guard metadata.recordType == CourseCloudRecordType.catalogEntry,
              let workspaceID = fields["workspaceID"],
              recordName == CourseSyncRecordName.course(workspaceID: workspaceID),
              let generationID = fields["generationID"],
              let generationRecordName = fields["generationRecordName"],
              let commitRecordName = fields["commitRecordName"],
              let checksum = fields["checksum"],
              let title = fields["title"],
              let encodedVersion = fields["versionJSON"],
              let versionData = Data(base64Encoded: encodedVersion) else {
            throw CourseCloudSyncEngineError.invalidEnvelope(recordName)
        }
        return CourseCloudHead(
            workspaceID: workspaceID,
            generationID: generationID,
            generationRecordName: generationRecordName,
            commitRecordName: commitRecordName,
            checksum: checksum,
            title: title,
            previousGenerationID: fields["previousGenerationID"].flatMap {
                $0.isEmpty ? nil : $0
            },
            version: try decoder.decode(CourseSyncVersionVector.self, from: versionData)
        )
    }
}

struct CourseCloudFetchedRecordMetadata: Codable, Equatable, Sendable {
    let recordType: String
    let fields: [String: String]
    let systemFields: Data?

    init(recordType: String, fields: [String: String], systemFields: Data? = nil) {
        self.recordType = recordType
        self.fields = fields
        self.systemFields = systemFields
    }
}

@MainActor
final class CourseCloudSyncApplyBridge {
    static let shared = CourseCloudSyncApplyBridge()

    private final class StoreReference {
        weak var store: CourseExperienceStore?
        init(_ store: CourseExperienceStore) { self.store = store }
    }

    private var stores: [StoreReference] = []

    func register(store: CourseExperienceStore) {
        stores.removeAll { $0.store == nil || $0.store === store }
        stores.append(StoreReference(store))
        Task {
            await CourseCloudSyncEngine.shared.applyPendingFetchedChanges()
        }
    }

    func apply(
        snapshot: CourseSyncWorkspaceSnapshot,
        base: CourseSyncWorkspaceSnapshot?,
        title: String
    ) async throws -> CourseDocumentRepository {
        stores.removeAll { $0.store == nil }
        guard let store = stores.last?.store else { throw CourseCloudSyncEngineError.notStarted }
        let workspaceID = snapshot.manifest.workspaceID
        let databaseURL = store.courseDatabaseURL(workspaceID: workspaceID)
        let existedBeforeSync = FileManager.default.fileExists(atPath: databaseURL.path)
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: databaseURL,
            rootTitle: title
        )
        await repository.configureContinuationControlDirectory(store.courseControlDirectory(workspaceID: workspaceID))

        if let base {
            _ = try await repository.applyRemoteSyncSnapshot(snapshot, baseSnapshot: base)
        } else {
            let current = try await repository.exportSyncSnapshot(generationID: "pre-cloud-import")
            if current.checksum == snapshot.checksum {
                // The local workspace is already the fetched generation.
            } else if !existedBeforeSync {
                try await repository.materializeRemoteSyncSnapshot(
                    snapshot,
                    expectedLocalChecksum: current.checksum
                )
            } else {
                throw CourseCloudSyncEngineError.missingMergeBase(workspaceID)
            }
        }
        // Each window observes its own Swift shell over the same persisted
        // course. Refresh every registered shell that owns this directory.
        for reference in stores {
            guard let windowStore = reference.store,
                  windowStore.courseDatabaseURL(workspaceID: workspaceID).standardizedFileURL == databaseURL.standardizedFileURL else { continue }
            await windowStore.importCourseContinuation(workspaceID: workspaceID)
            await windowStore.recoverReadyCourses()
        }
        return repository
    }
}
