import Foundation

// The chat surface is owned by the shared Rust layer (`store/chat.rs`,
// `store/timeline.rs`, `store/turn.rs`). These aliases keep the chat screen's
// vocabulary while every value is the generated UniFFI type, so nothing is
// copied or re-shaped between Rust and the views.

typealias ChatTurnPhase = TurnPhase
typealias ChatTurnOutcome = TurnOutcome
typealias ChatConnectionPhase = ConnectionPhase
typealias ChatTimelineRow = TimelineRow
typealias ChatWorkEntry = WorkEntry
typealias ChatNoticeTone = NoticeTone

extension TurnPhase {
    /// True from send until the source settles the turn.
    var isActive: Bool {
        switch self {
        case .idle, .settled:
            false
        case .queued, .accepted, .thinking, .streaming, .acting, .awaitingInput, .stopping:
            true
        }
    }

    /// True while the agent is producing the reply. A turn waiting on the
    /// learner's answer is active but not working: it renders settled (no
    /// streaming row, no highlight, no follow-bottom).
    var isWorking: Bool {
        isActive && self != .awaitingInput
    }

    /// Whether the stop control is meaningful.
    var canStop: Bool {
        isActive && self != .stopping
    }

    /// Stable name for accessibility values and logs.
    var debugName: String {
        switch self {
        case .idle: "idle"
        case .queued: "queued"
        case .accepted: "accepted"
        case .thinking: "thinking"
        case .streaming: "streaming"
        case .acting: "acting"
        case .awaitingInput: "awaitingInput"
        case .stopping: "stopping"
        case .settled(.completed): "settled(completed)"
        case .settled(.interrupted): "settled(interrupted)"
        case .settled(.failed): "settled(failed)"
        }
    }
}

extension TimelineRow: Identifiable {}

extension TimelineRow {
    /// Builds a row with a content digest, for fixtures and tests. Rows from
    /// Rust carry their own digest.
    init(id: String, turnId: String? = nil, kind: TimelineRowKind) {
        var hasher = Hasher()
        hasher.combine(kind)
        self.init(
            id: id,
            turnId: turnId,
            digest: UInt64(bitPattern: Int64(hasher.finalize())),
            kind: kind
        )
    }

    var isUser: Bool {
        if case .user = kind { return true }
        return false
    }

    var isFold: Bool {
        if case .fold = kind { return true }
        return false
    }

    var isWork: Bool {
        if case .work = kind { return true }
        return false
    }

    /// A learner row the source has not accepted yet.
    var isPendingUser: Bool {
        if case .user(_, _, .pending) = kind { return true }
        return false
    }
}

extension WorkEntry: Identifiable {
    public var id: String { itemId }
}

extension ChatUpdate {
    /// The thread sequence number the update was produced at.
    var seq: UInt64 {
        switch self {
        case .snapshot(_, _, _, _, _, let seq),
             .rowsChanged(_, _, _, let seq),
             .textAppended(_, _, _, let seq),
             .phaseChanged(_, _, _, let seq),
             .connectionChanged(_, let seq):
            seq
        }
    }
}
