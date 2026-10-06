import Foundation
import NativeBlockEditorCore
import NativeBlockEditorUI
import NativeEditorMCP
import Observation

private enum CourseDocumentRecoveryError: LocalizedError {
    case unreadableDraft(URL, Error)

    var errorDescription: String? {
        switch self {
        case let .unreadableDraft(url, error):
            "An unsaved course draft could not be read and was preserved at \(url.lastPathComponent). "
                + "The course was not opened to avoid losing it. \(error.localizedDescription)"
        }
    }
}

#if DEBUG
enum CourseDocumentDebugFlushError: LocalizedError {
    case simulatedFailure

    var errorDescription: String? {
        "Simulated course-page save failure. Your changes are still pending."
    }
}

private enum CourseDocumentDebugFixtureError: LocalizedError {
    case databaseMustBeTemporary
    case fixtureRootMustMatchRunToken
    case databaseMustBeInsideFixtureRoot
    case persistedDatabaseMissing
    case persistedWorkspaceMissing

    var errorDescription: String? {
        switch self {
        case .databaseMustBeTemporary:
            "Debug course fixtures must use an explicit directory inside the process temporary root."
        case .fixtureRootMustMatchRunToken:
            "The debug course fixture root did not match its canonical per-run token."
        case .databaseMustBeInsideFixtureRoot:
            "The debug course database must be contained by its exact per-run fixture root."
        case .persistedDatabaseMissing:
            "The persisted debug course database was missing; reopening must not create or reseed it."
        case .persistedWorkspaceMissing:
            "The persisted debug course database did not contain a course workspace; reopening must not seed a replacement."
        }
    }
}
#endif

struct CourseDocumentChange: Sendable {
    let pageID: String?
    let sequence: Int
    let snapshot: NativeEditorPageSnapshot?
    let replacesDocument: Bool
    let sourceEditID: UUID?
    let hasPendingUserEdit: Bool
    let errorMessage: String?
}

struct CourseDocumentOutline: Sendable {
    let rootPageID: String
    let bootstrapStatus: String?
    let allPages: [CourseLearningNode]
    let learningPages: [CourseLearningNode]

    var isReadyForLearning: Bool {
        bootstrapStatus == "ready_for_learning"
            && learningPages.contains(where: Self.containsGeneratedLearningPage)
    }

    private static func containsGeneratedLearningPage(_ node: CourseLearningNode) -> Bool {
        node.status == .generated
            || node.status == .partiallyGenerated
            || node.children.contains(where: containsGeneratedLearningPage)
    }
}

struct CourseSyncRemoteApplyResult: Equatable, Sendable {
    let changedPageIDs: [String]
    let resultingChecksum: String
}

enum CourseCloudSyncRepositoryError: Error, Equatable, LocalizedError {
    case workspaceMismatch
    case localWorkspaceChanged
    case structuralConflict([String])
    case contentConflict([String])

    var errorDescription: String? {
        switch self {
        case .workspaceMismatch:
            "The cloud course belongs to a different workspace."
        case .localWorkspaceChanged:
            "The local course changed before the cloud generation could be applied."
        case .structuralConflict(let ids):
            "Course structure changed concurrently for: \(ids.joined(separator: ", "))."
        case .contentConflict(let ids):
            "Course pages changed concurrently without a safe common base: \(ids.joined(separator: ", "))."
        }
    }
}

actor CourseDocumentRepository {
    let workspaceID: String

    /// The bundled practice course has an independent copy on each device.
    /// Sharing its fixed identity would merge unrelated tutorial exercises.
    nonisolated var allowsCloudSync: Bool {
        workspaceID != LearnfoldStarterCourse.workspaceID
    }

    private struct PendingUserEdit: Codable, Sendable {
        var document: BlockDocument
        var baseDocument: BlockDocument?
        var baseRevision: Int64?
        var sourceEditID: UUID?
    }

    private struct ActiveFlush: Sendable {
        let id: UUID
        let task: Task<[NativeEditorPageSnapshot], Error>
    }

    private let service: NativeEditorMCPService
    private let courseRoot: URL
    private var continuationControlDirectory: URL
    private let pendingEditsURL: URL
    private let autosaveDelay: Duration
    private let schedulesCloudSync: Bool
    private var pendingUserEdits: [String: PendingUserEdit] = [:]
    private var pendingSaveTask: Task<Void, Never>?
    private var activeFlush: ActiveFlush?
    private var latestSnapshots: [String: NativeEditorPageSnapshot] = [:]
    private var autosaveRetryAttempt = 0
    private var asyncTaskMonitors: [String: Task<Void, Never>] = [:]
    /// Unchanged visualizations are not re-rendered on every page edit.
    private var visualizationInspections: [String: HTMLBlockInspection] = [:]
    private var continuations: [UUID: AsyncStream<CourseDocumentChange>.Continuation] = [:]
    private var changeSequence = 0
#if DEBUG
    private var debugFlushFailures: [Duration] = []
    private var debugSuccessfulFlushDelays: [Duration] = []
    private var debugContinuationApplyInterleaving: (@Sendable () async throws -> Void)?
#endif

    private init(
        workspaceID: String,
        service: NativeEditorMCPService,
        courseRoot: URL,
        pendingEditsURL: URL,
        autosaveDelay: Duration,
        schedulesCloudSync: Bool,
        recoveredUserEdits: [String: PendingUserEdit]
    ) {
        self.workspaceID = workspaceID
        self.service = service
        self.courseRoot = courseRoot
        continuationControlDirectory = AppleCourseApprovalPolicy
            .protectedMetadataDirectory(courseDirectory: courseRoot).deletingLastPathComponent()
        self.pendingEditsURL = pendingEditsURL
        self.autosaveDelay = autosaveDelay
        self.schedulesCloudSync = schedulesCloudSync
        pendingUserEdits = recoveredUserEdits
    }

    static func open(
        workspaceID: String,
        databaseURL: URL,
        rootTitle: String,
        autosaveDelay: Duration = .milliseconds(350)
    ) async throws -> CourseDocumentRepository {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let courseRoot = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
        // Whether seeding is needed is the store's call, not the file system's.
        // SQLite creates the database file before the first workspace commits,
        // so gating on the file's existence meant a first open interrupted in
        // that window skipped the import for good and left the course showing
        // a blank "Home". The seed is an autoclosure, so the import still only
        // runs when the store really has no workspace.
        let service = try await NativeEditorMCPService.open(
            databaseURL: databaseURL,
            seedWorkspace: LegacyCoursePageImporter.makeSeedWorkspace(
                workspaceID: workspaceID,
                rootTitle: rootTitle,
                courseRoot: courseRoot
            )
        )
        let pendingEditsURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-user-edits.json")
        let recoveredUserEdits = try Self.loadPendingUserEdits(from: pendingEditsURL)
        let repository = CourseDocumentRepository(
            workspaceID: workspaceID,
            service: service,
            courseRoot: courseRoot,
            pendingEditsURL: pendingEditsURL,
            autosaveDelay: autosaveDelay,
            schedulesCloudSync: workspaceID != LearnfoldStarterCourse.workspaceID,
            recoveredUserEdits: recoveredUserEdits
        )
        if !recoveredUserEdits.isEmpty {
            await repository.scheduleAutosave(after: .milliseconds(50))
        }
        Task {
            await CourseCloudSyncEngine.shared.queueRepositoryChangesIfNeeded(
                repository: repository
            )
        }
        return repository
    }

#if DEBUG
    /// Opens a deterministic, caller-supplied workspace for Debug-only UI
    /// checkpoints. The boundary is intentionally temporary-directory-only so
    /// a fixture can never seed or replace a learner's real course database.
    static func openDebugFixture(
        workspaceID: String,
        databaseURL: URL,
        fixtureRootURL: URL,
        runToken: String,
        workspace: PageWorkspace,
        autosaveDelay: Duration = .seconds(60)
    ) async throws -> CourseDocumentRepository {
        let resolvedDatabaseURL = try validateDebugFixtureBoundary(
            databaseURL: databaseURL,
            fixtureRootURL: fixtureRootURL,
            runToken: runToken
        )

        try workspace.validate()
        try FileManager.default.createDirectory(
            at: resolvedDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let service = try await NativeEditorMCPService.open(
            databaseURL: resolvedDatabaseURL,
            seedWorkspace: workspace
        )
        let pendingEditsURL = resolvedDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-user-edits.json")
        return CourseDocumentRepository(
            workspaceID: workspaceID,
            service: service,
            courseRoot: resolvedDatabaseURL.deletingLastPathComponent().deletingLastPathComponent(),
            pendingEditsURL: pendingEditsURL,
            autosaveDelay: autosaveDelay,
            schedulesCloudSync: false,
            recoveredUserEdits: try loadPendingUserEdits(from: pendingEditsURL)
        )
    }

    /// Recreates the Debug-only repository around an existing SQLite database.
    /// This path fails before `NativeEditorMCPService.open` when persistence is
    /// absent, preventing its normal empty-database fallback from manufacturing
    /// a replacement workspace during a relaunch checkpoint.
    static func reopenDebugFixture(
        workspaceID: String,
        databaseURL: URL,
        fixtureRootURL: URL,
        runToken: String,
        autosaveDelay: Duration = .seconds(60)
    ) async throws -> CourseDocumentRepository {
        let resolvedDatabaseURL = try validateDebugFixtureBoundary(
            databaseURL: databaseURL,
            fixtureRootURL: fixtureRootURL,
            runToken: runToken
        )
        guard FileManager.default.fileExists(atPath: resolvedDatabaseURL.path) else {
            throw CourseDocumentDebugFixtureError.persistedDatabaseMissing
        }

        let preflightStore = try SQLiteLibraryStore(url: resolvedDatabaseURL)
        guard let persisted = try await preflightStore.load() else {
            throw CourseDocumentDebugFixtureError.persistedWorkspaceMissing
        }
        try persisted.workspace.validate()

        let service = try await NativeEditorMCPService.open(
            databaseURL: resolvedDatabaseURL,
            seedWorkspace: nil
        )
        let pendingEditsURL = resolvedDatabaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-user-edits.json")
        return CourseDocumentRepository(
            workspaceID: workspaceID,
            service: service,
            courseRoot: resolvedDatabaseURL.deletingLastPathComponent().deletingLastPathComponent(),
            pendingEditsURL: pendingEditsURL,
            autosaveDelay: autosaveDelay,
            schedulesCloudSync: false,
            recoveredUserEdits: try loadPendingUserEdits(from: pendingEditsURL)
        )
    }

    private static func validateDebugFixtureBoundary(
        databaseURL: URL,
        fixtureRootURL: URL,
        runToken: String
    ) throws -> URL {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedFixtureRoot = fixtureRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fixtureBase = resolvedFixtureRoot.deletingLastPathComponent()
        guard fixtureBase.deletingLastPathComponent().path == temporaryRoot.path else {
            throw CourseDocumentDebugFixtureError.databaseMustBeTemporary
        }
        guard resolvedFixtureRoot.lastPathComponent == runToken,
              UUID(uuidString: runToken)?.uuidString.lowercased() == runToken else {
            throw CourseDocumentDebugFixtureError.fixtureRootMustMatchRunToken
        }

        let resolvedDatabaseURL = databaseURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fixturePrefix = resolvedFixtureRoot.path.hasSuffix("/")
            ? resolvedFixtureRoot.path
            : resolvedFixtureRoot.path + "/"
        guard resolvedDatabaseURL.path.hasPrefix(fixturePrefix) else {
            throw CourseDocumentDebugFixtureError.databaseMustBeInsideFixtureRoot
        }
        return resolvedDatabaseURL
    }
#endif

    func rootPageSnapshot() async throws -> NativeEditorPageSnapshot {
        try await flushPendingUserEdits()
        return record(try await service.rootPageSnapshot())
    }

    func pageSnapshot(id: String) async throws -> NativeEditorPageSnapshot {
        try await flushPendingUserEdits()
        return record(try await service.pageSnapshot(id: id))
    }

    func workspaceSnapshot() async throws -> PageWorkspace {
        try await flushPendingUserEdits()
        return try await service.workspaceSnapshot()
    }

    func workspaceSnapshotWithGeneration() async throws -> NativeEditorWorkspaceSnapshot {
        try await flushPendingUserEdits()
        return try await service.workspaceSnapshotWithGeneration()
    }

    /// Installs a fully staged, approved course workspace in one SQLite CAS.
    /// A concurrent editor, native tool, or cloud writer advances the shared
    /// generation and makes this call fail without exposing any staged pages.
    func replaceApprovedWorkspace(
        _ replacement: PageWorkspace,
        expectedGeneration: Int64
    ) async throws {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
            workspaceID: workspaceID
        ) {
            try await self.replaceApprovedWorkspaceWhileHoldingSecurityGate(
                replacement,
                expectedGeneration: expectedGeneration
            )
        }
    }

    /// The workspace gate remains held while this actor performs the commit,
    /// publishes its replacement, and queues CloudKit reconciliation.
    private func replaceApprovedWorkspaceWhileHoldingSecurityGate(
        _ replacement: PageWorkspace,
        expectedGeneration: Int64
    ) async throws {
        try await flushPendingUserEdits()
        guard AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: courseRoot) else {
            throw AppleCourseAgentError.toolFailed(
                "The latest presented course plan has not been approved. Wait for explicit learner approval before changing native pages."
            )
        }
        try await service.replaceWorkspace(
            replacement,
            expectedGeneration: expectedGeneration
        )
        latestSnapshots.removeAll()
        publish(pageID: nil, replacesDocument: true)
        scheduleCloudSync()
    }

    func exportSyncSnapshot(
        generationID: String = UUID().uuidString.lowercased(),
        previousGenerationID: String? = nil,
        version: CourseSyncVersionVector = .init()
    ) async throws -> CourseSyncWorkspaceSnapshot {
        try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: try await workspaceSnapshot(),
            generationID: generationID,
            previousGenerationID: previousGenerationID,
            version: version,
            continuation: CourseContinuationSyncStore.export(
                courseDirectory: courseRoot,
                controlDirectory: continuationControlDirectory
            )
        )
    }

    func configureContinuationControlDirectory(_ directory: URL) {
        continuationControlDirectory = directory
    }

