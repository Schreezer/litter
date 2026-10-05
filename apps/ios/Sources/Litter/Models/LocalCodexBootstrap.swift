#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import UIKit

/// Bootstraps a local `codex app-server` on the host Mac when running on
/// the unsandboxed (direct-distribution) Catalyst lane. Sandboxed Catalyst
/// (Mac App Store) and iOS skip this entirely — they have no permission to
/// spawn child processes.
@MainActor
@Observable
final class LocalCodexBootstrap {
    static let shared = LocalCodexBootstrap()

    /// Reserved server id used for the bundled "Local Mac" entry. Matches
    /// the pre-existing convention in `SavedServerStore.reconnectRecords`.
    static let serverId = "local-mac"

    /// The codex app-server WebSocket port. Hard-coded for now; the
    /// onboarding plan also pins this for the iPhone↔Mac pairing flow.
    static let port: UInt16 = 8390

    enum Status: Equatable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored private let appClient = AppClient()

    /// Strong reference to the spawned process handle. Kept alive for the
    /// lifetime of the app so the child is not orphaned.
    @ObservationIgnored private var processHandle: LocalServerProcessHandle?

    /// Connected server id returned by the Rust transport layer. Empty
    /// until `attachOrSpawn()` succeeds.
    private(set) var connectedServerId: String?

    @ObservationIgnored private var bootstrapTask: Task<String, Error>?
    @ObservationIgnored private var bootstrapGeneration = UUID()

    private init() {}

    /// Kick off attach-or-spawn in the background and connect the result
    /// as a first-class server. Safe to call multiple times — subsequent
    /// calls are no-ops while a previous attempt is in flight or has
    /// already produced a `connectedServerId`.
    func startIfNeeded(appModel: AppModel) {
        guard LitterPlatform.isDirectDistMac else { return }
        Task {
            _ = try? await ensureConnected(appModel: appModel)
        }
    }

    /// Coalesces startup and retry callers. A disconnected snapshot must never
    /// be treated as ready merely because a previous launch produced an ID.
    func ensureConnected(appModel: AppModel, forceReconnect: Bool = false) async throws -> String {
        guard LitterPlatform.isDirectDistMac else {
            throw NSError(domain: "Learnfold.LocalCodex", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Installed Mac Codex requires the direct-download version of Learnfold."
            ])
        }
        if let bootstrapTask {
            return try await bootstrapTask.value
        }
        if !forceReconnect,
           appModel.snapshot?.serverSnapshot(for: Self.serverId)?.isConnected == true {
            connectedServerId = Self.serverId
            status = .ready
            return Self.serverId
        }
        let generation = UUID()
        bootstrapGeneration = generation
        status = .starting
        let task = Task<String, Error> { [self] in
            let result = try await appClient.attachOrSpawnLocalServer(
                port: Self.port,
                codexHome: nil
            )
            do {
                try Task.checkCancellation()
                let connectedID = try await appModel.serverBridge.connectHostLocalServer(
                    serverId: Self.serverId,
                    displayName: Self.displayName(),
                    host: result.host,
                    port: result.port
                )
                try Task.checkCancellation()
                // Keep our existing owned process when this retry attached to
                // the same healthy listener; externally owned processes are
                // never stopped when Learnfold quits.
                if let handle = result.handle {
                    processHandle = handle
                }
                connectedServerId = connectedID
                await appModel.refreshSnapshot()
                LLog.info("local-codex", "installed Codex connected", fields: [
                    "port": Int(result.port),
                    "attached": result.attachedToExisting,
                    "codexPath": result.codexPath ?? "(existing server)"
                ])
                return connectedID
            } catch {
                if let handle = result.handle { await handle.stop() }
                throw error
            }
        }
        bootstrapTask = task
        do {
            let serverID = try await task.value
            if bootstrapGeneration == generation {
                bootstrapTask = nil
                status = .ready
            }
            return serverID
        } catch {
            if bootstrapGeneration == generation {
                bootstrapTask = nil
                connectedServerId = nil
                status = .failed(error.localizedDescription)
            }
            LLog.error("local-codex", "installed Codex connection failed", error: error)
            throw error
        }
    }

    func restart(appModel: AppModel) async throws {
        appModel.serverBridge.disconnectServer(serverId: Self.serverId)
        await stop()
        // Startup can finish registering its transport while cancellation is
        // draining. Remove that registration before opening the new one.
        appModel.serverBridge.disconnectServer(serverId: Self.serverId)
        await appModel.refreshSnapshot()
        _ = try await ensureConnected(appModel: appModel, forceReconnect: true)
    }

    /// Stop the spawned codex child (no-op when we attached to an
    /// externally-started process).
    func stop() async {
        let generation = UUID()
        bootstrapGeneration = generation
        let runningTask = bootstrapTask
        runningTask?.cancel()
        connectedServerId = nil
        status = .idle
        if let runningTask {
            _ = try? await runningTask.value
        }
        if bootstrapGeneration == generation { bootstrapTask = nil }
        if let handle = processHandle {
            processHandle = nil
            await handle.stop()
        }
    }

    /// Synchronous best-effort termination, safe to call from
    /// `applicationWillTerminate` where awaiting an async task can
    /// deadlock the main thread. Detaches the handle off the main actor
    /// and lets it terminate on the tokio runtime; we then sleep briefly
    /// (off-main where possible) for SIGTERM to take effect.
    nonisolated func stopBlocking(timeout: TimeInterval) {
        // The MainActor-isolated state is the bootstrapTask + handle. We
        // need to grab the handle on the main actor without re-entering
        // it from the calling thread (which IS the main thread during
        // willTerminate). DispatchQueue.main.sync would deadlock; instead
        // we grab `processHandle` directly via an unchecked nonisolated
        // accessor (safe because we're on the main thread already).
        let handle = MainActor.assumeIsolated { () -> LocalServerProcessHandle? in
            self.bootstrapGeneration = UUID()
            self.bootstrapTask?.cancel()
            self.bootstrapTask = nil
            let h = self.processHandle
            self.processHandle = nil
            return h
        }
        guard let handle else { return }

        // Spin off the actual stop on a detached Task so the tokio
        // runtime hosting `stop()` is free to run, then wait on a
        // semaphore. The Task does NOT touch the main actor, so this
        // does not deadlock with main-thread blocking.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await handle.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private static func displayName() -> String {
        LitterPlatform.localRuntimeDisplayName()
    }
}
#endif
