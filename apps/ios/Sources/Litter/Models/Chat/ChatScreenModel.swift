import Foundation
import Observation
import SwiftUI

/// One learner message and everything the agent did in reply.
///
/// `id` is the learner row's id. Rust keeps an optimistic learner row's id
/// (`user:<client id>`) after the source accepts it, so a turn keeps one
/// identity from send to settle. Rows before the first learner message (an
/// intro or restored notice) form a preamble turn with no `user`.
struct ChatTurn: Identifiable, Equatable {
    static let preambleID = "chat-preamble"
    /// The turn shown for a message the platform is still preparing, before
    /// the source has staged it.
    static let localPreviewID = "chat-local-preview"

    let id: String
    /// The identity views use. A sent message shows as the local preview
    /// until the source stages it; the staged turn keeps the preview's view
    /// identity, so it stays the same view instead of fading out and back
    /// in. Defaults to `id`.
    let viewID: String
    var user: ChatTimelineRow?
    var rows: [ChatTimelineRow]

    init(id: String, viewID: String? = nil, user: ChatTimelineRow?, rows: [ChatTimelineRow]) {
        self.id = id
        self.viewID = viewID ?? id
        self.user = user
        self.rows = rows
    }

    var hasFold: Bool {
        rows.contains(where: \.isFold)
    }

    var isLocalPreview: Bool { id == Self.localPreviewID }
}

/// Where streaming deltas go besides the row's `LiveTextBuffer`. The default
/// feeds the shared Hairball renderer so token reveal works as it does in
/// the rest of the app; tests swap in a recorder.
@MainActor
protocol ChatStreamingRendering: AnyObject {
    func append(_ delta: String, itemID: String)
    func finish(itemID: String)
}

@MainActor
final class SharedChatStreamingRenderer: ChatStreamingRendering {
    static let shared = SharedChatStreamingRenderer()

    func append(_ delta: String, itemID: String) {
        StreamingRendererCoordinator.shared.appendDelta(delta, for: itemID)
    }

    func finish(itemID: String) {
        // Settled rows render from `StreamingAssistantRenderCache`, which is
        // LRU-trimmed, so only the streaming renderer needs releasing.
        StreamingRendererCoordinator.shared.finish(itemId: itemID)
    }
}

/// Applies Rust `ChatUpdate`s and exposes a turn-grouped timeline to the
/// chat screen.
///
/// Structural changes (rows added, phase changes) update `turns`. Text deltas
/// only touch the row's `LiveTextBuffer`, so streaming redraws one row.
@Observable
@MainActor
final class ChatScreenModel {
    /// Timeline grouped by learner message, oldest first.
    var turns: [ChatTurn] { layout.turns }
    /// The turn that owns the reserved viewport space. It is set when a new
    /// learner turn appears and stays set after the turn settles, until the
    /// next one, so settling never moves anything.
    var liveTurnID: String? { layout.liveTurnID }
    /// Turns and the live turn change in one assignment. A view that saw
    /// one without the other would lay the new turn out without its
    /// reserved space for a frame, and the scroll view would clamp its
    /// offset and drop the turn.
    private var layout = TurnLayout()
    private(set) var phase: ChatTurnPhase = .idle
    private(set) var connection: ChatConnectionPhase = .live
    private(set) var progressLabel: String?
    /// When the active turn started, from Rust's turn timing.
    private(set) var activeTurnStartedAt: Date?
    /// The answer row receiving text in the live turn. Only this row renders
    /// as streaming; earlier replies never do.
    private(set) var streamingRowID: String?
    /// The newest question row, whose options are tappable.
    private(set) var latestQuestionRowID: String?
    /// Text of a message the platform is still preparing. Shown as a pending
    /// bubble until the source stages its own learner row.
    private(set) var localPreviewText: String?
    /// Bumps when a learner send starts, so the screen can arm its scroll
    /// hand-off before the new turn arrives.
    private(set) var sendGeneration = 0
    /// View identity of the current local preview. Unique per send, so a
    /// staged turn can keep it without clashing with the next preview.
    private(set) var previewViewID = ChatTurn.localPreviewID
    /// The view identity the next send's preview gets, so the composer can
    /// hand its draft's position to that bubble.
    var nextPreviewViewID: String {
        "\(ChatTurn.localPreviewID)-\(previewCount + 1)"
    }

