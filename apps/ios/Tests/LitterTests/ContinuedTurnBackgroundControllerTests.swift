import BackgroundTasks
import XCTest
@testable import Litter

@MainActor
final class ContinuedTurnBackgroundControllerTests: XCTestCase {
    @available(iOS 26.0, *)
    private final class SchedulerSpy: ContinuedProcessingTaskScheduling {
        var registeredIdentifiers: [String] = []
        var submittedRequests: [BGTaskRequest] = []
        var cancelledIdentifiers: [String] = []
        var handlers: [(any ContinuedProcessingTaskHandling) -> Void] = []

        func register(
            identifier: String,
            handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
        ) -> Bool {
            registeredIdentifiers.append(identifier)
            handlers.append(handler)
            return true
        }

        func submit(_ request: BGTaskRequest) throws {
            submittedRequests.append(request)
        }

        func cancel(identifier: String) {
            cancelledIdentifiers.append(identifier)
        }
    }

    @available(iOS 26.0, *)
    private final class TaskSpy: ContinuedProcessingTaskHandling {
        let progress = Progress(totalUnitCount: 0)
        var expirationHandler: (() -> Void)?
        var titles: [(title: String, subtitle: String)] = []
        var completions: [Bool] = []

        func updateTitle(_ title: String, subtitle: String) {
            titles.append((title, subtitle))
        }

        func setTaskCompleted(success: Bool) {
            completions.append(success)
        }
    }