#if DEBUG
    func configureDebugContinuationApplyInterleaving(_ operation: @escaping @Sendable () async throws -> Void) {
        debugContinuationApplyInterleaving = operation
    }
#endif

    /// Metadata writers have no SQLite mutation receipt. Queue by the complete
    /// generation checksum after saving bookmarks, transcripts or practice.
    func continuationDidChange() {
        scheduleCloudSync()
    }

    func pendingSyncMutationReceipts(limit: Int = 256) async throws -> [LibraryMutationReceipt] {
        try await service.pendingSyncMutationReceipts(limit: limit)
    }

    func acknowledgeSyncMutationReceipts(ids: [String]) async throws {
        try await service.acknowledgeSyncMutationReceipts(ids: ids)
    }

    /// Applies a fetched cloud generation through the repository's serialized
    /// lane. The caller supplies the exact base generation it previously
    /// observed; unknown-base or structural conflicts remain unapplied in the
    /// durable cloud inbox for explicit recovery UI.
    @discardableResult
    func applyRemoteSyncSnapshot(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        baseSnapshot: CourseSyncWorkspaceSnapshot
    ) async throws -> CourseSyncRemoteApplyResult {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(workspaceID: workspaceID) {
            try await self.applyRemoteSyncSnapshotWhileHoldingSecurityGate(remoteSnapshot, baseSnapshot: baseSnapshot)
        }
    }

    private func applyRemoteSyncSnapshotWhileHoldingSecurityGate(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        baseSnapshot: CourseSyncWorkspaceSnapshot
    ) async throws -> CourseSyncRemoteApplyResult {
        guard remoteSnapshot.manifest.workspaceID == workspaceID,
              baseSnapshot.manifest.workspaceID == workspaceID else {
            throw CourseCloudSyncRepositoryError.workspaceMismatch
        }
        _ = try remoteSnapshot.validatedWorkspace()
        _ = try baseSnapshot.validatedWorkspace()
        try await flushPendingUserEdits()
        for attempt in 0..<4 {
            let versionedWorkspace = try await service.workspaceSnapshotWithGeneration()
            let localSnapshot = try CourseSyncWorkspaceSnapshot(
                workspaceID: workspaceID,
                workspace: versionedWorkspace.workspace,
                generationID: "local-comparison",
                continuation: CourseContinuationSyncStore.export(courseDirectory: courseRoot, controlDirectory: continuationControlDirectory)
            )

            if localSnapshot.checksum == remoteSnapshot.checksum {
                return CourseSyncRemoteApplyResult(
                    changedPageIDs: [],
                    resultingChecksum: localSnapshot.checksum
                )
            }
            if remoteSnapshot.checksum == baseSnapshot.checksum {
                return CourseSyncRemoteApplyResult(
                    changedPageIDs: [],
                    resultingChecksum: localSnapshot.checksum
                )
            }

            let merged: PageWorkspace
            let mergedContinuation = try CourseSyncContinuationMerger.merge(
                base: baseSnapshot.continuation,
                local: localSnapshot.continuation,
                remote: remoteSnapshot.continuation
            )
            try mergedContinuation?.validate(workspaceID: workspaceID)
            if localSnapshot.checksum == baseSnapshot.checksum {
                merged = try remoteSnapshot.validatedWorkspace()
            } else {
                merged = try CourseSyncWorkspaceMerger.merge(
                    base: baseSnapshot,
                    local: localSnapshot,
                    remote: remoteSnapshot
                )
            }

            do {
                try await service.replaceWorkspace(
                    merged,
                    expectedGeneration: versionedWorkspace.generation
                )
            } catch LibraryStoreError.workspaceGenerationConflict where attempt < 3 {
                continue
            }
#if DEBUG
            if let interleaving = debugContinuationApplyInterleaving {
                debugContinuationApplyInterleaving = nil
                try await interleaving()
            }
#endif
            let appliedContinuation = try CourseContinuationSyncStore.applyMergingConcurrentChanges(
                mergedContinuation,
                replacing: localSnapshot.continuation,
                courseDirectory: courseRoot,
                controlDirectory: continuationControlDirectory
            )
            latestSnapshots.removeAll()
            let mergedChecksums = Dictionary(
                uniqueKeysWithValues: try merged.pages.values.map {
                    ($0.id, try CourseSyncPageDocument($0).checksum)
                }
            )
            let changedPageIDs = Set(localSnapshot.pages.map(\.id))
                .union(remoteSnapshot.pages.map(\.id))
                .filter { pageID in
                    localSnapshot.pages.first(where: { $0.id == pageID })?.checksum
                        != mergedChecksums[pageID]
                }
                .sorted()
            publish(pageID: nil, replacesDocument: true)
            let result = try CourseSyncWorkspaceSnapshot(
                workspaceID: workspaceID,
                workspace: merged,
                generationID: remoteSnapshot.manifest.generationID,
                previousGenerationID: remoteSnapshot.manifest.previousGenerationID,
                version: localSnapshot.manifest.version.merged(with: remoteSnapshot.manifest.version),
                continuation: appliedContinuation
            )
            return CourseSyncRemoteApplyResult(
                changedPageIDs: changedPageIDs,
                resultingChecksum: result.checksum
            )
        }
        throw CourseCloudSyncRepositoryError.localWorkspaceChanged
    }

    /// Replaces a workspace only when the caller proves the local content is
    /// still the exact staging/base snapshot it inspected.
    func materializeRemoteSyncSnapshot(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        expectedLocalChecksum: String
    ) async throws {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(workspaceID: workspaceID) {
            try await self.materializeRemoteSyncSnapshotWhileHoldingSecurityGate(remoteSnapshot, expectedLocalChecksum: expectedLocalChecksum)
        }
    }

    private func materializeRemoteSyncSnapshotWhileHoldingSecurityGate(
        _ remoteSnapshot: CourseSyncWorkspaceSnapshot,
        expectedLocalChecksum: String
    ) async throws {
        guard remoteSnapshot.manifest.workspaceID == workspaceID else {
            throw CourseCloudSyncRepositoryError.workspaceMismatch
        }
        try await flushPendingUserEdits()
        let versionedWorkspace = try await service.workspaceSnapshotWithGeneration()
        let localSnapshot = try CourseSyncWorkspaceSnapshot(
            workspaceID: workspaceID,
            workspace: versionedWorkspace.workspace,
            generationID: "materialization-check",
            continuation: CourseContinuationSyncStore.export(courseDirectory: courseRoot, controlDirectory: continuationControlDirectory)
        )
        guard localSnapshot.checksum == expectedLocalChecksum else {
            throw CourseCloudSyncRepositoryError.localWorkspaceChanged
        }
        do {
            try await service.replaceWorkspace(
                try remoteSnapshot.validatedWorkspace(),
                expectedGeneration: versionedWorkspace.generation
            )
        } catch LibraryStoreError.workspaceGenerationConflict {
            throw CourseCloudSyncRepositoryError.localWorkspaceChanged
        }
        _ = try CourseContinuationSyncStore.applyMergingConcurrentChanges(
            remoteSnapshot.continuation,
            replacing: localSnapshot.continuation,
            courseDirectory: courseRoot,
            controlDirectory: continuationControlDirectory
        )
        latestSnapshots.removeAll()
        publish(pageID: nil, replacesDocument: true)
    }

    func outline() async throws -> CourseDocumentOutline {
        let workspace = try await workspaceSnapshot()
        return try Self.outline(from: workspace)
    }

    static func outline(from workspace: PageWorkspace) throws -> CourseDocumentOutline {
        guard let root = workspace.page(id: workspace.rootPageID) else {
            throw NativeEditorMCPError.pageNotFound(workspace.rootPageID)
        }
        let allPages = workspace.children(of: root.id).map { pageNode($0, workspace: workspace) }
        let learningPages = allPages.filter { node in
            guard let page = workspace.page(id: node.pageID ?? node.id) else { return true }
            let role = page.document.root.data["course_role"]?.stringValue
            return role != "context" && role != "agent_notes"
        }
        return CourseDocumentOutline(
            rootPageID: root.id,
            bootstrapStatus: root.document.root.data["course_bootstrap_status"]?.stringValue,
            allPages: allPages,
            learningPages: learningPages
        )
    }

    func stageUserEdit(
        pageID: String,
        document: BlockDocument,
        capturedBaseDocument: BlockDocument? = nil,
        capturedBaseRevision: Int64? = nil,
        sourceEditID: UUID? = nil
    ) throws {
        if var existing = pendingUserEdits[pageID] {
            existing.document = document
            existing.sourceEditID = sourceEditID
            pendingUserEdits[pageID] = existing
        } else {
            let base = latestSnapshots[pageID]
            pendingUserEdits[pageID] = PendingUserEdit(
                document: document,
                baseDocument: base?.document ?? capturedBaseDocument,
                baseRevision: base?.revision ?? capturedBaseRevision,
                sourceEditID: sourceEditID
            )
        }

        autosaveRetryAttempt = 0
        do {
            try persistPendingUserEdits()
            scheduleAutosave(after: autosaveDelay)
        } catch {
            // The draft is still retained by the repository actor. Persist it
            // into SQLite promptly instead of leaving it idle just because the
            // crash-recovery journal was temporarily unavailable.
            scheduleAutosave(after: .milliseconds(50))
            throw error
        }
    }

    @discardableResult
    func flushPendingUserEdits() async throws -> [NativeEditorPageSnapshot] {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        var snapshots: [NativeEditorPageSnapshot] = []

        while activeFlush != nil || !pendingUserEdits.isEmpty {
            let flush: ActiveFlush
            if let existing = activeFlush {
                flush = existing
            } else {
                let id = UUID()
                let task = Task<[NativeEditorPageSnapshot], Error> { [weak self] in
                    guard let self else { return [] }
                    return try await self.savePendingBatch()
                }
                flush = ActiveFlush(id: id, task: task)
                activeFlush = flush
            }

            do {
                snapshots.append(contentsOf: try await flush.task.value)
                if activeFlush?.id == flush.id {
                    activeFlush = nil
                }
            } catch {
                if activeFlush?.id == flush.id {
                    activeFlush = nil
                }
                throw error
            }
        }

        if !snapshots.isEmpty {
            scheduleCloudSync()
        }
        return snapshots
    }