    /// Called after rows change, with the full row list. Course logic uses it
    /// to react to plan and tool rows without polling.
    @ObservationIgnored var onRowsChanged: (([ChatTimelineRow]) -> Void)?
    /// Called when the phase changes.
    @ObservationIgnored var onPhaseChanged: ((ChatTurnPhase) -> Void)?
    /// Animation for inserting a new learner turn. Set by the screen (nil
    /// under Reduce Motion).
    @ObservationIgnored var turnInsertionAnimation: Animation?

    @ObservationIgnored private let source: ChatTimelineSource?
    @ObservationIgnored private let renderer: ChatStreamingRendering
    @ObservationIgnored private var rows: [ChatTimelineRow] = []
    @ObservationIgnored private var buffers: [String: LiveTextBuffer] = [:]
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Between `start()` and `tearDown()`: the screen wants updates.
    @ObservationIgnored private var isStarted = false
    /// Updates at or below this sequence number predate the applied snapshot.
    @ObservationIgnored private var snapshotSeq: UInt64?
    @ObservationIgnored private var previewCount = 0
    /// Staged learner rows that replaced a local preview, and the preview's
    /// view identity they keep.
    @ObservationIgnored private var stagedPreviewViewIDs: [String: String] = [:]

    init(source: ChatTimelineSource?, renderer: ChatStreamingRendering? = nil) {
        self.source = source
        self.renderer = renderer ?? SharedChatStreamingRenderer.shared
    }

    // MARK: - Lifecycle

    /// Starts consuming the source. Safe to call more than once.
    func start() {
        guard updatesTask == nil, let source else { return }
        isStarted = true
        let stream = source.updates()
        updatesTask = Task { [weak self] in
            for await update in stream {
                // AsyncStream keeps handing out buffered elements after
                // cancellation, so check explicitly: nothing may apply after
                // `tearDown()`.
                guard !Task.isCancelled, let self else { return }
                self.apply(update)
            }
            // The stream ended on its own. Forget it so the next `start()` or
            // `resync()` subscribes again instead of leaving the screen on
            // its last update.
            guard !Task.isCancelled else { return }
            self?.updatesTask = nil
        }
    }

    /// Brings the screen up to date with the source: a full snapshot from a
    /// live subscription, or a new subscription if the last one ended.
    /// Missed updates of any kind are repaired by this.
    func resync() {
        guard isStarted, let source else { return }
        if updatesTask == nil {
            start()
        } else {
            source.resync()
        }
    }

    /// Stops consuming the source and releases every streaming renderer this
    /// screen created.
    func tearDown() {
        isStarted = false
        updatesTask?.cancel()
        updatesTask = nil
        snapshotSeq = nil
        for rowID in buffers.keys {
            renderer.finish(itemID: Self.rendererItemID(for: rowID))
        }
    }

    // MARK: - Reading

    /// The live text for an answer row.
    func buffer(for rowID: String) -> LiveTextBuffer? {
        buffers[rowID]
    }

    func isStreaming(rowID: String) -> Bool {
        phase.isWorking && streamingRowID == rowID
    }

    /// The question whose options can be tapped right now: the newest one,
    /// while the turn waits on input or after it settles.
    var answerableQuestionRowID: String? {
        guard phase == .awaitingInput || !phase.isActive, localPreviewText == nil else { return nil }
        return latestQuestionRowID
    }

    var canSend: Bool {
        localPreviewText == nil && (!phase.isActive || phase == .awaitingInput)
    }

    /// True while the agent waits on an app-server `request_user_input`
    /// question. A typed message then answers that request (see `send`)
    /// instead of starting a turn.
    var awaitsRequestAnswer: Bool {
        phase == .awaitingInput && answerableQuestion()?.requestID != nil
    }

    var isEmpty: Bool {
        turns.isEmpty
    }

    /// Key for the shared streaming renderer. Namespaced so chat rows can't
    /// collide with conversation items that use the same coordinator.
    static func rendererItemID(for rowID: String) -> String {
        "chat-screen:\(rowID)"
    }

    // MARK: - Intents