    func testSubmitsAndCancelsAUserInitiatedContinuedProcessingTask() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The freshly submitted test task should not expire") }
        )
        let key = ThreadKey(serverId: "background-test", threadId: UUID().uuidString)

        let token = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(agentName: "Codex", intent: .generic(title: "Background test")),
            keepsAliveAcrossTurns: false
        )

        XCTAssertNotNil(token)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.registeredIdentifiers.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        XCTAssertTrue(scheduler.registeredIdentifiers[0].hasPrefix("com.example.course.codex-turn."))

        if let token {
            controller.markTurnStartFailed(token)
        }
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.cancelledIdentifiers, scheduler.registeredIdentifiers)
    }

    func testHermesMultiTurnSessionReusesLeaseAcrossIdleAndClosesOnce() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        var snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )

        let firstToken = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: "Build a course")),
            keepsAliveAcrossTurns: true
        )
        XCTAssertNotNil(firstToken)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)

        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        if let firstToken {
            controller.markTurnAccepted(firstToken)
        }

        snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        controller.handleSnapshot(snapshot)
        snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        controller.handleSnapshot(snapshot)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [])

        let reusedToken = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: "Return a native tool result")),
            keepsAliveAcrossTurns: true
        )
        XCTAssertEqual(reusedToken, firstToken)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
        if let reusedToken {
            controller.markTurnStartFailed(reusedToken)
        }
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [])

        controller.finishMultiTurnSession(key: key, outcome: .completed)
        controller.finishMultiTurnSession(key: key, outcome: .completed)
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.titles.last?.title, "Hermes finished")
    }

    func testHermesMultiTurnExpirationClosesAndInterruptsExactlyOnce() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        let scheduler = SchedulerSpy()
        var expiredKeys: [ThreadKey] = []
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { self.makeSnapshot(key: key, hasActiveTurn: true) },
            onExpiration: { expiredKeys.append($0) }
        )
        _ = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: "Build a course")),
            keepsAliveAcrossTurns: true
        )
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        task.expirationHandler?()
        await Task.yield()
        task.expirationHandler?()
        await Task.yield()

        XCTAssertEqual(expiredKeys, [key])
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    func testAutomaticContinuationOnlyReusesAnExistingLease() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )

        XCTAssertNil(
            controller.reuseMultiTurnSessionIfPresent(key: key, agentName: "Hermes")
        )
        XCTAssertTrue(scheduler.registeredIdentifiers.isEmpty)
        XCTAssertTrue(scheduler.submittedRequests.isEmpty)

        let created = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: "Build a course")),
            keepsAliveAcrossTurns: true
        )
        let reused = controller.reuseMultiTurnSessionIfPresent(
            key: key,
            agentName: "Hermes"
        )
        XCTAssertEqual(reused, created)
        XCTAssertEqual(scheduler.registeredIdentifiers.count, 1)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
    }

    func testRequestUsesContextTitleAndGettingStarted() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { nil },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        _ = controller.beginUserInitiatedTurn(
            key: ThreadKey(serverId: "local", threadId: "lesson"),
            context: lessonContext,
            keepsAliveAcrossTurns: false
        )

        let request = try XCTUnwrap(scheduler.submittedRequests.first as? BGContinuedProcessingTaskRequest)
        XCTAssertEqual(request.title, "Writing “Light Reactions”")
        XCTAssertEqual(request.subtitle, "Getting started")
    }

    func testPresentationUsesCurrentActivity() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "exploration")
        let previousRequest = activity(.responding, isRunning: false)
        var snapshot = makeSnapshot(key: key, hasActiveTurn: false, activity: previousRequest)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        _ = controller.beginUserInitiatedTurn(
            key: key,
            context: ContinuedTurnContext(
                agentName: "Codex",
                intent: .exploreTopic(title: "Why leaves look green", pageID: "page-green"),
                pageTitlesByID: ["page-chlorophyll": "Chlorophyll basics"]
            ),
            keepsAliveAcrossTurns: false
        )
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        // Before the turn starts, the summary still describes the previous
        // request, so the submitted text stays.
        XCTAssertTrue(task.titles.isEmpty)

        snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: true,
            activity: activity(.readingCourse, pageId: "page-chlorophyll"),
            lastToolLabel: "MCP native-editor-fetch"
        )
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.titles.count, 1)
        XCTAssertEqual(task.titles.last?.title, "Exploring “Why leaves look green”")
        XCTAssertEqual(task.titles.last?.subtitle, "Reading “Chlorophyll basics”")
    }

    func testIdenticalSnapshotsDoNotRetitle() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        var clock: TimeInterval = 1_000
        let snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: true,
            activity: activity(.readingCourse, pageId: "page-light")
        )
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        XCTAssertEqual(task.titles.map { $0.subtitle }, ["Reading the current draft"])

        clock += 10
        controller.handleSnapshot(snapshot)
        clock += 10
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.titles.count, 1)
        XCTAssertGreaterThan(task.progress.completedUnitCount, 1)
    }

    func testPlanSnapshotsAreThrottled() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "generic")
        var clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: true,
            plan: plan([.inProgress, .pending, .pending])
        )
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: genericContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        XCTAssertEqual(task.titles.map { $0.subtitle }, ["Step 1 of 3 · Reproduce the flake"])

        clock += 0.5
        snapshot = makeSnapshot(key: key, hasActiveTurn: true, plan: plan([.completed, .inProgress, .pending]))
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.titles.count, 1)

        clock += 2
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.titles.map { $0.subtitle }, [
            "Step 1 of 3 · Reproduce the flake",
            "Step 2 of 3 · Add retry to token refresh",
        ])
    }

    func testNeedsApprovalBypassesThrottle() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "generic")
        let clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.runningCommand, subject: "make test"))
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: genericContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: true,
            activity: activity(.runningCommand, subject: "make test"),
            pendingApprovals: [
                PendingApproval(
                    id: "approval",
                    serverId: key.serverId,
                    kind: .command,
                    threadId: key.threadId,
                    turnId: "turn-active",
                    itemId: nil,
                    command: "make test",
                    path: nil,
                    grantRoot: nil,
                    cwd: nil,
                    reason: nil
                ),
                PendingApproval(
                    id: "other-thread",
                    serverId: key.serverId,
                    kind: .command,
                    threadId: "someone-else",
                    turnId: nil,
                    itemId: nil,
                    command: nil,
                    path: nil,
                    grantRoot: nil,
                    cwd: nil,
                    reason: nil
                ),
            ]
        )
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.titles.map { $0.subtitle }, ["Running make test", "Needs your approval"])
    }

    func testFailedOutcomeCompletesUnsuccessfullyWithFailureCopy() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.readingCourse, read: 1))
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: false,
            activity: activity(.thinking, isRunning: false, read: 1),
            outcome: .failed(message: "The model is overloaded")
        )
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(task.titles.last?.title, "Couldn’t finish “Light Reactions”")
        XCTAssertEqual(task.titles.last?.subtitle, "Open Learnfold to try again")
        XCTAssertLessThan(task.progress.fractionCompleted, 1)
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    func testCompletedLessonCopy() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        var snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: true,
            activity: activity(.writingCoursePage, pageId: "page-light", read: 2)
        )
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        XCTAssertEqual(task.titles.last?.subtitle, "Saving the lesson")

        snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: false,
            activity: activity(.responding, isRunning: false, read: 2, written: 1),
            outcome: .completed
        )
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.titles.last?.title, "“Light Reactions” is ready")
        XCTAssertEqual(task.titles.last?.subtitle, "Open Learnfold to start the lesson")
        XCTAssertEqual(task.progress.fractionCompleted, 1)
    }

    func testMissingOutcomeIsTreatedAsCompletedAfterTheGrace() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "generic")
        var clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: genericContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        controller.handleSnapshot(snapshot)
        clock += 1
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.completions, [])
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)

        clock += ContinuedTurnBackgroundController.outcomeGrace
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(task.titles.last?.title, "Codex finished")
        XCTAssertEqual(task.titles.last?.subtitle, "Fix flaky login test")
    }

    /// Upstream marks the thread idle before turn/completed reports the
    /// failure; the idle gap must not read as a clean finish.
    func testIdleBeforeFailedOutcomeCompletesUnsuccessfully() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        var clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.readingCourse, read: 1))
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(key: key, hasActiveTurn: false, activity: activity(.thinking, isRunning: false, read: 1))
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.completions, [])

        clock += 0.2
        snapshot = makeSnapshot(
            key: key,
            hasActiveTurn: false,
            activity: activity(.thinking, isRunning: false, read: 1),
            outcome: .failed(message: "Model overloaded")
        )
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(task.titles.last?.title, "Couldn’t finish “Light Reactions”")
        XCTAssertEqual(task.titles.last?.subtitle, "Open Learnfold to try again")
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    func testTurnRestartingDuringTheGraceKeepsTheTaskRunning() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "generic")
        var clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: genericContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        let idle = makeSnapshot(key: key, hasActiveTurn: false)
        controller.handleSnapshot(idle)
        clock += 2
        snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        controller.handleSnapshot(snapshot)
        clock += 2
        controller.handleSnapshot(idle)
        XCTAssertEqual(task.completions, [], "the grace restarts with each idle period")

        clock += ContinuedTurnBackgroundController.outcomeGrace
        controller.handleSnapshot(idle)
        XCTAssertEqual(task.completions, [true])
    }

    func testInterruptedOutcomeShowsStoppedCopy() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(key: key, hasActiveTurn: false, outcome: .interrupted)
        controller.handleSnapshot(snapshot)

        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(task.titles.last?.title, "Stopped “Light Reactions”")
        XCTAssertEqual(task.titles.last?.subtitle, "Pick it up again in Learnfold")
    }

    func testExpirationDoesNotRetitle() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "local", threadId: "lesson")
        let snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.readingCourse, pageId: "page-light"))
        let scheduler = SchedulerSpy()
        var expiredKeys: [ThreadKey] = []
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { expiredKeys.append($0) }
        )
        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: false)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        let titlesBeforeExpiration = task.titles.count

        task.expirationHandler?()
        await Task.yield()

        XCTAssertEqual(expiredKeys, [key])
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(task.titles.count, titlesBeforeExpiration)
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    func testHermesReuseKeepsContext() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        var clock: TimeInterval = 1_000
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.readingCourseOutline))
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") },
            now: { clock }
        )
        let courseChat = ContinuedTurnContext(agentName: "Hermes", intent: .courseChat(courseTitle: "Photosynthesis"))
        let token = controller.beginUserInitiatedTurn(key: key, context: courseChat, keepsAliveAcrossTurns: true)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()
        XCTAssertEqual(task.titles.last?.title, "Working on “Photosynthesis”")

        // Tool-result continuations reuse the lease without renaming it, and a
        // begin while the turn is active keeps the first context.
        XCTAssertEqual(controller.reuseMultiTurnSessionIfPresent(key: key, agentName: "Hermes"), token)
        XCTAssertEqual(
            controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: true),
            token
        )
        clock += 5
        snapshot = makeSnapshot(key: key, hasActiveTurn: true, activity: activity(.searchingCourse, subject: "Calvin cycle"))
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.titles.last?.title, "Working on “Photosynthesis”")
        XCTAssertEqual(task.titles.last?.subtitle, "Searching for “Calvin cycle”")

        // An idle gap between tool round trips keeps the last text.
        clock += 5
        let titlesBeforeIdle = task.titles.count
        snapshot = makeSnapshot(key: key, hasActiveTurn: false, activity: activity(.responding, isRunning: false))
        controller.handleSnapshot(snapshot)
        XCTAssertEqual(task.titles.count, titlesBeforeIdle)
        XCTAssertTrue(controller.hasScheduledOrRunningTasks)
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
    }

    func testNewLearnerRequestOnIdleHermesLeaseRenamesTask() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        var snapshot = makeSnapshot(key: key, hasActiveTurn: true)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )
        let courseChat = ContinuedTurnContext(agentName: "Hermes", intent: .courseChat(courseTitle: "Photosynthesis"))
        let token = controller.beginUserInitiatedTurn(key: key, context: courseChat, keepsAliveAcrossTurns: true)
        let task = TaskSpy()
        scheduler.handlers[0](task)
        await Task.yield()

        snapshot = makeSnapshot(key: key, hasActiveTurn: false)
        controller.handleSnapshot(snapshot)
        let question = ContinuedTurnContext(agentName: "Hermes", intent: .answerQuestion(pageTitle: "Light"))
        XCTAssertEqual(
            controller.beginUserInitiatedTurn(key: key, context: question, keepsAliveAcrossTurns: true),
            token
        )

        XCTAssertEqual(task.titles.last?.title, "Answering about “Light”")
        XCTAssertEqual(task.titles.last?.subtitle, "Getting started")
        XCTAssertEqual(scheduler.submittedRequests.count, 1)

        controller.finishMultiTurnSession(key: key, outcome: .completed)
        XCTAssertEqual(task.titles.last?.title, "Your answer is ready")
        XCTAssertEqual(task.completions, [true])
    }

    /// The caller says why a lease ended. The last Hermes turn completed in
    /// both cases; only a learner's stop reads as stopped.
    func testMultiTurnCloseUsesTheCallersOutcome() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("BGContinuedProcessingTask requires iOS 26")
        }

        let key = ThreadKey(serverId: "hermes-server", threadId: "hermes-thread")
        let snapshot = makeSnapshot(key: key, hasActiveTurn: false, outcome: .completed)
        let scheduler = SchedulerSpy()
        let controller = ContinuedTurnBackgroundController(
            scheduler: scheduler,
            bundleIdentifier: "com.example.course",
            snapshotProvider: { snapshot },
            onExpiration: { _ in XCTFail("The task should not expire") }
        )

        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: true)
        let stopped = TaskSpy()
        scheduler.handlers[0](stopped)
        await Task.yield()
        controller.finishMultiTurnSession(key: key, outcome: .interrupted)

        XCTAssertEqual(stopped.completions, [false])
        XCTAssertEqual(stopped.titles.last?.title, "Stopped “Light Reactions”")
        XCTAssertEqual(stopped.titles.last?.subtitle, "Pick it up again in Learnfold")

        _ = controller.beginUserInitiatedTurn(key: key, context: lessonContext, keepsAliveAcrossTurns: true)
        let failed = TaskSpy()
        scheduler.handlers[1](failed)
        await Task.yield()
        controller.finishMultiTurnSession(key: key, outcome: .failed(message: "Malformed tool call"))

        XCTAssertEqual(failed.completions, [false])
        XCTAssertEqual(failed.titles.last?.title, "Couldn’t finish “Light Reactions”")
        XCTAssertEqual(failed.titles.last?.subtitle, "Open Learnfold to try again")
        XCTAssertFalse(controller.hasScheduledOrRunningTasks)
    }

    // MARK: - Factories

    private let lessonContext = ContinuedTurnContext(
        agentName: "Codex",
        intent: .writeLesson(title: "Light Reactions", pageID: "page-light")
    )
    private let genericContext = ContinuedTurnContext(
        agentName: "Codex",
        intent: .generic(title: "Fix flaky login test")
    )

    private func activity(
        _ kind: AppTurnActivityKind,
        subject: String? = nil,
        pageId: String? = nil,
        isRunning: Bool = true,
        read: UInt32 = 0,
        written: UInt32 = 0
    ) -> AppTurnActivity {
        AppTurnActivity(
            kind: kind,
            subject: subject,
            pageId: pageId,
            isRunning: isRunning,
            unitCount: 0,
            stepCount: 1,
            coursePagesRead: read,
            coursePagesWritten: written
        )
    }

    private func plan(_ statuses: [AppPlanStepStatus]) -> AppPlanProgressSnapshot {
        let names = ["Reproduce the flake", "Add retry to token refresh", "Run the login suite"]
        return AppPlanProgressSnapshot(
            turnId: "turn-active",
            explanation: nil,
            plan: statuses.enumerated().map { index, status in
                AppPlanStep(step: names[index], status: status)
            }
        )
    }

    private func makeSummary(
        key: ThreadKey,
        hasActiveTurn: Bool,
        activity: AppTurnActivity?,
        outcome: TurnOutcome?,
        lastToolLabel: String?
    ) -> AppSessionSummary {
        AppSessionSummary(
            key: key,
            agentRuntimeKind: "codex",
            serverDisplayName: key.serverId,
            serverHost: "\(key.serverId).local",
            title: "Course thread",
            preview: "",
            cwd: "/__learnfold_device_owned__/workspace",
            model: "",
            modelProvider: "",
            parentThreadId: nil,
            forkedFromId: nil,
            agentNickname: nil,
            agentRole: nil,
            agentDisplayLabel: nil,
            agentStatus: .unknown,
            updatedAt: nil,
            hasActiveTurn: hasActiveTurn,
            isResumed: false,
            isSubagent: false,
            isFork: false,
            lastResponsePreview: nil,
            lastResponseTurnId: nil,
            lastUserMessage: nil,
            lastToolLabel: lastToolLabel,
            recentToolLog: [],
            lastTurnStartMs: nil,
            lastTurnEndMs: nil,
            stats: nil,
            tokenUsage: nil,
            goal: nil,
            currentActivity: activity,
            lastTurnOutcome: outcome
        )
    }

    private func makeSnapshot(
        key: ThreadKey,
        hasActiveTurn: Bool,
        activity: AppTurnActivity? = nil,
        outcome: TurnOutcome? = nil,
        plan: AppPlanProgressSnapshot? = nil,
        lastToolLabel: String? = nil,
        pendingApprovals: [PendingApproval] = []
    ) -> AppSnapshotRecord {
        let thread = AppThreadSnapshot(
            key: key,
            info: ThreadInfo(
                id: key.threadId,
                title: "Hermes course",
                model: nil,
                status: hasActiveTurn ? .active : .idle,
                preview: "",
                cwd: "/__learnfold_device_owned__/workspace",
                path: nil,
                modelProvider: nil,
                agentNickname: nil,
                agentRole: nil,
                parentThreadId: nil,
                forkedFromId: nil,
                agentStatus: nil,
                createdAt: nil,
                updatedAt: nil
            ),
            agentRuntimeKind: "hermes",
            collaborationMode: .default,
            model: nil,
            reasoningEffort: nil,
            effectiveApprovalPolicy: nil,
            effectiveSandboxPolicy: nil,
            hydratedConversationItems: [],
            queuedFollowUps: [],
            activeTurnId: hasActiveTurn ? "turn-active" : nil,
            activePlanProgress: plan,
            pendingPlanImplementationPrompt: nil,
            contextTokensUsed: nil,
            modelContextWindow: nil,
            rateLimits: nil,
            realtimeSessionId: nil,
            goal: nil,
            stats: nil,
            tokenUsage: nil,
            olderTurnsCursor: nil,
            initialTurnsLoaded: true
        )
        let summary = makeSummary(
            key: key,
            hasActiveTurn: hasActiveTurn,
            activity: activity,
            outcome: outcome,
            lastToolLabel: lastToolLabel
        )
        return AppSnapshotRecord(
            servers: [],
            threads: [thread],
            sessionSummaries: [summary],
            agentDirectoryVersion: 0,
            activeThread: nil,
            pendingApprovals: pendingApprovals,
            pendingUserInputs: [],
            voiceSession: AppVoiceSessionSnapshot(
                activeThread: nil,
                sessionId: nil,
                phase: nil,
                lastError: nil,
                transcriptEntries: [],
                handoffThreadKey: nil
            ),
            terminalSessions: [],
            activeTerminalId: nil
        )
    }
}