#if DEBUG
    /// Queues deterministic, single-use failures before a pending batch is
    /// removed. Tests and the Debug-only editor harness use this to prove that
    /// retrying flushes the original draft instead of staging a duplicate.
    func debugFailNextFlushes(_ count: Int = 1, delay: Duration = .zero) {
        guard count > 0 else { return }
        debugFlushFailures.append(contentsOf: repeatElement(delay, count: count))
    }

    /// Delays the next real successful save while it remains inside the
    /// repository flush operation. This keeps the model's genuine `.saving`
    /// transition observable without replacing product state in the view.
    func debugDelayNextSuccessfulFlush(_ delay: Duration) {
        guard delay != .zero else { return }
        debugSuccessfulFlushDelays.append(delay)
    }
#endif

    private func savePendingBatch() async throws -> [NativeEditorPageSnapshot] {
#if DEBUG
        if !debugFlushFailures.isEmpty {
            let delay = debugFlushFailures.removeFirst()
            if delay != .zero {
                try await Task.sleep(for: delay)
            }
            throw CourseDocumentDebugFlushError.simulatedFailure
        }
        if !debugSuccessfulFlushDelays.isEmpty {
            try await Task.sleep(for: debugSuccessfulFlushDelays.removeFirst())
        }
#endif
        let batch = pendingUserEdits
        pendingUserEdits.removeAll()
        var unsaved = batch
        var snapshots: [NativeEditorPageSnapshot] = []

        for pageID in batch.keys.sorted() {
            guard let edit = unsaved.removeValue(forKey: pageID) else { continue }
            do {
                let snapshot = try await saveUserEdit(edit, pageID: pageID)
                latestSnapshots[pageID] = snapshot
                snapshots.append(snapshot)

                if var queued = pendingUserEdits[pageID] {
                    queued.document = CourseDocumentThreeWayMerger.merge(
                        base: edit.document,
                        local: queued.document,
                        remote: snapshot.document
                    )
                    queued.baseDocument = snapshot.document
                    queued.baseRevision = snapshot.revision
                    pendingUserEdits[pageID] = queued
                }

                do {
                    try persistPendingUserEdits()
                } catch {
                    publishFailure(pageID: pageID, error: error)
                }
                publish(
                    pageID: pageID,
                    snapshot: snapshot,
                    replacesDocument: pendingUserEdits[pageID] == nil
                        && !CourseDocumentThreeWayMerger.semanticallyEqual(snapshot.document, edit.document),
                    sourceEditID: edit.sourceEditID,
                    hasPendingUserEdit: pendingUserEdits[pageID] != nil
                )
            } catch {
                requeue(edit, pageID: pageID)
                for (remainingPageID, remainingEdit) in unsaved {
                    requeue(remainingEdit, pageID: remainingPageID)
                }
                try? persistPendingUserEdits()
                throw error
            }
        }

        return snapshots
    }

    private func saveUserEdit(
        _ edit: PendingUserEdit,
        pageID: String
    ) async throws -> NativeEditorPageSnapshot {
        var baseDocument = edit.baseDocument
        var expectedRevision = edit.baseRevision
        if baseDocument == nil || expectedRevision == nil {
            let snapshot = record(try await service.pageSnapshot(id: pageID))
            baseDocument = snapshot.document
            expectedRevision = snapshot.revision
        }

        var candidate = edit.document
        for _ in 0 ..< 8 {
            do {
                return try await service.saveDocument(
                    candidate,
                    pageID: pageID,
                    expectedRevision: expectedRevision ?? 0
                )
            } catch let error as NativeEditorMCPError {
                switch error {
                case .revisionConflict, .workspaceGenerationConflict:
                    let remote = record(try await service.pageSnapshot(id: pageID))
                    candidate = CourseDocumentThreeWayMerger.merge(
                        base: baseDocument ?? remote.document,
                        local: candidate,
                        remote: remote.document
                    )
                    expectedRevision = remote.revision
                default:
                    throw error
                }
            }
        }

        let actualSnapshot = try await service.pageSnapshot(id: pageID)
        throw NativeEditorMCPError.revisionConflict(
            pageID: pageID,
            expected: expectedRevision ?? 0,
            actual: actualSnapshot.revision
        )
    }

    private func requeue(_ edit: PendingUserEdit, pageID: String) {
        if var newer = pendingUserEdits[pageID] {
            if newer.baseDocument == nil {
                newer.baseDocument = edit.baseDocument
                newer.baseRevision = edit.baseRevision
            }
            pendingUserEdits[pageID] = newer
        } else {
            pendingUserEdits[pageID] = edit
        }
    }

    private func record(_ snapshot: NativeEditorPageSnapshot) -> NativeEditorPageSnapshot {
        latestSnapshots[snapshot.id] = snapshot
        return snapshot
    }

    private func scheduleAutosave(after delay: Duration) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                _ = try await self.flushPendingUserEdits()
                await self.autosaveDidSucceed()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                await self.autosaveDidFail(error)
            }
        }
    }

    private func autosaveDidSucceed() {
        autosaveRetryAttempt = 0
    }

    private func autosaveDidFail(_ error: Error) {
        let pageIDs = pendingUserEdits.keys.sorted()
        for pageID in pageIDs {
            publishFailure(pageID: pageID, error: error)
        }
        guard !pendingUserEdits.isEmpty else { return }
        autosaveRetryAttempt = min(autosaveRetryAttempt + 1, 6)
        let seconds = min(30, 1 << autosaveRetryAttempt)
        scheduleAutosave(after: .seconds(seconds))
    }

    private func persistPendingUserEdits() throws {
        if pendingUserEdits.isEmpty {
            if FileManager.default.fileExists(atPath: pendingEditsURL.path) {
                try FileManager.default.removeItem(at: pendingEditsURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: pendingEditsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(pendingUserEdits)
        try data.write(
            to: pendingEditsURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private static func loadPendingUserEdits(from url: URL) throws -> [String: PendingUserEdit] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: PendingUserEdit].self, from: Data(contentsOf: url))
        } catch {
            // Never turn an unreadable draft into an apparently empty draft.
            // Preserve the original bytes in place and block opening until the
            // recovery issue is handled explicitly.
            throw CourseDocumentRecoveryError.unreadableDraft(url, error)
        }
    }

    func callTool(named name: String, argumentsJSON: String) async -> NativeEditorMCPToolResult {
        let requiresApprovedPlan = Self.mutatingTools.contains(name)
        if requiresApprovedPlan {
            do {
                return try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
                    workspaceID: workspaceID
                ) {
                    await callToolWithAuthorizationHeld(
                        named: name,
                        argumentsJSON: argumentsJSON,
                        requiresApprovedPlan: true
                    )
                }
            } catch {
                return NativeEditorMCPToolResult(
                    value: .object([
                        "object": "error",
                        "code": "repository_error",
                        "message": .string(error.localizedDescription),
                    ]),
                    isError: true
                )
            }
        }
        return await callToolWithAuthorizationHeld(
            named: name,
            argumentsJSON: argumentsJSON,
            requiresApprovedPlan: false
        )
    }

    private func callToolWithAuthorizationHeld(
        named name: String,
        argumentsJSON: String,
        requiresApprovedPlan: Bool
    ) async -> NativeEditorMCPToolResult {
        do {
            try Task.checkCancellation()
            try await flushPendingUserEdits()
            try Task.checkCancellation()
            if requiresApprovedPlan,
               !AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: courseRoot) {
                return Self.planNotApprovedResult()
            }
            let data = Data(argumentsJSON.utf8)
            let arguments = try JSONDecoder().decode([String: JSONValue].self, from: data)
            let result = await service.callTool(named: name, arguments: arguments)
            if !result.isError {
                if let task = Self.asyncTaskDescriptor(result.value) {
                    if requiresApprovedPlan {
                        // Native async tasks are in-memory and may commit after
                        // the initial queued descriptor. Keep the plan lease
                        // until the device has actually finished the mutation,
                        // and return that terminal result to Hermes.
                        guard let terminal = await awaitAsyncTaskTerminal(id: task.id) else {
                            return NativeEditorMCPToolResult(
                                value: .object([
                                    "object": "error",
                                    "code": "async_task_timeout",
                                    "message": .string(
                                        "The page edit did not report a result in time."
                                    ),
                                ]),
                                isError: true
                            )
                        }
                        handleAsyncTask(terminal.descriptor)
                        let terminalResult = NativeEditorMCPToolResult(
                            value: terminal.value,
                            isError: terminal.descriptor.status == "failed"
                        )
                        return await addingVisualizationCheck(
                            to: terminalResult,
                            tool: name,
                            arguments: arguments
                        )
                    }
                    handleAsyncTask(task)
                } else if Self.mutatingTools.contains(name) {
                    let pageID = arguments["page_id"]?.stringValue
                    latestSnapshots.removeAll()
                    publish(pageID: pageID, replacesDocument: true)
                    scheduleCloudSync()
                    return await addingVisualizationCheck(to: result, tool: name, arguments: arguments)
                }
            }
            return result
        } catch {
            return NativeEditorMCPToolResult(
                value: .object([
                    "object": "error",
                    "code": "repository_error",
                    "message": .string(error.localizedDescription),
                ]),
                isError: true
            )
        }
    }

    /// Renders each visualization on the pages a successful write touched and
    /// attaches what a learner would hit, so the agent fixes it right away.
    private func addingVisualizationCheck(
        to result: NativeEditorMCPToolResult,
        tool: String,
        arguments: [String: JSONValue]
    ) async -> NativeEditorMCPToolResult {
        guard !result.isError,
              CourseVisualizationCheck.writesContent(tool: tool, arguments: arguments) else { return result }
        var reports: [CourseVisualizationCheck.PageReport] = []
        for pageID in CourseVisualizationCheck.writtenPageIDs(in: result.value) {
            guard let snapshot = try? await service.pageSnapshot(id: pageID) else { continue }
            let visualizations = CourseVisualizationCheck.visualizations(in: snapshot.document)
            guard !visualizations.isEmpty else { continue }
            var issues: [[String]] = []
            for html in visualizations {
                issues.append(await visualizationInspection(for: html).issues)
            }
            reports.append(.init(pageID: pageID, title: snapshot.title, visualizationIssues: issues))
        }
        guard let check = CourseVisualizationCheck.value(for: reports) else { return result }
        return CourseVisualizationCheck.attaching(check, to: result)
    }

    private func visualizationInspection(for html: String) async -> HTMLBlockInspection {
        if let cached = visualizationInspections[html] { return cached }
        let inspection = await HTMLBlockInspector.inspect(html: html)
        if visualizationInspections.count >= 32 { visualizationInspections.removeAll() }
        visualizationInspections[html] = inspection
        return inspection
    }

    func isLatestPlanApproved() -> Bool {
        AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: courseRoot)
    }

    func presentPlan(_ plan: CourseBrief) async throws {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
            workspaceID: workspaceID
        ) {
            try await self.writePresentedPlan(plan)
        }
    }

    func presentPlanForRecoveryIfUnchanged(_ plan: CourseBrief) async throws {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
            workspaceID: workspaceID
        ) {
            try await self.presentPlanForRecoveryWhileHoldingSecurityGate(plan)
        }
    }

    private func presentPlanForRecoveryWhileHoldingSecurityGate(_ plan: CourseBrief) throws {
        let presentedURL = AppleCourseApprovalPolicy.protectedPlanURL(
            courseDirectory: courseRoot,
            filename: AppleCourseApprovalPolicy.presentedPlanFilename
        )
        if FileManager.default.fileExists(atPath: presentedURL.path) {
            let current = try JSONDecoder().decode(
                CourseBrief.self,
                from: Data(contentsOf: presentedURL)
            )
            guard current == plan else {
                throw AppleCourseAgentError.toolFailed(
                    "A different course plan is already being reviewed. Learnfold preserved it and did not replay the older Hermes presentation."
                )
            }
            return
        }
        try writePresentedPlan(plan)
    }

    private func writePresentedPlan(_ plan: CourseBrief) throws {
        guard !plan.planID.isEmpty else {
            throw AppleCourseAgentError.toolFailed(
                "The generated course plan is missing its plan identifier."
            )
        }
        let metadataDirectory = courseRoot.appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.courseFileEncoder.encode(plan)
        let protectedURL = AppleCourseApprovalPolicy.protectedPlanURL(
            courseDirectory: courseRoot,
            filename: AppleCourseApprovalPolicy.presentedPlanFilename
        )
        try FileManager.default.createDirectory(
            at: protectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: protectedURL, options: .atomic)
        // Keep a readable workspace mirror for agent context. It is not used
        // for authorization because course_bash may freely change it.
        try data.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.presentedPlanFilename
            ),
            options: .atomic
        )
        scheduleCloudSync()
    }

    func approvePlan(_ plan: CourseBrief) async throws {
        try await CourseWorkspaceSecurityGate.shared.withExclusiveAccess(
            workspaceID: workspaceID
        ) {
            try await self.approvePlanWhileHoldingSecurityGate(plan)
        }
    }

    private func approvePlanWhileHoldingSecurityGate(_ plan: CourseBrief) throws {
        let protectedPresentedURL = AppleCourseApprovalPolicy.protectedPlanURL(
            courseDirectory: courseRoot,
            filename: AppleCourseApprovalPolicy.presentedPlanFilename
        )
        // Remote Codex validates and returns dynamic-tool arguments on its
        // server. If the app was suspended before its completed call could
        // be mirrored locally, the learner's explicit Approve tap is the
        // first authoritative phone-side boundary.
        if !FileManager.default.fileExists(atPath: protectedPresentedURL.path) {
            try writePresentedPlan(plan)
        }
        let presented = try JSONDecoder().decode(
            CourseBrief.self,
            from: Data(contentsOf: protectedPresentedURL)
        )
        guard presented == plan else {
            throw AppleCourseAgentError.toolFailed(
                "The plan changed before approval was committed. Review the latest revision and approve it explicitly."
            )
        }
        let data = try JSONEncoder.courseFileEncoder.encode(presented)
        let metadataDirectory = courseRoot.appendingPathComponent(".course", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        // Write the learner-visible mirror first. Only the final protected
        // write commits authorization, so a storage failure cannot grant it.
        try data.write(
            to: metadataDirectory.appendingPathComponent(
                AppleCourseApprovalPolicy.approvedPlanFilename
            ),
            options: .atomic
        )
        let protectedApprovedURL = AppleCourseApprovalPolicy.protectedPlanURL(
            courseDirectory: courseRoot,
            filename: AppleCourseApprovalPolicy.approvedPlanFilename
        )
        try FileManager.default.createDirectory(
            at: protectedApprovedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: protectedApprovedURL, options: .atomic)
        scheduleCloudSync()
    }

    private static func planNotApprovedResult() -> NativeEditorMCPToolResult {
        NativeEditorMCPToolResult(
            value: .object([
                "object": "error",
                "code": "course_plan_not_approved",
                "message": "The latest presented course plan has not been approved. Wait for explicit learner approval before changing native pages.",
            ]),
            isError: true
        )
    }

    func changes() -> AsyncStream<CourseDocumentChange> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func scheduleCloudSync() {
        guard schedulesCloudSync else { return }
        Task {
            await CourseCloudSyncEngine.shared.queueRepositoryChangesIfNeeded(repository: self)
        }
    }

    private func publish(
        pageID: String?,
        snapshot: NativeEditorPageSnapshot? = nil,
        replacesDocument: Bool = false,
        sourceEditID: UUID? = nil,
        hasPendingUserEdit: Bool = false,
        errorMessage: String? = nil
    ) {
        changeSequence &+= 1
        let change = CourseDocumentChange(
            pageID: pageID,
            sequence: changeSequence,
            snapshot: snapshot,
            replacesDocument: replacesDocument,
            sourceEditID: sourceEditID,
            hasPendingUserEdit: hasPendingUserEdit,
            errorMessage: errorMessage
        )
        for continuation in continuations.values {
            continuation.yield(change)
        }
    }

    private func publishFailure(pageID: String?, error: Error) {
        publish(pageID: pageID, errorMessage: error.localizedDescription)
    }

    private static let mutatingTools: Set<String> = [
        NativeEditorMCPToolCatalog.createPages,
        NativeEditorMCPToolCatalog.updatePage,
        NativeEditorMCPToolCatalog.movePages,
        NativeEditorMCPToolCatalog.duplicatePage,
    ]

    private struct AsyncTaskDescriptor: Sendable {
        var id: String
        var status: String
    }

    private struct TerminalAsyncTask: Sendable {
        var descriptor: AsyncTaskDescriptor
        var value: JSONValue
    }

    private static func asyncTaskDescriptor(_ value: JSONValue) -> AsyncTaskDescriptor? {
        guard let object = value.objectValue,
              object["object"]?.stringValue == "async_task",
              let id = object["id"]?.stringValue,
              let status = object["status"]?.stringValue else { return nil }
        return AsyncTaskDescriptor(id: id, status: status)
    }

    private func handleAsyncTask(_ task: AsyncTaskDescriptor) {
        switch task.status {
        case "succeeded":
            asyncTaskMonitors.removeValue(forKey: task.id)?.cancel()
            latestSnapshots.removeAll()
            publish(pageID: nil, replacesDocument: true)
            scheduleCloudSync()
        case "failed":
            asyncTaskMonitors.removeValue(forKey: task.id)?.cancel()
        default:
            startAsyncTaskMonitor(id: task.id)
        }
    }

    /// Upper bound on how long the plan lease is held waiting for a native
    /// mutation to reach a terminal state. Without it a task that never
    /// reports `succeeded`/`failed` wedges the workspace security gate for the
    /// rest of the process's life, blocking every later course operation.
    private static let asyncTaskTerminalTimeout: Duration = .seconds(120)

    private func awaitAsyncTaskTerminal(id: String) async -> TerminalAsyncTask? {
        let service = self.service
        let deadline = ContinuousClock.now.advanced(by: Self.asyncTaskTerminalTimeout)
        return await Task.detached {
            var pollDelay: Duration = .milliseconds(100)
            while ContinuousClock.now < deadline {
                do {
                    let value = try await service.asyncTask(["task_id": .string(id)])
                    if let descriptor = Self.asyncTaskDescriptor(value),
                       descriptor.status == "succeeded" || descriptor.status == "failed" {
                        return TerminalAsyncTask(descriptor: descriptor, value: value)
                    }
                    pollDelay = .milliseconds(100)
                } catch {
                    pollDelay = .milliseconds(500)
                }
                // Detached polling intentionally outlives cancellation of the
                // Hermes request. Releasing the authorization lease while the
                // native mutation can still commit would be unsafe.
                try? await Task.sleep(for: pollDelay)
            }
            return nil
        }.value
    }

    private func startAsyncTaskMonitor(id: String) {
        guard asyncTaskMonitors[id] == nil else { return }
        asyncTaskMonitors[id] = Task { [weak self] in
            var pollDelay: Duration = .milliseconds(200)
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: pollDelay)
                    guard let self else { return }
                    let value = try await self.service.asyncTask(["task_id": .string(id)])
                    guard let task = Self.asyncTaskDescriptor(value) else { return }
                    consecutiveFailures = 0
                    pollDelay = .milliseconds(200)
                    if task.status == "succeeded" || task.status == "failed" {
                        await self.handleAsyncTask(task)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Polling is observational; a transient failure must not
                    // abandon a mutation that can still commit later. Keep the
                    // monitor alive with bounded exponential backoff until the
                    // service reports a terminal state or the repository dies.
                    consecutiveFailures = min(consecutiveFailures + 1, 6)
                    let milliseconds = min(5_000, 200 * (1 << consecutiveFailures))
                    pollDelay = .milliseconds(milliseconds)
                }
            }
        }
    }

    private static func pageNode(_ page: PageRecord, workspace: PageWorkspace) -> CourseLearningNode {
        let children = workspace.children(of: page.id).map { pageNode($0, workspace: workspace) }
        let role = page.document.root.data["course_role"]?.stringValue
        let isLeafPage = role.map {
            ["lesson", "module", "context", "agent_notes", "explainer"].contains($0)
        } ?? false
        // A lesson that gains child pages stays a readable lesson; its
        // children are branches, not a new section of the planned path.
        let kind: CourseLearningNode.Kind = isLeafPage
            ? .markdown
            : .folder
        let explicitStatus = page.document.root.data["course_generation_status"]?.stringValue
            .flatMap(CourseLearningNode.GenerationStatus.init(rawValue:))
        let contentBlocks = page.document.root.children.filter {
            $0.type != "nbe/child_page" && $0.type != "nbe/page_reference"
        }
        let derivedStatus: CourseLearningNode.GenerationStatus
        if kind == .folder, !children.isEmpty, explicitStatus != .generating {
            let childStatuses = children.map(\.status)
            if childStatuses.allSatisfy({ $0 == .generated }) {
                derivedStatus = .generated
            } else if childStatuses.allSatisfy({ $0 == .pendingGeneration }) {
                derivedStatus = .pendingGeneration
            } else {
                derivedStatus = .partiallyGenerated
            }
        } else if let explicitStatus {
            derivedStatus = explicitStatus
        } else if !contentBlocks.isEmpty || (kind == .folder && !children.isEmpty) {
            derivedStatus = .generated
        } else {
            derivedStatus = .pendingGeneration
        }
        return CourseLearningNode(
            id: page.document.root.data["course_node_id"]?.stringValue ?? page.id,
            title: page.title,
            kind: kind,
            status: derivedStatus,
            role: role.flatMap(CourseLearningNode.Role.init(rawValue:)),
            pageID: page.id,
            children: children,
            originQuestion: page.document.root.data["course_origin_question"]?.stringValue,
            originAnchor: CourseExplorationAnchor(
                propertyValue: page.document.root.data["course_origin_anchor"]?.stringValue
            )
        )
    }
}

