import Foundation

/// Where a chat's intents go. The source stays provider-agnostic: whoever
/// builds it supplies the routing (the course store for course chats).
@MainActor
struct ChatIntentRouting {
    /// Sends a learner message. Returns `false` if it was refused up front.
    var send: (String) -> Bool
    var stop: () -> Void
    /// Answers one question of an app-server `request_user_input` request.
    var respondToRequest: (_ requestID: String, _ questionID: String, _ option: String) -> Void
}

/// `ChatTimelineSource` over `AppStore.subscribeChat`.
///
/// Rust owns the timeline, the turn phase and the optimistic learner rows;
/// this type only pumps `ChatSubscription.nextUpdate()` onto the main actor
/// and forwards intents to `routing`.
@MainActor
final class RustChatTimelineSource: ChatTimelineSource {
    let key: ThreadKey
    private let store: AppStore
    private let options: ChatViewOptions
    private let routing: ChatIntentRouting
    /// Runs before each subscription opens, for sources whose transcript the
    /// platform holds (Apple re-sends `replaceTranscript`).
    private let prepare: (() -> Void)?
    private var pump: Task<Void, Never>?
    private var subscription: ChatSubscription?
    /// Identifies the newest `updates()` stream. A superseded stream's
    /// termination must not close the subscription that replaced it.
    private var streamGeneration = 0

    init(
        store: AppStore,
        key: ThreadKey,
        options: ChatViewOptions = ChatViewOptions(hidesSelectionEnvelope: false, showsInternalCourseActivity: false, hidesPlanRows: false),
        routing: ChatIntentRouting,
        prepare: (() -> Void)? = nil
    ) {
        self.store = store
        self.key = key
        self.options = options
        self.routing = routing
        self.prepare = prepare
    }

    deinit {
        pump?.cancel()
        subscription?.resync()
    }

    func updates() -> AsyncStream<ChatUpdate> {
        close()
        streamGeneration += 1
        let generation = streamGeneration
        prepare?()
        let subscription = store.subscribeChatWithOptions(key: key, options: options)
        self.subscription = subscription
        let (stream, continuation) = AsyncStream.makeStream(of: ChatUpdate.self)
        pump = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let update = try await subscription.nextUpdate()
                    guard !Task.isCancelled else { break }
                    continuation.yield(update)
                } catch {
                    LLog.warn(
                        "chat",
                        "chat subscription ended",
                        fields: ["error": error.localizedDescription]
                    )
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                // A later `updates()` call already closed this stream and
                // opened a new subscription; leave that one running.
                guard let self, self.streamGeneration == generation else { return }
                self.close()
            }
        }
        return stream
    }

    @discardableResult
    func send(text: String) -> Bool {
        routing.send(text)
    }

    func stop() {
        routing.stop()
    }

    func answer(_ answer: ChatQuestionAnswer) {
        guard let requestID = answer.requestID else {
            _ = routing.send(answer.option)
            return
        }
        // Rust always pairs a request id with a question id. Answering
        // without one would resolve the request with no answer at all.
        guard let questionID = answer.questionID else {
            LLog.warn(
                "chat",
                "question answer missing question id",
                fields: ["requestId": requestID]
            )
            return
        }
        routing.respondToRequest(requestID, questionID, answer.option)
    }

    /// Ends the current subscription. `nextUpdate()` can't be cancelled, so a
    /// resync wakes the pending call; the pump then sees the cancellation
    /// and drops the subscription, which releases the thread's chat state.
    private func close() {
        guard let pump else { return }
        pump.cancel()
        self.pump = nil
        subscription?.resync()
        subscription = nil
    }
}
