#if DEBUG
import Foundation

/// A scripted `ChatTimelineSource` for the chat harness, previews and tests.
///
/// Each send replays one turn: accepted → thinking → a tool acting →
/// streamed answer paragraphs → a question with options → settled. The
/// scenario swaps in an interrupt, a failure or a reconnect.
@MainActor
final class FixtureChatSource: ChatTimelineSource {
    enum Scenario: String, CaseIterable, Sendable {
        /// The full happy path.
        case happy
        /// Stops partway through the answer, as if the learner tapped stop.
        case interrupt
        /// A tool fails and the turn settles as failed.
        case failure
        /// The connection drops mid-answer, resyncs with a snapshot, then
        /// keeps streaming.
        case reconnect
        /// One short paragraph and no question, so the settled turn fits
        /// above the keyboard.
        case brief
    }

    let scenario: Scenario
    /// Multiplies every pause. `0` runs the script as fast as the main
    /// actor allows, which tests use.
    let timeScale: Double
    /// Seconds before the source stages a sent message, as a hosted agent's
    /// round trip does. Until then only the local preview shows it.
    let stagingDelay: Double
    /// Called when the interrupt scenario reaches its stop point. The harness
    /// routes it through `ChatScreenModel.stop()` so the real stop path runs.
    var onAutoStop: (() -> Void)?

    private(set) var sentMessages: [String] = []
    private(set) var answeredOptions: [String] = []
    private(set) var stopCount = 0

    private var rows: [ChatTimelineRow]
    private var phase: ChatTurnPhase = .idle
    private var continuation: AsyncStream<ChatUpdate>.Continuation?
    private var runTask: Task<Void, Never>?
    private var stopRequested = false
    private var turnCount = 0
    private var seq: UInt64 = 0
    private var progressLabel: String?

    init(
        scenario: Scenario = .happy,
        timeScale: Double = 1,
        stagingDelay: Double = 0,
        initialRows: [ChatTimelineRow] = []
    ) {
        self.scenario = scenario
        self.timeScale = timeScale
        self.stagingDelay = stagingDelay
        self.rows = initialRows
        self.turnCount = initialRows.filter(\.isUser).count
    }

    // MARK: - ChatTimelineSource