private enum CourseSyncWorkspaceMerger {
    static func merge(
        base: CourseSyncWorkspaceSnapshot,
        local: CourseSyncWorkspaceSnapshot,
        remote: CourseSyncWorkspaceSnapshot
    ) throws -> PageWorkspace {
        let baseWorkspace = try base.validatedWorkspace()
        let localWorkspace = try local.validatedWorkspace()
        let remoteWorkspace = try remote.validatedWorkspace()

        let allItemIDs = Set(baseWorkspace.items.keys)
            .union(localWorkspace.items.keys)
            .union(remoteWorkspace.items.keys)
        var mergedItems: [String: NativeBlockEditorLibrary.LibraryItem] = [:]
        var structuralConflicts: [String] = []

        for id in allItemIDs.sorted() {
            do {
                if let item = try mergeItem(
                    id: id,
                    base: baseWorkspace.items[id],
                    local: localWorkspace.items[id],
                    remote: remoteWorkspace.items[id]
                ) {
                    mergedItems[id] = item
                }
            } catch {
                structuralConflicts.append(id)
            }
        }
        guard structuralConflicts.isEmpty else {
            throw CourseCloudSyncRepositoryError.structuralConflict(structuralConflicts)
        }

        let allPageIDs = Set(baseWorkspace.pages.keys)
            .union(localWorkspace.pages.keys)
            .union(remoteWorkspace.pages.keys)
        var mergedPages: [String: PageRecord] = [:]
        var contentConflicts: [String] = []

        for id in allPageIDs.sorted() {
            guard let mergedItem = mergedItems[id], mergedItem.kind == .page else { continue }
            let basePage = baseWorkspace.pages[id]
            let localPage = localWorkspace.pages[id]
            let remotePage = remoteWorkspace.pages[id]

            do {
                let page = try mergePage(
                    id: id,
                    item: mergedItem,
                    base: basePage,
                    local: localPage,
                    remote: remotePage
                )
                mergedPages[id] = page
            } catch {
                contentConflicts.append(id)
            }
        }
        guard contentConflicts.isEmpty else {
            throw CourseCloudSyncRepositoryError.contentConflict(contentConflicts)
        }

        return try PageWorkspace(
            rootPageID: try mergeRequiredValue(
                base: baseWorkspace.rootPageID,
                local: localWorkspace.rootPageID,
                remote: remoteWorkspace.rootPageID
            ),
            pages: mergedPages,
            items: mergedItems
        )
    }

