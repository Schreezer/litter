import Foundation

/// A question row the learner answered by tapping an option.
struct ChatQuestionAnswer: Equatable, Sendable {
    /// Set for app-server `request_user_input` questions, which are answered
    /// through the pending request. `nil` for questions the agent asked in
    /// prose, which are answered by sending the option as the next message.
    let requestID: String?
    let questionID: String?
    let option: String
}

/// Where a chat screen's state comes from and where its intents go.
///
/// Every provider (app-server, hosted, Apple on-device) reaches the screen as
/// the same stream of Rust `ChatUpdate`s. Routing a send, stop or answer to
/// the right runtime is the source's job, so no view or model branches on
/// the provider.
@MainActor
protocol ChatTimelineSource: AnyObject {
    /// A fresh stream of updates. The first element is a `.snapshot` so the
    /// screen can render history before any diffs.
    func updates() -> AsyncStream<ChatUpdate>

    /// Sends a learner message. Returns `false` when the message was refused
    /// before it reached the source (the draft should stay in the composer).
    /// The learner row itself comes back through `updates()`.
    @discardableResult
    func send(text: String) -> Bool

    /// Asks the source to interrupt the live turn. The phase moves to
    /// `.stopping` and later `.settled(.interrupted)` through `updates()`.
    func stop()

    /// Answers a question row.
    func answer(_ answer: ChatQuestionAnswer)
}