    func updates() -> AsyncStream<ChatUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatUpdate.self)
        self.continuation?.finish()
        self.continuation = continuation
        continuation.yield(snapshot(connection: .live))
        return stream
    }

    @discardableResult
    func send(text: String) -> Bool {
        sentMessages.append(text)
        turnCount += 1
        stopRequested = false
        let turn = turnCount
        let userRow = ChatTimelineRow(
            id: "user:\(turn)",
            turnId: "turn-\(turn)",
            kind: .user(text: text, imageDataUris: [], delivery: .pending)
        )
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.runTurn(turn, userRow: userRow)
        }
        return true
    }

    func stop() {
        stopCount += 1
        stopRequested = true
        setPhase(.stopping)
    }

    func answer(_ answer: ChatQuestionAnswer) {
        answeredOptions.append(answer.option)
    }

    /// Waits for the current scripted turn to finish. For tests.
    func waitForIdle() async {
        await runTask?.value
    }

    // MARK: - Script

    private func runTurn(_ turn: Int, userRow: ChatTimelineRow) async {
        let startedAt = ContinuousClock.now
        if stagingDelay > 0 {
            try? await Task.sleep(for: .milliseconds(Int(stagingDelay * 1000)))
        }
        upsert([userRow])
        setPhase(.queued)

        await pause(0.7)
        upsert([ChatTimelineRow(
            id: userRow.id,
            turnId: userRow.turnId,
            kind: .user(text: userText(userRow), imageDataUris: [], delivery: .sent)
        )])
        setPhase(.accepted)

        await pause(0.45)
        setPhase(.thinking, progress: "Reading your message")

        await pause(1.0)
        if stopRequested { return await finishStopped(turn, startedAt: startedAt) }

        let workID = "work-\(turn)"
        var entries = [
            ChatWorkEntry(
                itemId: "\(workID)-search",
                kind: .search,
                title: "Searching 4 sources",
                detail: nil,
                status: .inProgress
            ),
        ]
        upsert([workRow(workID, entries)])
        setPhase(.acting)

        await pause(1.3)
        entries[0].title = "Searched 4 sources"
        entries[0].detail = "Neuralink trial updates, Utah array reviews, glial scarring studies, decoder drift papers"
        entries[0].status = .completed
        entries.append(ChatWorkEntry(
            itemId: "\(workID)-reasoning",
            kind: .reasoning,
            title: "Planned the reply",
            detail: "Start from what the learner guessed, correct it gently, then name the physical bottlenecks before asking where to go deep.",
            status: .completed
        ))

        if scenario == .failure {
            entries.append(ChatWorkEntry(
                itemId: "\(workID)-outline",
                kind: .command,
                title: "Draft course outline",
                detail: "The model stopped responding after 30 seconds.",
                status: .failed
            ))
            upsert([workRow(workID, entries)])
            await pause(0.5)
            upsert([foldRow(turn, label: "Worked for \(elapsed(since: startedAt))s", folding: [workID])])
            setPhase(.settled(outcome: .failed(message: "The model stopped responding. Try sending again.")))
            return
        }

        upsert([workRow(workID, entries)])
        if stopRequested { return await finishStopped(turn, startedAt: startedAt) }

        await pause(0.3)
        let answerID = "answer-\(turn)"
        upsert([ChatTimelineRow(id: answerID, kind: .answer(text: "", isStreaming: true, agentLabel: nil))])
        setPhase(.streaming)

        var wordCount = 0
        let paragraphs = scenario == .brief ? [Self.answerParagraphs[0]] : Self.answerParagraphs
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            let words = paragraph.split(separator: " ", omittingEmptySubsequences: false)
            for (index, word) in words.enumerated() {
                if Task.isCancelled { return }
                if stopRequested { return await finishStopped(turn, startedAt: startedAt) }
                let prefix = index == 0 ? (paragraphIndex == 0 ? "" : "\n\n") : " "
                appendText(prefix + word, to: answerID)
                wordCount += 1
                if scenario == .interrupt, wordCount == 70 {
                    if let onAutoStop { onAutoStop() } else { stopRequested = true }
                }
                await pause(0.035)
            }
            await pause(0.2)

            if scenario == .reconnect, paragraphIndex == 1 {
                setPhase(.streaming, progress: "Reconnecting... 1/5")
                emit(.connectionChanged(connection: .reconnecting, seq: nextSeq()))
                await pause(1.6)
                emit(.connectionChanged(connection: .syncing, seq: nextSeq()))
                await pause(0.6)
                emit(snapshot(connection: .live))
                setPhase(.streaming)
            }
        }

        upsert([ChatTimelineRow(id: answerID, kind: .answer(
            text: paragraphs.joined(separator: "\n\n"),
            isStreaming: false,
            agentLabel: nil
        ))])
        if scenario != .brief {
            upsert([ChatTimelineRow(
                id: "question-\(turn)",
                kind: .question(
                    prompt: "Which part should the course go deepest on?",
                    options: ["Signal decoding", "Electrode materials", "Brain aging and repair"],
                    isPending: true,
                    allowsFreeText: true,
                    requestId: nil,
                    questionId: nil,
                    sourceItemId: answerID
                )
            )])
        }
        await pause(0.5)
        upsert([foldRow(turn, label: "Worked for \(elapsed(since: startedAt))s", folding: [workID])])
        setPhase(.settled(outcome: .completed))
    }

    private func finishStopped(_ turn: Int, startedAt: ContinuousClock.Instant) async {
        setPhase(.stopping)
        await pause(0.7)
        upsert([foldRow(turn, label: "You stopped after \(elapsed(since: startedAt))s", folding: ["work-\(turn)"])])
        setPhase(.settled(outcome: .interrupted))
    }

    // MARK: - Emitting

    private func emit(_ update: ChatUpdate) {
        continuation?.yield(update)
    }

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func snapshot(connection: ChatConnectionPhase) -> ChatUpdate {
        .snapshot(
            rows: rows,
            phase: phase,
            connection: connection,
            progressLabel: progressLabel,
            activeTurnStartedAtMs: nil,
            seq: nextSeq()
        )
    }

    private func setPhase(_ newPhase: ChatTurnPhase, progress: String? = nil) {
        phase = newPhase
        progressLabel = progress
        emit(.phaseChanged(phase: newPhase, progressLabel: progress, activeTurnStartedAtMs: nil, seq: nextSeq()))
    }

    private func userText(_ row: ChatTimelineRow) -> String {
        if case .user(let text, _, _) = row.kind { return text }
        return ""
    }

    private func workRow(_ id: String, _ entries: [ChatWorkEntry]) -> ChatTimelineRow {
        ChatTimelineRow(id: id, kind: .work(
            summary: entries.last?.title ?? "",
            entries: entries,
            isLive: entries.contains { $0.status == .inProgress },
            hasFailure: entries.contains { $0.status == .failed }
        ))
    }

    private func foldRow(_ turn: Int, label: String, folding: [String]) -> ChatTimelineRow {
        ChatTimelineRow(id: "fold-\(turn)", kind: .fold(
            label: label,
            durationMs: nil,
            foldedRowIds: folding.filter { id in rows.contains { $0.id == id } }
        ))
    }

    private func upsert(_ changed: [ChatTimelineRow]) {
        for row in changed {
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index] = row
            } else {
                rows.append(row)
            }
        }
        emit(.rowsChanged(upserts: changed, removals: [], order: rows.map(\.id), seq: nextSeq()))
    }

    private func appendText(_ text: String, to rowID: String) {
        if let index = rows.firstIndex(where: { $0.id == rowID }),
           case .answer(let current, let streaming, let label) = rows[index].kind {
            rows[index] = ChatTimelineRow(id: rowID, kind: .answer(text: current + text, isStreaming: streaming, agentLabel: label))
        }
        emit(.textAppended(rowId: rowID, text: text, digest: 0, seq: nextSeq()))
    }

    private func pause(_ seconds: Double) async {
        let scaled = seconds * timeScale
        if scaled <= 0 {
            await Task.yield()
            return
        }
        try? await Task.sleep(for: .milliseconds(Int(scaled * 1000)))
    }

    private func elapsed(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return max(1, Int(seconds.rounded()))
    }
}

