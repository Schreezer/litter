import BackgroundTasks
import Foundation

@MainActor
protocol ContinuedTurnBackgroundControlling: AnyObject {
    var hasScheduledOrRunningTasks: Bool { get }

    func beginUserInitiatedTurn(
        key: ThreadKey,
        context: ContinuedTurnContext,
        keepsAliveAcrossTurns: Bool
    ) -> UUID?
    func markTurnAccepted(_ token: UUID)
    func markTurnStartFailed(_ token: UUID)
    func reuseMultiTurnSessionIfPresent(key: ThreadKey, agentName: String) -> UUID?
    func finishMultiTurnSession(key: ThreadKey, outcome: TurnOutcome)
    func handleSnapshot(_ snapshot: AppSnapshotRecord?)
}

@available(iOS 26.0, *)
protocol ContinuedProcessingTaskHandling: AnyObject {
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }

    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@available(iOS 26.0, *)
extension BGContinuedProcessingTask: ContinuedProcessingTaskHandling {}

@available(iOS 26.0, *)
protocol ContinuedProcessingTaskScheduling: AnyObject {
    func register(
        identifier: String,
        handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool
    func submit(_ request: BGTaskRequest) throws
    func cancel(identifier: String)
}

@available(iOS 26.0, *)
extension BGTaskScheduler: ContinuedProcessingTaskScheduling {
    func register(
        identifier: String,
        handler: @escaping (any ContinuedProcessingTaskHandling) -> Void
    ) -> Bool {
        register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handler(continuedTask)
        }
    }