    private static func mergeItem(
        id: String,
        base: NativeBlockEditorLibrary.LibraryItem?,
        local: NativeBlockEditorLibrary.LibraryItem?,
        remote: NativeBlockEditorLibrary.LibraryItem?
    ) throws -> NativeBlockEditorLibrary.LibraryItem? {
        guard let base, let local, let remote else {
            return try mergeValue(base: base, local: local, remote: remote)
        }
        return NativeBlockEditorLibrary.LibraryItem(
            id: id,
            kind: try mergeRequiredValue(
                base: base.kind,
                local: local.kind,
                remote: remote.kind
            ),
            parentID: try mergeValue(
                base: base.parentID,
                local: local.parentID,
                remote: remote.parentID
            ),
            sortKey: try mergeRequiredValue(
                base: base.sortKey,
                local: local.sortKey,
                remote: remote.sortKey
            ),
            title: try mergeRequiredValue(
                base: base.title,
                local: local.title,
                remote: remote.title
            ),
            icon: try mergeRequiredValue(
                base: base.icon,
                local: local.icon,
                remote: remote.icon
            ),
            isFavorite: try mergeRequiredValue(
                base: base.isFavorite,
                local: local.isFavorite,
                remote: remote.isFavorite
            ),
            createdAt: min(local.createdAt, remote.createdAt),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            lastOpenedAt: max(local.lastOpenedAt ?? .distantPast, remote.lastOpenedAt ?? .distantPast)
                .nilIfDistantPast,
            trashedAt: try mergeValue(
                base: base.trashedAt,
                local: local.trashedAt,
                remote: remote.trashedAt
            )
        )
    }