extension FixtureChatSource {
    static let answerParagraphs = [
        "Close. An electrode doesn’t read thoughts. It picks up tiny voltage changes when nearby neurons fire, and a **decoder** learns which firing patterns line up with an intended movement.",
        "The hard parts are physical. Scar tissue builds around implants within months, each electrode hears only a few neurons out of billions, and signals drift from day to day, so decoders need constant recalibration.",
        "Researchers are attacking this from three sides:\n\n- **Softer materials** such as thin polymer threads that flex with the brain instead of fighting it.\n- **More channels**, so losing a few electrodes matters less.\n- **Adaptive decoders** that retrain quietly while you use them.",
        "As for immortality, today’s interfaces restore lost functions like movement or speech. Copying a whole mind would need recording from every one of roughly 86 billion neurons at once, which is far beyond anything on the horizon.",
    ]

    /// A settled earlier exchange, so the harness can show the previous turn
    /// giving up its reserved space when a new message is sent.
    static let historyRows: [ChatTimelineRow] = [
        ChatTimelineRow(
            id: "user:history-1",
            kind: .user(
                text: "Hey I wanna learn about biology and what’s preventing brain computer interfaces",
                imageDataUris: [],
                delivery: .sent
            )
        ),
        ChatTimelineRow(
            id: "history-fold-1",
            kind: .fold(label: "Worked for 6s", durationMs: 6000, foldedRowIds: ["history-work-1"])
        ),
        ChatTimelineRow(
            id: "history-work-1",
            kind: .work(
                summary: "Searched 2 sources",
                entries: [
                    ChatWorkEntry(itemId: "history-work-1-search", kind: .search, title: "Searched 2 sources", detail: nil, status: .completed),
                ],
                isLive: false,
                hasFailure: false
            )
        ),
        ChatTimelineRow(
            id: "history-answer-1",
            kind: .answer(text: "Let’s shape this around neuroscience, brain–computer interfaces, their current bottlenecks, and the realistic science behind “immortality.”\n\nTo calibrate the technical depth: in your own words, how do you think a brain–computer interface reads information from neurons?", isStreaming: false, agentLabel: nil)
        ),
    ]
}
#endif