    func cancel(identifier: String) {
        cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Keeps user-started Codex turns eligible for runtime after the app moves to
/// the background. `BGContinuedProcessingTask` is deliberately an iOS-only
/// projection: the Codex turn and its canonical state remain owned by Rust.
///
/// The system owns the task's Live Activity and cancellation affordance. When
/// it expires that task (including after a person cancels it), `onExpiration`
/// interrupts the matching Codex turn so the system UI and actual work agree.
///
/// The banner title names the caller's `ContinuedTurnContext`; the subtitle
/// follows Rust's typed `currentActivity`. The final banner and success flag
/// come from the summary's `lastTurnOutcome`. Upstream marks a thread idle
/// just before it reports how the turn ended, so an idle thread without an
/// outcome gets a short grace before its status is reported as unconfirmed.
@available(iOS 26.0, *)
@MainActor
final class ContinuedTurnBackgroundController: ContinuedTurnBackgroundControlling {
    private final class Session {
        let token: UUID
        let identifier: String
        let key: ThreadKey
        let initialAssistantItemID: String?
        var accepted = false
        var observedActiveTurn = false
        var backgroundTask: (any ContinuedProcessingTaskHandling)?
        var heartbeatTask: Task<Void, Never>?
        var context: ContinuedTurnContext
        var keepsAliveAcrossTurns: Bool
        var progress = ContinuedTurnProgress()
        var lastProgressUpdate = -TimeInterval.infinity
        /// What the system shows: the request's text until the first update.
        var lastBanner: ContinuedTurnBanner?
        var lastBannerAt = -TimeInterval.infinity
        /// The newest activity seen while the turn was active.
        var lastActivity: AppTurnActivity?
        /// When the thread was first seen idle without a turn outcome.
        var idleWithoutOutcomeSince: TimeInterval?
        var outcomeWaitTask: Task<Void, Never>?

        init(
            token: UUID,
            identifier: String,
            key: ThreadKey,
            initialAssistantItemID: String?,
            context: ContinuedTurnContext,
            keepsAliveAcrossTurns: Bool
        ) {
            self.token = token
            self.identifier = identifier
            self.key = key
            self.initialAssistantItemID = initialAssistantItemID
            self.context = context
            self.keepsAliveAcrossTurns = keepsAliveAcrossTurns
        }
    }

    /// Progress ticks and non-urgent banner changes are at least this far
    /// apart. "Needs you" and terminal banners skip the wait; the heartbeat
    /// applies anything that was skipped.
    private static let progressInterval: TimeInterval = 2
    private static let bannerInterval: TimeInterval = 2
    /// How long an idle thread may wait for its turn outcome before the task
    /// ends with an unconfirmed result.
    static let outcomeGrace: TimeInterval = 3

    private let scheduler: any ContinuedProcessingTaskScheduling
    private let bundleIdentifier: String
    private let snapshotProvider: () -> AppSnapshotRecord?
    private let onExpiration: (ThreadKey) -> Void
    /// Monotonic seconds, so a wall-clock change cannot freeze the throttles.
    private let now: () -> TimeInterval
    private var sessions: [UUID: Session] = [:]
    private var tokenByThreadKey: [ThreadKey: UUID] = [:]

    var hasScheduledOrRunningTasks: Bool {
        !sessions.isEmpty
    }

    init(
        scheduler: any ContinuedProcessingTaskScheduling = BGTaskScheduler.shared,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chirag.learnfold",
        snapshotProvider: @escaping () -> AppSnapshotRecord?,
        onExpiration: @escaping (ThreadKey) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.scheduler = scheduler
        self.bundleIdentifier = bundleIdentifier
        self.snapshotProvider = snapshotProvider
        self.onExpiration = onExpiration
        self.now = now
    }

    func beginUserInitiatedTurn(
        key: ThreadKey,
        context: ContinuedTurnContext,
        keepsAliveAcrossTurns: Bool
    ) -> UUID? {
        if let existingToken = tokenByThreadKey[key],
           let existing = sessions[existingToken] {
            existing.keepsAliveAcrossTurns = existing.keepsAliveAcrossTurns
                || keepsAliveAcrossTurns
            let threadIsIdle = snapshotProvider()?
                .threadSnapshot(for: key)?
                .hasActiveTurn != true
            if threadIsIdle {
                // A new learner request on a kept-alive lease (Hermes): the
                // banner now names that request. While a turn is active, the
                // first context wins.
                existing.context = context
                existing.lastActivity = nil
                if let task = existing.backgroundTask {
                    show(
                        ContinuedTurnBannerFormatter.submitted(context),
                        for: existing,
                        task: task,
                        immediately: true
                    )
                }
            } else {
                existing.context.agentName = context.agentName
            }
            return existingToken
        }

        let token = UUID()
        let identifier = "\(bundleIdentifier).codex-turn.\(token.uuidString.lowercased())"
        let initialAssistantItemID = snapshotProvider()?
            .threadSnapshot(for: key)?
            .latestAssistantSnippetSnapshot?
            .sourceItemId
        let session = Session(
            token: token,
            identifier: identifier,
            key: key,
            initialAssistantItemID: initialAssistantItemID,
            context: context,
            keepsAliveAcrossTurns: keepsAliveAcrossTurns
        )

        let registered = scheduler.register(identifier: identifier) { [weak self] task in
            Task { @MainActor [weak self] in
                self?.activate(task, token: token)
            }
        }

        guard registered else {
            LLog.warn(
                "background-turn",
                "continued processing handler registration was rejected",
                fields: ["identifier": identifier]
            )
            return nil
        }

        sessions[token] = session
        tokenByThreadKey[key] = token

        let banner = ContinuedTurnBannerFormatter.submitted(context)
        session.lastBanner = banner
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: banner.title,
            subtitle: banner.subtitle
        )
        request.strategy = .queue
        request.requiredResources = []

        do {
            try scheduler.submit(request)
            LLog.info(
                "background-turn",
                "submitted continued processing task",
                fields: ["identifier": identifier, "thread": Self.threadLabel(key)]
            )
            return token
        } catch {
            removeSession(token: token, cancelPendingRequest: true)
            LLog.error(
                "background-turn",
                "continued processing task submission failed",
                error: error,
                fields: ["identifier": identifier, "thread": Self.threadLabel(key)]
            )
            return nil
        }
    }

    func markTurnAccepted(_ token: UUID) {
        sessions[token]?.accepted = true
        handleSnapshot(snapshotProvider())
    }

    func markTurnStartFailed(_ token: UUID) {
        if sessions[token]?.keepsAliveAcrossTurns == true {
            return
        }
        finish(token: token, outcome: .failed(message: ""))
    }

    /// Automatic continuations share the learner's lease without renaming it.
    func reuseMultiTurnSessionIfPresent(key: ThreadKey, agentName: String) -> UUID? {
        guard let token = tokenByThreadKey[key], let session = sessions[token] else {
            return nil
        }
        session.context.agentName = agentName
        return token
    }

    /// A multi-turn lease ends when its caller says so; the caller knows
    /// whether the learner stopped it, it failed, or it finished.
    func finishMultiTurnSession(key: ThreadKey, outcome: TurnOutcome) {
        guard let token = tokenByThreadKey[key] else { return }
        let summary = snapshotProvider()?.sessionSummary(for: key)
        finish(token: token, outcome: outcome, activity: summary?.currentActivity)
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        guard let snapshot else { return }

        for session in Array(sessions.values) {
            guard let thread = snapshot.threadSnapshot(for: session.key) else { continue }

            if thread.hasActiveTurn {
                session.observedActiveTurn = true
                session.idleWithoutOutcomeSince = nil
                session.outcomeWaitTask?.cancel()
                session.outcomeWaitTask = nil
                refresh(session, snapshot: snapshot)
                continue
            }

            let assistantItemID = thread.latestAssistantSnippetSnapshot?.sourceItemId
            let receivedNewAssistantOutput = session.accepted
                && assistantItemID != nil
                && assistantItemID != session.initialAssistantItemID

            guard !session.keepsAliveAcrossTurns,
                  session.observedActiveTurn || receivedNewAssistantOutput else { continue }
            let summary = snapshot.sessionSummary(for: session.key)
            if summary?.lastTurnOutcome == nil, !outcomeGraceElapsed(for: session) {
                continue
            }
            finish(
                token: session.token,
                outcome: summary?.lastTurnOutcome,
                activity: summary?.currentActivity
            )
        }
    }

    /// Upstream sends `thread/status/changed` (idle) before `turn/completed`,
    /// so the first idle snapshot can lack the outcome. Waits up to
    /// `outcomeGrace` for it, re-checking once the grace has passed.
    private func outcomeGraceElapsed(for session: Session) -> Bool {
        let timestamp = now()
        guard let since = session.idleWithoutOutcomeSince else {
            session.idleWithoutOutcomeSince = timestamp
            let token = session.token
            session.outcomeWaitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.outcomeGrace))
                guard !Task.isCancelled, let self, self.sessions[token] != nil else { return }
                self.handleSnapshot(self.snapshotProvider())
            }
            return false
        }
        return timestamp - since >= Self.outcomeGrace
    }

    private func activate(_ task: any ContinuedProcessingTaskHandling, token: UUID) {
        guard let session = sessions[token] else {
            task.setTaskCompleted(success: false)
            return
        }

        session.backgroundTask = task
        task.progress.totalUnitCount = ContinuedTurnProgress.total
        task.progress.completedUnitCount = session.progress.completed
        session.lastProgressUpdate = now()
        refresh(session, snapshot: snapshotProvider())

        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.expire(token: token)
            }
        }

        session.heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, let liveSession = self.sessions[token] else { return }
                self.refresh(liveSession, snapshot: self.snapshotProvider())
            }
        }

        handleSnapshot(snapshotProvider())
    }

    /// Advances progress and, while the turn is active, the banner. An idle
    /// thread keeps its current text: before the turn starts the summary still
    /// describes the previous request, and a Hermes lease idles between tool
    /// round trips.
    private func refresh(_ session: Session, snapshot: AppSnapshotRecord?) {
        let thread = snapshot?.threadSnapshot(for: session.key)
        let isActive = thread?.hasActiveTurn == true
        if isActive, let activity = snapshot?.sessionSummary(for: session.key)?.currentActivity {
            session.lastActivity = activity
        }
        tickProgress(for: session, plan: thread?.activePlanProgress)
        if isActive, let snapshot, let thread {
            updatePresentation(for: session, snapshot: snapshot, thread: thread)
        }
    }

    private func tickProgress(for session: Session, plan: AppPlanProgressSnapshot?) {
        guard let task = session.backgroundTask else { return }
        let timestamp = now()
        guard timestamp - session.lastProgressUpdate >= Self.progressInterval else { return }
        let units = session.progress.tick(
            context: session.context,
            activity: session.lastActivity,
            plan: plan
        )
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, units)
        session.lastProgressUpdate = timestamp
    }

    private func updatePresentation(
        for session: Session,
        snapshot: AppSnapshotRecord,
        thread: AppThreadSnapshot
    ) {
        guard let task = session.backgroundTask else { return }
        let key = session.key
        let needsApproval = snapshot.pendingApprovals.contains {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }
        let needsInput = snapshot.pendingUserInputs.contains {
            $0.serverId == key.serverId && $0.threadId == key.threadId
        }
        let banner = ContinuedTurnBannerFormatter.running(
            context: session.context,
            activity: snapshot.sessionSummary(for: key)?.currentActivity ?? session.lastActivity,
            plan: thread.activePlanProgress,
            needsApproval: needsApproval,
            needsInput: needsInput
        )
        show(banner, for: session, task: task, immediately: needsApproval || needsInput)
    }

    private func show(
        _ banner: ContinuedTurnBanner,
        for session: Session,
        task: any ContinuedProcessingTaskHandling,
        immediately: Bool
    ) {
        guard banner != session.lastBanner else { return }
        let timestamp = now()
        guard immediately
                || timestamp - session.lastBannerAt >= Self.bannerInterval else { return }
        task.updateTitle(banner.title, subtitle: banner.subtitle)
        session.lastBanner = banner
        session.lastBannerAt = timestamp
        LLog.debug(
            "background-turn",
            "presentation",
            fields: [
                "title": banner.title,
                "subtitle": banner.subtitle,
                "fraction": task.progress.fractionCompleted
            ]
        )
    }

    private func expire(token: UUID) {
        guard let session = sessions[token] else { return }
        let key = session.key
        // The system owns the UI once it expires the task.
        finish(token: token, outcome: .interrupted, announces: false)
        LLog.warn(
            "background-turn",
            "continued processing task expired or was cancelled",
            fields: ["thread": Self.threadLabel(key)]
        )
        onExpiration(key)
    }

    private func finish(
        token: UUID,
        outcome: TurnOutcome?,
        activity: AppTurnActivity? = nil,
        announces: Bool = true
    ) {
        guard let session = sessions[token] else { return }
        session.heartbeatTask?.cancel()
        session.heartbeatTask = nil
        session.outcomeWaitTask?.cancel()
        session.outcomeWaitTask = nil

        let result = ContinuedTurnBannerFormatter.finished(
            context: session.context,
            activity: activity ?? session.lastActivity,
            outcome: outcome
        )
        if let task = session.backgroundTask {
            if result.success {
                let finalUnit = max(1, task.progress.completedUnitCount + 1)
                task.progress.totalUnitCount = finalUnit
                task.progress.completedUnitCount = finalUnit
            }
            if announces {
                show(result.banner, for: session, task: task, immediately: true)
            }
            task.expirationHandler = nil
            task.setTaskCompleted(success: result.success)
        }

        removeSession(token: token, cancelPendingRequest: session.backgroundTask == nil)
        LLog.info(
            "background-turn",
            "completed continued processing task",
            fields: [
                "thread": Self.threadLabel(session.key),
                "success": result.success
            ]
        )
    }

    private func removeSession(token: UUID, cancelPendingRequest: Bool) {
        guard let session = sessions.removeValue(forKey: token) else { return }
        session.heartbeatTask?.cancel()
        session.outcomeWaitTask?.cancel()
        if tokenByThreadKey[session.key] == token {
            tokenByThreadKey.removeValue(forKey: session.key)
        }
        if cancelPendingRequest {
            scheduler.cancel(identifier: session.identifier)
        }
    }

    private static func threadLabel(_ key: ThreadKey) -> String {
        "\(key.serverId)|\(key.threadId)"
    }
}