    private static func mergePage(
        id: String,
        item: NativeBlockEditorLibrary.LibraryItem,
        base: PageRecord?,
        local: PageRecord?,
        remote: PageRecord?
    ) throws -> PageRecord {
        let selected: PageRecord
        switch (base, local, remote) {
        case (_, let local?, let remote?) where local == remote:
            selected = local
        case (let base?, let local?, let remote?) where local == base:
            selected = remote
        case (let base?, let local?, let remote?) where remote == base:
            selected = local
        case (let base?, let local?, let remote?):
            selected = PageRecord(
                id: id,
                title: item.title,
                icon: item.icon,
                parentID: item.parentID,
                document: CourseDocumentThreeWayMerger.merge(
                    base: base.document,
                    local: local.document,
                    remote: remote.document
                ),
                createdAt: min(local.createdAt, remote.createdAt),
                updatedAt: max(local.updatedAt, remote.updatedAt)
            )
        case (nil, let local?, nil):
            selected = local
        case (nil, nil, let remote?):
            selected = remote
        case (nil, let local?, let remote?) where local == remote:
            selected = local
        case (let base?, nil, let remote?) where remote == base:
            throw MergeConflict()
        case (let base?, let local?, nil) where local == base:
            throw MergeConflict()
        default:
            throw MergeConflict()
        }

        return PageRecord(
            id: id,
            title: item.title,
            icon: item.icon,
            parentID: item.parentID,
            document: selected.document,
            createdAt: selected.createdAt,
            updatedAt: selected.updatedAt
        )
    }

    private static func mergeValue<T: Equatable>(
        base: T?,
        local: T?,
        remote: T?
    ) throws -> T? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        if base == nil {
            if local == nil { return remote }
            if remote == nil { return local }
        }
        throw MergeConflict()
    }

    private static func mergeRequiredValue<T: Equatable>(
        base: T,
        local: T,
        remote: T
    ) throws -> T {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        throw MergeConflict()
    }

    private struct MergeConflict: Error {}
}

private extension Date {
    var nilIfDistantPast: Date? {
        self == .distantPast ? nil : self
    }
}

/// Three-way reconciliation for the local editor lane. Stable block IDs let us
/// preserve independent learner and agent changes without replacing a whole
/// page merely because its SQLite revision advanced.
private enum CourseDocumentThreeWayMerger {
    static func semanticallyEqual(_ lhs: BlockDocument, _ rhs: BlockDocument) -> Bool {
        semanticallyEqual(lhs.root, rhs.root)
    }

    static func merge(
        base: BlockDocument,
        local: BlockDocument,
        remote: BlockDocument
    ) -> BlockDocument {
        if semanticallyEqual(local.root, base.root) { return remote }
        if semanticallyEqual(remote.root, base.root) { return local }
        if semanticallyEqual(local.root, remote.root) { return local }

        var document = BlockDocument(root: mergeNode(base: base.root, local: local.root, remote: remote.root))
        document.ensureStableBlockIDs()
        return document
    }

    private static func mergeNode(base: BlockNode, local: BlockNode, remote: BlockNode) -> BlockNode {
        if semanticallyEqual(local, base) { return remote }
        if semanticallyEqual(remote, base) { return local }
        if semanticallyEqual(local, remote) { return local }

        var merged = remote
        merged.type = mergeValue(base: base.type, local: local.type, remote: remote.type)
        merged.data = mergeData(base: base.data, local: local.data, remote: remote.data)
        merged.children = mergeChildren(
            base: base.children,
            local: local.children,
            remote: remote.children
        )
        return merged
    }

    private static func mergeChildren(
        base: [BlockNode],
        local: [BlockNode],
        remote: [BlockNode]
    ) -> [BlockNode] {
        if semanticallyEqual(local, base) { return remote }
        if semanticallyEqual(remote, base) { return local }

        let baseByID = nodeMap(base)
        let localByID = nodeMap(local)
        let remoteByID = nodeMap(remote)
        let allIDs = Set(baseByID.keys).union(localByID.keys).union(remoteByID.keys)
        var mergedByID: [String: BlockNode] = [:]

        for id in allIDs {
            switch (baseByID[id], localByID[id], remoteByID[id]) {
            case let (baseNode?, localNode?, remoteNode?):
                mergedByID[id] = mergeNode(base: baseNode, local: localNode, remote: remoteNode)
            case let (nil, localNode?, remoteNode?):
                mergedByID[id] = semanticallyEqual(localNode, remoteNode)
                    ? localNode
                    : mergeNode(base: localNode, local: localNode, remote: remoteNode)
            case (_?, nil, _?):
                // A missing local node is an intentional learner deletion. The
                // remote version remains recoverable in SQLite history, so do
                // not silently resurrect it when an agent edits concurrently.
                break
            case let (baseNode?, localNode?, nil):
                if !semanticallyEqual(localNode, baseNode) { mergedByID[id] = localNode }
            case let (nil, localNode?, nil):
                mergedByID[id] = localNode
            case let (nil, nil, remoteNode?):
                mergedByID[id] = remoteNode
            case (_, nil, nil):
                break
            }
        }

        let allowed = Set(mergedByID.keys)
        let baseOrder = base.map(stableKey)
        let localOrder = local.map(stableKey)
        let remoteOrder = remote.map(stableKey)
        let localReordered = relativeOrderChanged(base: baseOrder, variant: localOrder)
        let remoteReordered = relativeOrderChanged(base: baseOrder, variant: remoteOrder)
        let primary = localReordered || !remoteReordered ? localOrder : remoteOrder
        let secondary = primary == localOrder ? remoteOrder : localOrder
        let order = insertingMissingIDs(from: secondary, into: primary.filter(allowed.contains), allowed: allowed)
        return order.compactMap { mergedByID[$0] }
    }

