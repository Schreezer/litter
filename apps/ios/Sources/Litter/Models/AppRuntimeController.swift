import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppRuntimeController {
    static let shared = AppRuntimeController()

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private weak var voiceRuntime: VoiceRuntimeController?
    @ObservationIgnored private let lifecycle = AppLifecycleController()
    @ObservationIgnored private let liveActivities = TurnLiveActivityController()
    @ObservationIgnored private let reachability = NetworkReachabilityObserver()
    @ObservationIgnored private let notificationPermissions: AppNotificationPermissionController
    @ObservationIgnored private var continuedTurnBackground: (any ContinuedTurnBackgroundControlling)?
    @ObservationIgnored private var pendingLiveActivitySync = false
    @ObservationIgnored private var lastLiveActivitySyncTime: CFAbsoluteTime = 0

    init(
        notificationPermissions: AppNotificationPermissionController? = nil
    ) {
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "AppRuntimeController.init"
        )
        self.notificationPermissions = notificationPermissions ?? .shared
    }

    func bind(appModel: AppModel, voiceRuntime: VoiceRuntimeController) {
        guard !LearnfoldStrictHarnessPolicy.isStrictHarnessActive() else {
            return
        }
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "AppRuntimeController.bind"
        )
        notificationPermissions.runtimeDidBind()
        self.appModel = appModel
        self.voiceRuntime = voiceRuntime
        if #available(iOS 26.0, *), continuedTurnBackground == nil {
            continuedTurnBackground = ContinuedTurnBackgroundController(
                snapshotProvider: { [weak self] in self?.appModel?.snapshot },
                onExpiration: { [weak self] key in
                    guard let self else { return }
                    self.updateLiveActivityOwnership(snapshot: self.appModel?.snapshot)
                    self.interruptTurnAfterBackgroundExpiration(key: key)
                }
            )
        }
        reachability.bind(appModel: appModel)
        reachability.start()
        loadAndPushAlleycatSecretKey(client: appModel.client)
    }

    /// Load the persisted iroh device secret key from the keychain (if
    /// any) and push it to the Rust client BEFORE any alleycat
    /// operation triggers the endpoint bind. After the first bind, the
    /// Rust side may have generated a fresh key — observe via
    /// `persistAlleycatSecretKeyIfNeeded`. Together these maintain a
    /// stable `EndpointId` across cold launches.
    private func loadAndPushAlleycatSecretKey(client: AppClient) {
        do {
            if let bytes = try AlleycatCredentialStore.shared.loadDeviceSecretKey() {
                client.setAlleycatSecretKey(secretKeyBytes: bytes)
                LLog.info("alleycat", "loaded persisted device secret key from keychain")
            }
        } catch {
            LLog.error("alleycat", "failed to load device secret key", error: error)
        }
    }

    /// After an alleycat operation has triggered the Rust endpoint
    /// bind, read back the actually-used bytes and persist them so the
    /// next cold launch reuses the same `EndpointId`. Idempotent — safe
    /// to call any time; if the bind hasn't happened yet, returns
    /// silently.
    func persistAlleycatSecretKeyIfNeeded() {
        guard let appModel else { return }
        guard let data = appModel.client.alleycatSecretKey() else { return }
        do {
            let existing = try AlleycatCredentialStore.shared.loadDeviceSecretKey()
            if existing == data { return }
            try AlleycatCredentialStore.shared.saveDeviceSecretKey(data)
            LLog.info("alleycat", "persisted device secret key to keychain")
        } catch {
            LLog.error("alleycat", "failed to persist device secret key", error: error)
        }
    }

    /// Best-effort graceful shutdown of the iroh endpoint. Wired from
    /// `applicationWillTerminate` (UIKit) — see comment on that hook
    /// in LitterApp.swift for reliability caveats. iroh sends a clean
    /// CONNECTION_CLOSE to peers instead of logging "Aborting
    /// ungracefully" when the static MobileClient slot is finally
    /// dropped at process exit.
    func shutdownAlleycatEndpoint() async {
        guard let appModel else { return }
        await appModel.client.shutdownAlleycatEndpoint()
    }

    /// The endpoint-owning client, read synchronously. `applicationWillTerminate`
    /// blocks the main thread, so it cannot await a main-actor hop; it takes this
    /// `Sendable` handle first and closes the endpoint off the main actor.
    var alleycatEndpointClient: AppClient? { appModel?.client }

    func reconnectSavedServers() async {
        guard let appModel else { return }
        await lifecycle.reconnectSavedServers(appModel: appModel)
    }

    func reconnectServer(serverId: String) async {
        guard let appModel else { return }
        await lifecycle.reconnectServer(serverId: serverId, appModel: appModel)
    }

    func restoreMissingLocalAuthStateIfNeeded() async {
        guard let appModel else { return }
        await appModel.restoreMissingLocalAuthStateIfNeeded()
    }

    func openThreadFromNotification(key: ThreadKey) async {
        guard let appModel else { return }
        LLog.info(
            "push",
            "runtime opening thread from notification",
            fields: ["serverId": key.serverId, "threadId": key.threadId]
        )
        lifecycle.markThreadOpenedFromNotification(key)
        appModel.activateThread(key)

        if let resolvedKey = await appModel.ensureThreadLoaded(key: key) {
            lifecycle.markThreadOpenedFromNotification(resolvedKey)
            LLog.info(
                "push",
                "notification thread resolved and activated",
                fields: ["serverId": resolvedKey.serverId, "threadId": resolvedKey.threadId]
            )
            appModel.activateThread(resolvedKey)
            await appModel.refreshThreadSnapshot(key: resolvedKey)
        } else {
            LLog.warn(
                "push",
                "notification thread could not be resolved",
                fields: ["serverId": key.serverId, "threadId": key.threadId]
            )
        }
    }

    func handleSnapshot(_ snapshot: AppSnapshotRecord?) {
        continuedTurnBackground?.handleSnapshot(snapshot)
        updateLiveActivityOwnership(snapshot: snapshot)

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastLiveActivitySyncTime
        if elapsed >= 3.0 {
            lastLiveActivitySyncTime = now
            liveActivities.sync(snapshot)
        } else if !pendingLiveActivitySync {
            pendingLiveActivitySync = true
            let delay = 3.0 - elapsed
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.pendingLiveActivitySync = false
                self.lastLiveActivitySyncTime = CFAbsoluteTimeGetCurrent()
                self.liveActivities.sync(self.appModel?.snapshot)
            }
        }
    }

    /// Whether a user-initiated turn started now could get a
    /// continued-processing task. Lets callers skip work that only feeds the
    /// task's banner.
    var canBeginUserInitiatedTurn: Bool {
        continuedTurnBackground != nil && UIApplication.shared.applicationState == .active
    }

    /// Called synchronously with the user action that starts a Codex turn.
    /// This is intentionally separate from snapshot observation because iOS 26
    /// only permits continued-processing requests that directly follow a
    /// person's action.
    func beginUserInitiatedTurn(
        key: ThreadKey,
        appModel: AppModel,
        context: ContinuedTurnContext,
        keepsAliveAcrossTurns: Bool = false
    ) -> UUID? {
        guard self.appModel === appModel else { return nil }
        guard UIApplication.shared.applicationState == .active else { return nil }
        let token = continuedTurnBackground?.beginUserInitiatedTurn(
            key: key,
            context: context,
            keepsAliveAcrossTurns: keepsAliveAcrossTurns
        )
        updateLiveActivityOwnership(snapshot: appModel.snapshot)
        return token
    }

    func markUserInitiatedTurnAccepted(_ token: UUID?) {
        guard let token else { return }
        continuedTurnBackground?.markTurnAccepted(token)
        updateLiveActivityOwnership(snapshot: appModel?.snapshot)
    }

    func markUserInitiatedTurnStartFailed(_ token: UUID?) {
        guard let token else { return }
        continuedTurnBackground?.markTurnStartFailed(token)
        updateLiveActivityOwnership(snapshot: appModel?.snapshot)
    }

    /// Automatic continuation turns may share a lease created by the learner's
    /// initiating action, but must never submit a new continued-processing
    /// request of their own.
    func reuseUserInitiatedMultiTurnIfPresent(
        key: ThreadKey,
        agentName: String
    ) -> UUID? {
        continuedTurnBackground?.reuseMultiTurnSessionIfPresent(
            key: key,
            agentName: agentName
        )
    }

    /// Ends a multi-turn lease. `outcome` says why: `.interrupted` only for a
    /// learner's stop or abandon, `.failed` for errors.
    func finishUserInitiatedMultiTurn(
        key: ThreadKey,
        outcome: TurnOutcome
    ) {
        continuedTurnBackground?.finishMultiTurnSession(key: key, outcome: outcome)
        updateLiveActivityOwnership(snapshot: appModel?.snapshot)
    }

    func appDidEnterBackground() {
        guard let appModel else { return }
        appModel.reconnectController.onAppEnteredBackground()
        lifecycle.appDidEnterBackground(
            snapshot: appModel.snapshot,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func appDidBecomeInactive() {
        guard let appModel else { return }
        appModel.reconnectController.onAppBecameInactive()
    }

    func appDidBecomeActive() {
        guard let appModel else { return }
        // Keep lifecycle state in sync even when foreground recovery exits early
        // for an already-running voice session.
        appModel.reconnectController.noteAppBecameActive()
        lifecycle.appDidBecomeActive(
            appModel: appModel,
            hasActiveVoiceSession: voiceRuntime?.activeVoiceSession != nil,
            liveActivities: liveActivities
        )
    }

    func handleBackgroundPush() async {
        guard let appModel else { return }
        LLog.info("push", "runtime handling background push")
        await lifecycle.handleBackgroundPush(
            appModel: appModel,
            liveActivities: liveActivities
        )
        LLog.info("push", "runtime finished background push")
    }

    private func updateLiveActivityOwnership(snapshot: AppSnapshotRecord?) {
        liveActivities.setSystemContinuedProcessingActive(
            continuedTurnBackground?.hasScheduledOrRunningTasks == true,
            snapshot: snapshot
        )
    }

    private func interruptTurnAfterBackgroundExpiration(key: ThreadKey) {
        guard let appModel,
              let turnID = appModel.threadSnapshot(for: key)?.activeTurnId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !turnID.isEmpty else {
            return
        }

        Task {
            do {
                _ = try await appModel.client.interruptTurn(
                    serverId: key.serverId,
                    params: AppInterruptTurnRequest(threadId: key.threadId, turnId: turnID)
                )
                await appModel.refreshThreadSnapshot(key: key)
            } catch {
                LLog.error(
                    "background-turn",
                    "failed to interrupt an expired continued-processing turn",
                    error: error,
                    fields: ["thread": "\(key.serverId)|\(key.threadId)"]
                )
            }
        }
    }
}