    /// Sends a learner message. Returns `false` if nothing was sent.
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if phase == .awaitingInput,
           let question = answerableQuestion(), question.requestID != nil {
            source?.answer(ChatQuestionAnswer(
                requestID: question.requestID,
                questionID: question.questionID,
                option: trimmed
            ))
            return true
        }
        guard canSend, let source, source.send(text: trimmed) else { return false }
        noteLocalSend(previewText: trimmed)
        return true
    }

    func stop() {
        guard phase.canStop else { return }
        source?.stop()
    }

    /// A tapped question option. Questions with a pending request are
    /// answered through it; any other question takes the option as the
    /// learner's next message, sent through `sendMessage` when the host owns
    /// sending (the course composer) and through the source otherwise.
    @discardableResult
    func choose(
        option: String,
        rowID: String? = nil,
        sendMessage: ((String) -> Bool)? = nil
    ) -> Bool {
        let question = rowID.flatMap(questionTarget(rowID:)) ?? answerableQuestion()
        if let question, question.requestID != nil {
            source?.answer(ChatQuestionAnswer(
                requestID: question.requestID,
                questionID: question.questionID,
                option: option
            ))
            return true
        }
        if let sendMessage {
            return sendMessage(option)
        }
        return send(option)
    }

    /// A learner send that went through another path (the course composer).
    /// Shows `previewText` as a pending bubble until the source stages the
    /// message, and arms the screen's scroll hand-off.
    func noteLocalSend(previewText: String?) {
        finishStreamingRow()
        sendGeneration += 1
        setLocalPreview(previewText)
    }

    /// Takes over a send in flight from the model this one replaces. The
    /// course chat's first message creates its chat thread, so the screen
    /// swaps models mid-send; the pending bubble and the scroll hand-off
    /// must survive the swap (see `ChatScreen.attach`).
    func continuePendingSend(from previous: ChatScreenModel) {
        guard let text = previous.localPreviewText else { return }
        sendGeneration = previous.sendGeneration
        setLocalPreview(text, viewID: previous.previewViewID)
    }

    /// Shows or clears the pending bubble for a message the platform is
    /// still preparing.
    func setLocalPreview(_ text: String?) {
        setLocalPreview(text, viewID: nil)
    }

    private func setLocalPreview(_ text: String?, viewID: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed?.isEmpty == false ? trimmed : nil
        guard next != localPreviewText else { return }
        if next != nil, localPreviewText == nil {
            if let viewID {
                previewViewID = viewID
            } else {
                previewCount += 1
                previewViewID = "\(ChatTurn.localPreviewID)-\(previewCount)"
            }
        }
        localPreviewText = next
        if next != nil, progressLabel != nil { progressLabel = nil }
        rebuildTurns(animated: next != nil) { live, turns in
            if next != nil {
                live = ChatTurn.localPreviewID
            } else if live == ChatTurn.localPreviewID {
                live = turns.last(where: { $0.user != nil })?.id
            }
        }
    }

    // MARK: - Applying updates

    func apply(_ update: ChatUpdate) {
        if case .snapshot = update {
            // A snapshot is authoritative and resets the sequence floor.
        } else if let snapshotSeq, update.seq <= snapshotSeq {
            return
        }
        switch update {
        case .snapshot(let snapshotRows, let snapshotPhase, let snapshotConnection, let label, let startedAt, let seq):
            snapshotSeq = seq
            applySnapshot(rows: snapshotRows, phase: snapshotPhase)
            applyProgress(label: label, startedAtMs: startedAt)
            if connection != snapshotConnection {
                connection = snapshotConnection
            }
        case .rowsChanged(let upserts, let removals, let order, _):
            applyRowsChanged(upserts: upserts, removals: removals, order: order)
        case .textAppended(let rowID, let text, _, _):
            appendText(text, to: rowID)
        case .phaseChanged(let newPhase, let label, let startedAt, _):
            applyPhase(newPhase)
            applyProgress(label: label, startedAtMs: startedAt)
        case .connectionChanged(let newConnection, _):
            if connection != newConnection {
                connection = newConnection
            }
        }
    }

    private func applySnapshot(rows snapshotRows: [ChatTimelineRow], phase snapshotPhase: ChatTurnPhase) {
        let previousUserIDs = Set(rows.lazy.filter(\.isUser).map(\.id))
        let keptIDs = Set(snapshotRows.map(\.id))
        for rowID in buffers.keys where !keptIDs.contains(rowID) {
            dropBuffer(rowID)
        }
        rows = snapshotRows
        for row in rows {
            syncBuffer(for: row)
        }
        if let streamingRowID, !keptIDs.contains(streamingRowID) {
            self.streamingRowID = nil
        }
        let newUserID = rows.last(where: { $0.isUser && !previousUserIDs.contains($0.id) })?.id
        var stagedPreviewID: String?
        if let newUserID, !previousUserIDs.isEmpty || localPreviewText != nil {
            if localPreviewText != nil {
                stagePreview(as: newUserID)
                stagedPreviewID = newUserID
            }
            localPreviewText = nil
        }
        rebuildTurns(animated: false) { live, turns in
            if snapshotPhase.isActive {
                live = turns.last(where: { $0.user != nil })?.id ?? live
            } else if let stagedPreviewID {
                // The sent message is staged before its turn starts; it owns
                // the reserve the preview had.
                live = stagedPreviewID
            } else if let newUserID, !previousUserIDs.isEmpty {
                // A resync found a turn the screen missed; it is the newest,
                // as it would have been had its rows arrived as diffs.
                live = newUserID
            } else if let current = live, !turns.contains(where: { $0.id == current }) {
                live = nil
            }
        }
        applyPhase(snapshotPhase)
        onRowsChanged?(rows)
    }

    private func applyRowsChanged(upserts: [ChatTimelineRow], removals: [String], order: [String]) {
        guard !upserts.isEmpty || !removals.isEmpty || order != rows.map(\.id) else { return }
        var byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for rowID in removals {
            guard byID.removeValue(forKey: rowID) != nil else { continue }
            dropBuffer(rowID)
            if streamingRowID == rowID { streamingRowID = nil }
        }
        var newUserIDs: [String] = []
        for row in upserts {
            if byID[row.id] == nil, row.isUser {
                newUserIDs.append(row.id)
            }
            byID[row.id] = row
            syncBuffer(for: row)
            if case .answer(_, true, _) = row.kind, phase.isWorking, streamingRowID != row.id {
                finishStreamingRow()
                streamingRowID = row.id
            }
        }
        var ordered: [ChatTimelineRow] = order.compactMap { byID.removeValue(forKey: $0) }
        // Rows Rust did not list keep their relative order at the end. This
        // only happens if an update was dropped; the next snapshot fixes it.
        if !byID.isEmpty {
            ordered += rows.compactMap { byID.removeValue(forKey: $0.id) }
            ordered += upserts.compactMap { byID.removeValue(forKey: $0.id) }
        }
        rows = ordered

        let newTurnID = newUserIDs.last
        if let newTurnID {
            if localPreviewText != nil {
                stagePreview(as: newTurnID)
            }
            localPreviewText = nil
        }
        if newTurnID != nil { progressLabel = nil }
        rebuildTurns(animated: newTurnID != nil) { live, turns in
            if let newTurnID {
                live = newTurnID
            } else if let current = live, current != ChatTurn.localPreviewID,
                      !turns.contains(where: { $0.id == current }) {
                live = turns.last(where: { $0.user != nil })?.id
            }
        }
        onRowsChanged?(rows)
    }

    private func appendText(_ delta: String, to rowID: String) {
        guard !delta.isEmpty else { return }
        let buffer: LiveTextBuffer
        if let existing = buffers[rowID] {
            buffer = existing
        } else {
            // A delta for a row the source never announced. Show it rather
            // than drop text.
            rows.append(ChatTimelineRow(id: rowID, kind: .answer(text: "", isStreaming: true, agentLabel: nil)))
            buffer = LiveTextBuffer(rowID: rowID)
            buffers[rowID] = buffer
            rebuildTurns(animated: false)
        }
        if phase.isWorking, streamingRowID != rowID {
            finishStreamingRow()
            streamingRowID = rowID
        }
        buffer.append(delta)
        renderer.append(delta, itemID: Self.rendererItemID(for: rowID))
    }

    private func applyPhase(_ newPhase: ChatTurnPhase) {
        // Rust settles a reply that ends in a question and asks for input in
        // one batch, so `.streaming` can go straight to `.awaitingInput`.
        // The answer is complete either way.
        if !newPhase.isWorking {
            finishStreamingRow()
        }
        // Nothing is in flight once the source comes to rest, so a preview
        // that never became a learner row was not sent. Only a change counts:
        // a fresh thread's first snapshot is idle before the send that
        // created the thread has been staged.
        if !newPhase.isActive, newPhase != phase {
            if localPreviewText != nil {
                localPreviewText = nil
                rebuildTurns(animated: false) { live, turns in
                    if live == ChatTurn.localPreviewID {
                        live = turns.last(where: { $0.user != nil })?.id
                    }
                }
            }
        }
        if phase != newPhase {
            phase = newPhase
            onPhaseChanged?(newPhase)
        }
    }

    private func applyProgress(label: String?, startedAtMs: Int64?) {
        let nextLabel = phase.isActive ? label : nil
        if progressLabel != nextLabel {
            progressLabel = nextLabel
        }
        let startedAt = startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if activeTurnStartedAt != startedAt {
            activeTurnStartedAt = startedAt
        }
    }

    // MARK: - Helpers

    private struct QuestionTarget {
        let rowID: String
        let requestID: String?
        let questionID: String?
    }

    private func questionTarget(rowID: String) -> QuestionTarget? {
        guard let row = rows.first(where: { $0.id == rowID }),
              case .question(_, _, _, _, let requestID, let questionID, _) = row.kind else { return nil }
        return QuestionTarget(rowID: rowID, requestID: requestID, questionID: questionID)
    }

    private func answerableQuestion() -> QuestionTarget? {
        latestQuestionRowID.flatMap(questionTarget(rowID:))
    }

    private func syncBuffer(for row: ChatTimelineRow) {
        guard case .answer(let text, _, _) = row.kind else {
            if buffers[row.id] != nil {
                dropBuffer(row.id)
            }
            return
        }
        guard let buffer = buffers[row.id] else {
            buffers[row.id] = LiveTextBuffer(rowID: row.id, text: text)
            return
        }
        switch buffer.sync(to: text) {
        case .unchanged:
            break
        case .appended(let delta):
            renderer.append(delta, itemID: Self.rendererItemID(for: row.id))
        case .replaced:
            // The renderer has consumed text that is no longer true. Drop it
            // so the row rebuilds from the buffer.
            renderer.finish(itemID: Self.rendererItemID(for: row.id))
        }
    }

    private func dropBuffer(_ rowID: String) {
        guard buffers.removeValue(forKey: rowID) != nil else { return }
        renderer.finish(itemID: Self.rendererItemID(for: rowID))
    }

    private func finishStreamingRow() {
        guard let rowID = streamingRowID else { return }
        streamingRowID = nil
        renderer.finish(itemID: Self.rendererItemID(for: rowID))
    }

    /// The staged learner row takes over the local preview's view identity.
    private func stagePreview(as userRowID: String) {
        stagedPreviewViewIDs[userRowID] = previewViewID
    }

    /// Regroups rows into turns. `updateLive` picks the live turn against
    /// the new turns, and both land in one assignment (see `layout`).
    private func rebuildTurns(
        animated: Bool,
        updateLive: (_ live: inout String?, _ turns: [ChatTurn]) -> Void = { _, _ in }
    ) {
        var result: [ChatTurn] = []
        var current: ChatTurn?
        var latestQuestion: String?
        for row in rows {
            if row.isUser {
                if let current { result.append(current) }
                current = ChatTurn(id: row.id, viewID: stagedPreviewViewIDs[row.id], user: row, rows: [])
                latestQuestion = nil
                continue
            }
            if current == nil {
                current = ChatTurn(id: ChatTurn.preambleID, user: nil, rows: [])
            }
            current?.rows.append(row)
            if case .question = row.kind {
                latestQuestion = row.id
            }
        }
        if let current { result.append(current) }
        if let localPreviewText {
            result.append(ChatTurn(
                id: ChatTurn.localPreviewID,
                viewID: previewViewID,
                user: ChatTimelineRow(
                    id: ChatTurn.localPreviewID,
                    kind: .user(text: localPreviewText, imageDataUris: [], delivery: .pending)
                ),
                rows: []
            ))
        }

        var next = TurnLayout(turns: result, liveTurnID: layout.liveTurnID)
        updateLive(&next.liveTurnID, result)
        if next != layout {
            if animated, let turnInsertionAnimation {
                withAnimation(turnInsertionAnimation) { layout = next }
            } else {
                layout = next
            }
        }
        if latestQuestionRowID != latestQuestion {
            latestQuestionRowID = latestQuestion
        }
    }
}

private struct TurnLayout: Equatable {
    var turns: [ChatTurn] = []
    var liveTurnID: String?
}