    private static func mergeData(
        base: [String: JSONValue],
        local: [String: JSONValue],
        remote: [String: JSONValue]
    ) -> [String: JSONValue] {
        var merged: [String: JSONValue] = [:]
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let value = mergeOptionalValue(base: base[key], local: local[key], remote: remote[key])
            if let value { merged[key] = value }
        }
        return merged
    }

    private static func mergeValue<T: Equatable>(base: T, local: T, remote: T) -> T {
        if local == base { return remote }
        if remote == base { return local }
        return local
    }

    private static func mergeOptionalValue<T: Equatable>(base: T?, local: T?, remote: T?) -> T? {
        if local == base { return remote }
        if remote == base { return local }
        return local
    }

    private static func semanticallyEqual(_ lhs: [BlockNode], _ rhs: [BlockNode]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(semanticallyEqual)
    }

    private static func semanticallyEqual(_ lhs: BlockNode, _ rhs: BlockNode) -> Bool {
        lhs.type == rhs.type
            && lhs.data == rhs.data
            && semanticallyEqual(lhs.children, rhs.children)
    }

    private static func nodeMap(_ nodes: [BlockNode]) -> [String: BlockNode] {
        Dictionary(nodes.map { (stableKey($0), $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func stableKey(_ node: BlockNode) -> String {
        node.stableBlockID ?? "runtime:\(node.id.uuidString.lowercased())"
    }

    private static func relativeOrderChanged(base: [String], variant: [String]) -> Bool {
        let common = Set(base).intersection(variant)
        return base.filter(common.contains) != variant.filter(common.contains)
    }

    private static func insertingMissingIDs(
        from secondary: [String],
        into primary: [String],
        allowed: Set<String>
    ) -> [String] {
        var result = primary
        for (index, id) in secondary.enumerated() where allowed.contains(id) && !result.contains(id) {
            if let preceding = secondary[..<index].last(where: result.contains),
               let insertionIndex = result.firstIndex(of: preceding) {
                result.insert(id, at: result.index(after: insertionIndex))
            } else if let following = secondary[(index + 1)...].first(where: result.contains),
                      let insertionIndex = result.firstIndex(of: following) {
                result.insert(id, at: insertionIndex)
            } else {
                result.append(id)
            }
        }
        return result
    }
}

private enum LegacyCoursePageImporter {
    private struct Metadata: Decodable {
        var planID: String?
        var title: String?
        var learningPath: [CourseLearningNode]?

        private enum CodingKeys: String, CodingKey {
            case planID = "plan_id"
            case title
            case learningPath = "learning_path"
        }
    }

    static func makeSeedWorkspace(
        workspaceID: String,
        rootTitle: String,
        courseRoot: URL
    ) -> PageWorkspace {
        let metadata = decodeMetadata(at: courseRoot.appendingPathComponent("course.json"))
        var rootDocument = document(at: courseRoot.appendingPathComponent("index.md")) ?? .blank()
        applyMetadata(
            to: &rootDocument,
            nodeID: metadata?.planID ?? workspaceID,
            role: "course",
            generationStatus: nil,
            bootstrapStatus: "ready_for_learning"
        )
        var workspace = PageWorkspace(rootPage: PageRecord(
            title: metadata?.title ?? rootTitle,
            icon: "books.vertical.fill",
            document: rootDocument
        ))

        importContextPages(into: &workspace, courseRoot: courseRoot)
        if let learningPath = metadata?.learningPath, !learningPath.isEmpty {
            for node in learningPath {
                importLearningNode(node, parentID: workspace.rootPageID, depth: 0, into: &workspace, courseRoot: courseRoot)
            }
        } else {
            importLegacyChapterFolders(into: &workspace, courseRoot: courseRoot)
        }
        return workspace
    }

    private static func decodeMetadata(at url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func importContextPages(into workspace: inout PageWorkspace, courseRoot: URL) {
        let contextDirectory = courseRoot.appendingPathComponent("context", isDirectory: true)
        for url in markdownFiles(in: contextDirectory) {
            let title = displayTitle(for: url)
            addPage(
                title: title,
                parentID: workspace.rootPageID,
                document: document(at: url) ?? .blank(),
                nodeID: "context-\(slug(url.deletingPathExtension().lastPathComponent))",
                role: "context",
                status: .generated,
                into: &workspace
            )
        }

        let agentNotesURL = courseRoot.appendingPathComponent(".course/agent-notes.md")
        if let notes = document(at: agentNotesURL) {
            addPage(
                title: "Agent notes",
                parentID: workspace.rootPageID,
                document: notes,
                nodeID: "agent-notes",
                role: "agent_notes",
                status: .generated,
                into: &workspace
            )
        }
    }

    private static func importLearningNode(
        _ node: CourseLearningNode,
        parentID: String,
        depth: Int,
        into workspace: inout PageWorkspace,
        courseRoot: URL
    ) {
        let pageDocument = node.relativePath
            .flatMap { document(at: courseRoot.appendingPathComponent($0)) }
            ?? headingDocument(node.title)
        let role: String
        if let explicitRole = node.role {
            role = explicitRole.rawValue
        } else {
            switch node.kind {
            case .folder: role = depth == 0 ? "chapter" : "subchapter"
            case .markdown: role = "lesson"
            }
        }
        guard let page = addPage(
            title: node.title,
            parentID: parentID,
            document: pageDocument,
            nodeID: node.id,
            role: role,
            status: node.status,
            into: &workspace
        ) else { return }
        for child in node.children {
            importLearningNode(child, parentID: page.id, depth: depth + 1, into: &workspace, courseRoot: courseRoot)
        }
    }

    private static func importLegacyChapterFolders(into workspace: inout PageWorkspace, courseRoot: URL) {
        let chaptersDirectory = courseRoot.appendingPathComponent("chapters", isDirectory: true)
        guard let chapterURLs = try? FileManager.default.contentsOfDirectory(
            at: chaptersDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for chapterURL in chapterURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? chapterURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            importDirectoryPage(
                chapterURL,
                parentID: workspace.rootPageID,
                depth: 0,
                into: &workspace
            )
        }
    }

    private static func importDirectoryPage(
        _ directory: URL,
        parentID: String,
        depth: Int,
        into workspace: inout PageWorkspace
    ) {
        let readme = directory.appendingPathComponent("README.md")
        guard let page = addPage(
            title: displayTitle(for: directory),
            parentID: parentID,
            document: document(at: readme) ?? headingDocument(displayTitle(for: directory)),
            nodeID: "legacy-\(slug(directory.lastPathComponent))",
            role: depth == 0 ? "chapter" : "subchapter",
            status: .generated,
            into: &workspace
        ) else { return }

        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                importDirectoryPage(child, parentID: page.id, depth: depth + 1, into: &workspace)
            } else if child.pathExtension.lowercased() == "md", child.lastPathComponent.lowercased() != "readme.md" {
                _ = addPage(
                    title: displayTitle(for: child),
                    parentID: page.id,
                    document: document(at: child) ?? .blank(),
                    nodeID: "legacy-\(slug(child.deletingPathExtension().lastPathComponent))",
                    role: "lesson",
                    status: .generated,
                    into: &workspace
                )
            }
        }
    }

    @discardableResult
    private static func addPage(
        title: String,
        parentID: String,
        document sourceDocument: BlockDocument,
        nodeID: String,
        role: String,
        status: CourseLearningNode.GenerationStatus,
        into workspace: inout PageWorkspace
    ) -> PageRecord? {
        var pageDocument = sourceDocument
        applyMetadata(
            to: &pageDocument,
            nodeID: nodeID,
            role: role,
            generationStatus: status.rawValue,
            bootstrapStatus: nil
        )
        guard let page = try? workspace.createPage(
            title: title,
            parentID: parentID,
            icon: role == "chapter" || role == "subchapter" ? "folder.fill" : "doc.text",
            document: pageDocument
        ) else { return nil }
        if var parentDocument = workspace.page(id: parentID)?.document {
            parentDocument.root.children.append(.childPage(pageID: page.id, title: page.title, icon: page.icon))
            try? workspace.saveDocument(parentDocument, for: parentID)
        }
        return page
    }

    private static func applyMetadata(
        to document: inout BlockDocument,
        nodeID: String,
        role: String,
        generationStatus: String?,
        bootstrapStatus: String?
    ) {
        document.root.data["course_node_id"] = .string(nodeID)
        document.root.data["course_role"] = .string(role)
        if let generationStatus {
            document.root.data["course_generation_status"] = .string(generationStatus)
        }
        if let bootstrapStatus {
            document.root.data["course_bootstrap_status"] = .string(bootstrapStatus)
        }
        document.ensureStableBlockIDs()
    }

    private static func document(at url: URL) -> BlockDocument? {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (try? AppFlowyMarkdownCodec().decode(markdown))
            ?? BlockDocument(root: BlockNode(type: "page", children: [.paragraph(markdown)]))
    }

    private static func headingDocument(_ title: String) -> BlockDocument {
        BlockDocument(root: BlockNode(type: "page", children: [.heading(title, level: 1)]))
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func displayTitle(for url: URL) -> String {
        let stem = url.hasDirectoryPath ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let withoutOrder = stem.replacingOccurrences(of: #"^\d+[-_ ]*"#, with: "", options: .regularExpression)
        return withoutOrder
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

actor CourseDocumentRegistry {
    static let shared = CourseDocumentRegistry()

    private struct OpeningRepository: Sendable {
        let id: UUID
        let task: Task<CourseDocumentRepository, Error>
    }

    private var repositories: [String: CourseDocumentRepository] = [:]
    private var openingRepositories: [String: OpeningRepository] = [:]
    private var workspaceByThreadID: [String: String] = [:]

    func repository(
        workspaceID: String,
        databaseURL: URL,
        rootTitle: String
    ) async throws -> CourseDocumentRepository {
        if let existing = repositories[workspaceID] { return existing }
        let opening: OpeningRepository
        if let existing = openingRepositories[workspaceID] {
            opening = existing
        } else {
            let id = UUID()
            let task = Task {
                try await CourseDocumentRepository.open(
                    workspaceID: workspaceID,
                    databaseURL: databaseURL,
                    rootTitle: rootTitle
                )
            }
            opening = OpeningRepository(id: id, task: task)
            openingRepositories[workspaceID] = opening
        }

        do {
            let repository = try await opening.task.value
            if openingRepositories[workspaceID]?.id == opening.id {
                openingRepositories.removeValue(forKey: workspaceID)
                repositories[workspaceID] = repository
            }
            return repositories[workspaceID] ?? repository
        } catch {
            if openingRepositories[workspaceID]?.id == opening.id {
                openingRepositories.removeValue(forKey: workspaceID)
            }
            throw error
        }
    }

    func register(threadID: String, workspaceID: String) {
        workspaceByThreadID[threadID] = workspaceID
    }

    func openRepositories() -> [CourseDocumentRepository] {
        Array(repositories.values)
    }

    func handle(
        threadID: String,
        tool: String,
        argumentsJSON: String
    ) async -> NativeEditorMCPToolResult? {
        guard let workspaceID = workspaceByThreadID[threadID],
              let repository = repositories[workspaceID] else { return nil }
        return await repository.callTool(named: tool, argumentsJSON: argumentsJSON)
    }

    func handle(
        workspaceID: String,
        tool: String,
        argumentsJSON: String
    ) async -> NativeEditorMCPToolResult? {
        guard let repository = repositories[workspaceID] else { return nil }
        return await repository.callTool(named: tool, argumentsJSON: argumentsJSON)
    }

    func executeCourseBash(
        threadID: String,
        argumentsJSON: String
    ) async -> AppPlatformDynamicToolResult? {
        guard let workspaceID = workspaceByThreadID[threadID],
              let repository = repositories[workspaceID] else { return nil }
        return await repository.executeCourseBash(argumentsJSON: argumentsJSON)
    }

    func presentPlan(
        threadID: String,
        argumentsJSON: String
    ) async -> AppPlatformDynamicToolResult? {
        guard let workspaceID = workspaceByThreadID[threadID],
              let repository = repositories[workspaceID],
              let data = argumentsJSON.data(using: .utf8),
              let plan = try? JSONDecoder().decode(CourseBrief.self, from: data) else {
            return AppPlatformDynamicToolResult(
                success: false,
                output: "present_course_plan requires a valid complete plan for the registered course thread."
            )
        }
        do {
            try await repository.presentPlan(plan)
            return AppPlatformDynamicToolResult(
                success: true,
                output: "Course plan revision \(plan.revision) is ready for learner review."
            )
        } catch {
            return AppPlatformDynamicToolResult(
                success: false,
                output: error.localizedDescription
            )
        }
    }

    /// Persists the proposal through the same repository actor that owns
    /// approval authorization. Returning false means this capability is no
    /// longer connected to a live course repository and must fail closed.
    func presentPlan(workspaceID: String, plan: CourseBrief) async throws -> Bool {
        guard let repository = repositories[workspaceID] else { return false }
        try await repository.presentPlan(plan)
        return true
    }
}

private extension CourseDocumentRepository {
    func executeCourseBash(argumentsJSON: String) async -> AppPlatformDynamicToolResult {
        do {
            guard let data = argumentsJSON.data(using: .utf8),
                  let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  arguments[CourseAgentTools.workspaceIDArgument] as? String == workspaceID,
                  let script = arguments["script"] as? String else {
                return AppPlatformDynamicToolResult(
                    success: false,
                    output: "course_bash requires the registered course's exact workspace_id and a non-empty script."
                )
            }
            let timeout = (arguments["timeout_seconds"] as? NSNumber)?.intValue
            let execution = try await CourseBashTool.execute(
                workspaceID: workspaceID,
                workspaceURL: courseRoot,
                script: script,
                timeoutSeconds: timeout
            )
            var object = execution.jsonObject
            if execution.exitCode != 0 {
                object["warning"] = "The command exited nonzero but may have partially modified the course. Inspect the workspace before retrying."
            }
            let output = String(
                decoding: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                ),
                as: UTF8.self
            )
            return AppPlatformDynamicToolResult(
                success: execution.exitCode == 0,
                output: output
            )
        } catch {
            return AppPlatformDynamicToolResult(
                success: false,
                output: error.localizedDescription
            )
        }
    }
}

private final class CourseToolResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppPlatformDynamicToolResult?

    func store(_ result: AppPlatformDynamicToolResult?) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> AppPlatformDynamicToolResult? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class CourseDocumentToolRouter: PlatformDynamicToolHandler, @unchecked Sendable {
    static let shared = CourseDocumentToolRouter()

    private let courseBashFlightLock = NSLock()
    private var courseBashInFlight = false

    func handleDynamicTool(
        invocation: AppPlatformDynamicToolInvocation
    ) -> AppPlatformDynamicToolResult? {
        let isCourseBash = invocation.tool == CourseAgentTools.courseBash
        let isCoursePlan = invocation.tool == CourseAgentTools.presentPlan
        guard isCourseBash
                || isCoursePlan
                || NativeEditorMCPToolCatalog.tools.contains(where: { $0.name == invocation.tool }) else {
            return nil
        }
        if isCourseBash {
            courseBashFlightLock.lock()
            guard !courseBashInFlight else {
                courseBashFlightLock.unlock()
                return AppPlatformDynamicToolResult(
                    success: false,
                    output: "Another phone-side course_bash call is already running. Wait for its result before retrying."
                )
            }
            courseBashInFlight = true
            courseBashFlightLock.unlock()
        }
        defer {
            if isCourseBash {
                courseBashFlightLock.lock()
                courseBashInFlight = false
                courseBashFlightLock.unlock()
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let box = CourseToolResultBox()
        Task {
            defer { semaphore.signal() }
            guard !Task.isCancelled else { return }
            let encoded: AppPlatformDynamicToolResult?
            if isCourseBash {
                encoded = await CourseDocumentRegistry.shared.executeCourseBash(
                    threadID: invocation.threadId,
                    argumentsJSON: invocation.argumentsJson
                )
            } else if isCoursePlan {
                encoded = await CourseDocumentRegistry.shared.presentPlan(
                    threadID: invocation.threadId,
                    argumentsJSON: invocation.argumentsJson
                )
            } else {
                let result = await CourseDocumentRegistry.shared.handle(
                    threadID: invocation.threadId,
                    tool: invocation.tool,
                    argumentsJSON: invocation.argumentsJson
                )
                encoded = result.flatMap { result -> AppPlatformDynamicToolResult? in
                    guard let data = try? JSONEncoder().encode(result.value),
                          let output = String(data: data, encoding: .utf8) else { return nil }
                    return AppPlatformDynamicToolResult(success: !result.isError, output: output)
                }
            }
            guard !Task.isCancelled else { return }
            box.store(encoded)
        }

        // The callback boundary is synchronous, but returning a timeout while
        // this task can still commit would turn an unknown outcome into a
        // terminal failure and invite a duplicate retry. Wait for the native
        // transaction's authoritative result instead.
        semaphore.wait()
        return box.load()
    }
}

@MainActor
@Observable
final class CoursePageEditorModel {
    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)

        var accessibilityValue: String {
            switch self {
            case .idle:
                "No pending changes"
            case .saving:
                "Saving changes"
            case .saved:
                "Changes saved"
            case .failed:
                "Changes not saved"
            }
        }

        var failureMessage: String? {
            guard case let .failed(message) = self else { return nil }
            return message
        }

        var canRetry: Bool {
            if case .failed = self { return true }
            return false
        }

#if DEBUG
        /// Stable, content-free state used by the product-attached editor
        /// runtime probe. Keep this separate from the localized accessibility
        /// copy rendered by the save-status view.
        var runtimeProbeValue: String {
            switch self {
            case .idle:
                "idle"
            case .saving:
                "saving"
            case .saved:
                "saved"
            case .failed:
                "failed"
            }
        }
#endif
    }

    var title = "Course page"
    var document = BlockDocument.blank()
    var isLoading = true
    var errorMessage: String?
    var saveState = SaveState.idle
    var pageTitles: [String: String] = [:]

    let pageID: String
    private let repository: CourseDocumentRepository
    private let stagingDelay: Duration?
    private var confirmedDocument: BlockDocument?
    private var confirmedRevision: Int64?
    private var latestEditID: UUID?
    private var latestStagedEditID: UUID?
    private var stagedSaveTask: Task<Void, Never>?
    private var saveOperationGeneration = 0
    @ObservationIgnored
    nonisolated(unsafe) private var changesTask: Task<Void, Never>?

    init(
        pageID: String,
        repository: CourseDocumentRepository,
        stagingDelay: Duration? = nil
    ) {
        self.pageID = pageID
        self.repository = repository
        self.stagingDelay = stagingDelay
    }

    deinit {
        changesTask?.cancel()
    }

    func load() async {
        // Register the stream first. AsyncStream buffers any mutation that
        // lands while initial hydration is awaiting SQLite, closing the gap
        // where a change could previously occur before the observer existed.
        if changesTask == nil {
            let stream = await repository.changes()
            changesTask = Task { [weak self] in
                for await change in stream {
                    guard !Task.isCancelled else { return }
                    if change.pageID == nil || change.pageID == self?.pageID {
                        if let errorMessage = change.errorMessage {
                            self?.recordSaveFailure(errorMessage)
                        } else if let snapshot = change.snapshot {
                            guard let self else { return }
                            let completesLatestEdit = change.sourceEditID != nil
                                && change.sourceEditID == self.latestEditID
                                && !change.hasPendingUserEdit
                            let canAdoptSnapshot = self.latestEditID == nil || completesLatestEdit
                            self.apply(
                                snapshot,
                                replacingDocument: canAdoptSnapshot
                                    && (change.replacesDocument
                                        || !CourseDocumentThreeWayMerger.semanticallyEqual(
                                            self.document,
                                            snapshot.document
                                        ))
                            )
                            if completesLatestEdit {
                                self.latestEditID = nil
                                self.latestStagedEditID = nil
                                self.errorMessage = nil
                                self.saveState = .saved
                            }
                        } else {
                            guard let self else { return }
                            // An external mutation may publish before the latest
                            // keystroke's staging task reaches the repository. The
                            // captured base will reconcile it once staged, so never
                            // overwrite the visible editor during that gap.
                            guard self.latestEditID == self.latestStagedEditID else { continue }
                            await self.reload()
                        }
                    }
                }
            }
        }
        await reload()
    }

    func userChangedDocument(_ updated: BlockDocument) {
        document = updated
        let editID = UUID()
        latestEditID = editID
        errorMessage = nil
        saveState = .saving
        let previous = stagedSaveTask
        let repository = repository
        let pageID = pageID
        let capturedBaseDocument = confirmedDocument
        let capturedBaseRevision = confirmedRevision
        let stagingDelay = stagingDelay
        stagedSaveTask = Task { [weak self] in
            await previous?.value
            if let stagingDelay {
                try? await Task.sleep(for: stagingDelay)
            }
            do {
                try await repository.stageUserEdit(
                    pageID: pageID,
                    document: updated,
                    capturedBaseDocument: capturedBaseDocument,
                    capturedBaseRevision: capturedBaseRevision,
                    sourceEditID: editID
                )
            } catch {
                guard self?.latestEditID == editID else { return }
                self?.recordSaveFailure(error.localizedDescription)
            }
            if self?.latestEditID == editID {
                self?.latestStagedEditID = editID
            }
        }
    }

    func flush() async {
        saveOperationGeneration &+= 1
        let operationGeneration = saveOperationGeneration
        if latestEditID != nil || saveState.canRetry {
            errorMessage = nil
            saveState = .saving
        }

        while true {
            guard operationGeneration == saveOperationGeneration else { return }
            let targetEditID = latestEditID
            let targetStagingTask = stagedSaveTask
            await targetStagingTask?.value
            guard operationGeneration == saveOperationGeneration else { return }
            do {
                let snapshots = try await repository.flushPendingUserEdits()
                // A newer edit may enter while either await is suspended. Do
                // not adopt an older snapshot or clear its identity; include
                // the new staging task in another pass instead.
                guard operationGeneration == saveOperationGeneration else { return }
                guard latestEditID == targetEditID else { continue }
                if let snapshot = snapshots.last(where: { $0.id == pageID }) {
                    apply(snapshot, replacingDocument: true)
                }
                latestEditID = nil
                latestStagedEditID = nil
                errorMessage = nil
                if targetEditID != nil || saveState != .idle {
                    saveState = .saved
                }
                return
            } catch {
                guard operationGeneration == saveOperationGeneration else { return }
                // A later keystroke owns the visible save state. Retry the
                // repository's requeued batch plus that newer edit in this
                // operation instead of surfacing the older failure.
                guard latestEditID == targetEditID else { continue }
                recordSaveFailure(error.localizedDescription)
                return
            }
        }
    }

    func retrySave() async {
        guard saveState.canRetry else { return }
        await flush()
    }

    private func reload() async {
        let targetEditID = latestEditID
        do {
            let snapshot = try await repository.pageSnapshot(id: pageID)
            let workspace = try await repository.workspaceSnapshot()
            // Loading and external refreshes suspend on repository I/O. If a
            // keystroke entered meanwhile, its captured base must remain in
            // charge; adopting this older snapshot would erase visible input.
            if latestEditID == targetEditID {
                apply(snapshot, replacingDocument: true)
                latestEditID = nil
                latestStagedEditID = nil
            }
            pageTitles = workspace.pages.mapValues(\.title)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(_ snapshot: NativeEditorPageSnapshot, replacingDocument: Bool) {
        title = snapshot.title
        confirmedDocument = snapshot.document
        confirmedRevision = snapshot.revision
        if replacingDocument, document != snapshot.document {
            document = snapshot.document
        }
        errorMessage = nil
    }

    private func recordSaveFailure(_ message: String) {
        errorMessage = message
        saveState = .failed(message)
    }

    func pageTitle(id: String) -> String? {
        pageTitles[id]
    }

#if DEBUG
    /// Read-only observability for the Debug runtime evidence layer. These
    /// values are projections of the real editor state; they do not provide a
    /// second mutation path or expose learner-authored document content.
    var runtimeProbeHasPendingEdit: Bool {
        latestEditID != nil || latestStagedEditID != nil || saveState.canRetry
    }

    var runtimeProbeConfirmedRevision: Int64? {
        confirmedRevision
    }
#endif
}
