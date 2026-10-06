import XCTest
@testable import Litter

@MainActor
final class ChatScreenModelTests: XCTestCase {
    // MARK: - Grouping

    func testSnapshotGroupsRowsByUserMessage() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [
                row("intro", notice("Welcome")),
                row("user:c1", user("First")),
                row("w1", work()),
                row("a1", answer("Reply one")),
                row("fold:t1", fold("Worked for 3s", folding: ["w1"])),
                row("user:u2", user("Second")),
                row("a2", answer("Reply two")),
            ],
            phase: .idle
        ))

        XCTAssertEqual(model.turns.map(\.id), [ChatTurn.preambleID, "user:c1", "user:u2"])
        XCTAssertNil(model.turns[0].user)
        XCTAssertEqual(model.turns[0].rows.map(\.id), ["intro"])
        XCTAssertEqual(model.turns[1].rows.map(\.id), ["w1", "a1", "fold:t1"])
        XCTAssertTrue(model.turns[1].hasFold)
        XCTAssertEqual(model.turns[2].rows.map(\.id), ["a2"])
        XCTAssertNil(model.liveTurnID, "Restored history has no live turn")
        XCTAssertEqual(model.buffer(for: "a1")?.text, "Reply one")
    }

    func testActiveSnapshotMakesLastTurnLive() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [row("user:c1", user("Hi")), row("a1", answer("He", streaming: true))],
            phase: .streaming,
            progress: "Waiting on model…"
        ))
        XCTAssertEqual(model.liveTurnID, "user:c1")
        XCTAssertEqual(model.phase, .streaming)
        XCTAssertEqual(model.progressLabel, "Waiting on model…")
    }

    // MARK: - Sequence numbers

    func testUpdatesAtOrBelowTheSnapshotSeqAreDropped() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("a1", answer("Hello"))], phase: .streaming, seq: 10))
        model.apply(.textAppended(rowId: "a1", text: " stale", digest: 0, seq: 9))
        model.apply(.phaseChanged(phase: .idle, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 10))
        XCTAssertEqual(model.buffer(for: "a1")?.text, "Hello")
        XCTAssertEqual(model.phase, .streaming)

        model.apply(.textAppended(rowId: "a1", text: " world", digest: 0, seq: 11))
        XCTAssertEqual(model.buffer(for: "a1")?.text, "Hello world")

        // A new snapshot resets the floor, even to a lower number.
        model.apply(snapshot(rows: [row("a1", answer("Hello world"))], phase: .idle, seq: 2))
        model.apply(.phaseChanged(phase: .thinking, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 3))
        XCTAssertEqual(model.phase, .thinking)
    }

    func testRowsChangedFollowsRustOrder() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("q")), row("a1", answer("x"))], phase: .idle))
        model.apply(.rowsChanged(
            upserts: [row("w1", work())],
            removals: [],
            order: ["user:c1", "w1", "a1"],
            seq: 2
        ))
        XCTAssertEqual(model.turns.last?.rows.map(\.id), ["w1", "a1"])
    }

    // MARK: - Sending

    func testSendRoutesToSourceAndShowsPreviewUntilRustStagesTheRow() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())

        XCTAssertTrue(model.send("  Teach me cells  "))

        XCTAssertEqual(source.sent, ["Teach me cells"])
        XCTAssertEqual(model.localPreviewText, "Teach me cells")
        XCTAssertEqual(model.turns.map(\.id), [ChatTurn.localPreviewID])
        XCTAssertEqual(model.liveTurnID, ChatTurn.localPreviewID)
        XCTAssertEqual(model.sendGeneration, 1)

        model.apply(.rowsChanged(
            upserts: [row("user:c1", user("Teach me cells", delivery: .pending))],
            removals: [],
            order: ["user:c1"],
            seq: 1
        ))
        model.apply(.phaseChanged(phase: .queued, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 2))

        XCTAssertNil(model.localPreviewText, "Rust's optimistic row replaces the preview")
        XCTAssertEqual(model.turns.map(\.id), ["user:c1"], "One bubble, never two")
        XCTAssertEqual(model.liveTurnID, "user:c1")
        XCTAssertEqual(model.phase, .queued)

        // Accepting the message keeps the row id.
        model.apply(.rowsChanged(
            upserts: [row("user:c1", user("Teach me cells"))],
            removals: [],
            order: ["user:c1"],
            seq: 3
        ))
        XCTAssertEqual(model.turns.map(\.id), ["user:c1"])
        XCTAssertEqual(model.liveTurnID, "user:c1")
    }

    func testSendIsRefusedWhileTurnIsActive() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("one"))], phase: .thinking))
        XCTAssertFalse(model.send("two"))
        XCTAssertFalse(model.send("   "))
        XCTAssertTrue(source.sent.isEmpty)
    }

    func testRefusedSendKeepsNoPreview() {
        let source = RecordingSource()
        source.accepts = false
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        XCTAssertFalse(model.send("hello"))
        XCTAssertNil(model.localPreviewText)
        XCTAssertTrue(model.turns.isEmpty)
    }

    func testDroppedPendingRowRestoresTheDraft() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.send("hello")
        model.apply(.rowsChanged(
            upserts: [row("user:c1", user("hello", delivery: .pending))],
            removals: [],
            order: ["user:c1"],
            seq: 1
        ))
        model.apply(.rowsChanged(upserts: [], removals: ["user:c1"], order: [], seq: 2))
        model.apply(.phaseChanged(phase: .idle, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 3))

        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertTrue(model.canSend)
    }

    // MARK: - Review fixes

    func testAwaitingInputStraightFromStreamingFinishesTheAnswer() {
        let renderer = RecordingRenderer()
        let model = ChatScreenModel(source: RecordingSource(), renderer: renderer)
        model.apply(snapshot(
            rows: [row("user:c1", user("one")), row("a1", answer("", streaming: true))],
            phase: .streaming
        ))
        model.apply(.textAppended(rowId: "a1", text: "Which topic?", digest: 1, seq: 2))
        XCTAssertTrue(model.isStreaming(rowID: "a1"))

        // Rust settles and asks for input in one batch.
        model.apply(.rowsChanged(
            upserts: [row("a1", answer("Which topic?")), row("q1", question("Which topic?"))],
            removals: [],
            order: ["user:c1", "a1", "q1"],
            seq: 3
        ))
        model.apply(.phaseChanged(phase: .awaitingInput, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 4))

        XCTAssertNil(model.streamingRowID)
        XCTAssertFalse(model.isStreaming(rowID: "a1"))
        XCTAssertEqual(renderer.finished, [ChatScreenModel.rendererItemID(for: "a1")])
        XCTAssertFalse(model.phase.isWorking, "Awaiting input looks settled")
        XCTAssertEqual(model.answerableQuestionRowID, "q1")
    }

    func testDeltaWhileAwaitingInputDoesNotRestartStreaming() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [row("user:c1", user("one")), row("a1", answer("Done"))],
            phase: .awaitingInput
        ))
        model.apply(.textAppended(rowId: "a1", text: ".", digest: 1, seq: 2))
        XCTAssertNil(model.streamingRowID)
        XCTAssertFalse(model.isStreaming(rowID: "a1"))
    }

    func testPendingSendSurvivesAModelSwap() {
        let first = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        first.noteLocalSend(previewText: "Teach me OLED")

        let second = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        second.continuePendingSend(from: first)
        XCTAssertEqual(second.localPreviewText, "Teach me OLED")
        XCTAssertEqual(second.sendGeneration, first.sendGeneration)
        XCTAssertEqual(second.turns.map(\.id), [ChatTurn.localPreviewID])
        XCTAssertEqual(second.liveTurnID, ChatTurn.localPreviewID)

        // The new thread's first snapshot predates the staged message.
        second.apply(snapshot(rows: [], phase: .idle))
        XCTAssertEqual(second.localPreviewText, "Teach me OLED")
        XCTAssertEqual(second.turns.map(\.id), [ChatTurn.localPreviewID])

        second.apply(.rowsChanged(
            upserts: [row("user:c1", user("Teach me OLED", delivery: .pending))],
            removals: [],
            order: ["user:c1"],
            seq: 2
        ))
        XCTAssertNil(second.localPreviewText)
        XCTAssertEqual(second.turns.map(\.id), ["user:c1"])
        XCTAssertEqual(second.liveTurnID, "user:c1")
    }

    func testStagedMessageKeepsThePreviewsViewIdentity() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        XCTAssertTrue(model.send("First"))
        let firstPreview = model.turns.last?.viewID
        XCTAssertNotNil(firstPreview)
        model.apply(.rowsChanged(
            upserts: [row("user:c1", user("First", delivery: .pending))],
            removals: [],
            order: ["user:c1"],
            seq: 1
        ))
        XCTAssertEqual(model.turns.map(\.id), ["user:c1"])
        XCTAssertEqual(model.turns.map(\.viewID), [firstPreview], "Staging doesn't replace the bubble's view")

        model.apply(.phaseChanged(phase: .settled(outcome: .completed), progressLabel: nil, activeTurnStartedAtMs: nil, seq: 2))
        XCTAssertTrue(model.send("Second"))
        let secondPreview = model.turns.last?.viewID
        XCTAssertNotEqual(secondPreview, firstPreview, "Each send gets its own preview identity")
        XCTAssertEqual(model.turns.map(\.viewID), [firstPreview, secondPreview])
    }

    func testModelSwapKeepsThePreviewsViewIdentityThroughStaging() {
        let first = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        first.noteLocalSend(previewText: "Teach me OLED")
        let previewViewID = first.turns.last?.viewID

        let second = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        second.continuePendingSend(from: first)
        XCTAssertEqual(second.previewViewID, first.previewViewID)
        XCTAssertEqual(second.turns.map(\.viewID), [previewViewID])

        // The new thread's snapshot already has the staged message, before
        // its turn starts.
        second.apply(snapshot(rows: [row("user:c1", user("Teach me OLED", delivery: .pending))], phase: .idle))
        XCTAssertNil(second.localPreviewText)
        XCTAssertEqual(second.turns.map(\.viewID), [previewViewID])
        XCTAssertEqual(second.liveTurnID, "user:c1", "The staged message keeps the preview's reserve")
    }

    func testModelSwapWithoutAPendingSendCarriesNothing() {
        let first = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        let second = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        second.continuePendingSend(from: first)
        XCTAssertNil(second.localPreviewText)
        XCTAssertEqual(second.sendGeneration, 0)
        XCTAssertTrue(second.turns.isEmpty)
    }

    func testTypedTextAnswersAPendingRequest() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [
                row("user:c1", user("a")),
                row("q1", question("Depth?", requestID: "req-1", questionID: "depth")),
            ],
            phase: .awaitingInput
        ))
        XCTAssertTrue(model.awaitsRequestAnswer)
        XCTAssertTrue(model.send("Somewhere in between"))
        XCTAssertEqual(
            source.answers,
            [ChatQuestionAnswer(requestID: "req-1", questionID: "depth", option: "Somewhere in between")]
        )
        XCTAssertTrue(source.sent.isEmpty)
    }

    func testProseQuestionDoesNotAwaitARequestAnswer() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [row("user:c1", user("a")), row("q1", question("Depth?"))],
            phase: .awaitingInput
        ))
        XCTAssertFalse(model.awaitsRequestAnswer)
    }

    func testProseOptionGoesThroughTheHostSendWhenGiven() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [row("user:c1", user("a")), row("q1", question("Depth?"))],
            phase: .awaitingInput
        ))
        var hostSent: [String] = []
        XCTAssertTrue(model.choose(option: "Deep", rowID: "q1", sendMessage: { hostSent.append($0); return true }))
        XCTAssertEqual(hostSent, ["Deep"])
        XCTAssertTrue(source.sent.isEmpty)
    }

    func testErrorNoticesHideOnlyWhenTheHostShowsTheError() {
        let rows = [
            row("a1", answer("Partial")),
            row("turn-error:t1", .notice(tone: .error, title: "The agent stopped", message: "boom")),
            row("n1", notice("Info")),
        ]
        XCTAssertEqual(
            TurnSection.displayRows(rows, showsFoldedWork: false, hidesErrorNotices: false).map(\.id),
            ["a1", "turn-error:t1", "n1"]
        )
        XCTAssertEqual(
            TurnSection.displayRows(rows, showsFoldedWork: false, hidesErrorNotices: true).map(\.id),
            ["a1", "n1"]
        )
    }

    func testReopeningASourceKeepsTheNewSubscription() async throws {
        let store = AppStore()
        let key = appleChatThreadKey(sessionId: "reopen-\(UUID().uuidString)")
        let source = RustChatTimelineSource(
            store: store,
            key: key,
            routing: ChatIntentRouting(send: { _ in false }, stop: {}, respondToRequest: { _, _, _ in })
        )
        let first = source.updates()
        let second = source.updates()
        // The first stream ends because `updates()` superseded it; its
        // termination must not close the second subscription.
        for await _ in first {}
        for _ in 0..<20 { await Task.yield() }

        var iterator = second.makeAsyncIterator()
        guard case .snapshot? = await iterator.next() else {
            return XCTFail("Expected the opening snapshot")
        }
        store.ingestSourceEvents(
            key: key,
            source: .apple,
            events: [.userMessage(clientMsgId: "c1", text: "Still live?")]
        )
        let update = await iterator.next()
        XCTAssertNotNil(update, "The reopened subscription still delivers updates")
    }

    func testPreviewClearsWhenTheSourceRestsWithoutStagingIt() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.send("hello")
        model.apply(.phaseChanged(
            phase: .settled(outcome: .failed(message: "Send failed")),
            progressLabel: nil,
            activeTurnStartedAtMs: nil,
            seq: 1
        ))
        XCTAssertNil(model.localPreviewText)
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertTrue(model.canSend)
    }

    func testExternalSendShowsPreviewAndArmsHandOff() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.noteLocalSend(previewText: "From the course composer")
        XCTAssertEqual(model.turns.map(\.id), [ChatTurn.localPreviewID])
        XCTAssertEqual(model.sendGeneration, 1)
        model.setLocalPreview(nil)
        XCTAssertTrue(model.turns.isEmpty)
        XCTAssertNil(model.liveTurnID)
    }

    // MARK: - Questions

    func testOptionForRequestQuestionAnswersTheRequest() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [
                row("user:c1", user("a")),
                row("q1", question("Depth?", requestID: "req-1", questionID: "depth")),
            ],
            phase: .awaitingInput
        ))
        XCTAssertEqual(model.answerableQuestionRowID, "q1")
        XCTAssertTrue(model.choose(option: "Deep", rowID: "q1"))
        XCTAssertEqual(source.answers, [ChatQuestionAnswer(requestID: "req-1", questionID: "depth", option: "Deep")])
        XCTAssertTrue(source.sent.isEmpty)
    }

    func testOptionForProseQuestionIsTheNextMessage() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [row("user:c1", user("a")), row("q1", question("Depth?"))],
            phase: .awaitingInput
        ))
        XCTAssertTrue(model.choose(option: "Deep", rowID: "q1"))
        XCTAssertEqual(source.sent, ["Deep"])
        XCTAssertTrue(source.answers.isEmpty)
    }

    func testAnswerableQuestionIsOnlyTheNewestWhenNotBusy() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(
            rows: [
                row("user:u1", user("a")),
                row("q1", question("Old?")),
                row("user:u2", user("b")),
                row("q2", question("New?")),
            ],
            phase: .idle
        ))
        XCTAssertEqual(model.answerableQuestionRowID, "q2")

        model.apply(.phaseChanged(phase: .thinking, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 2))
        XCTAssertNil(model.answerableQuestionRowID, "No options while a turn runs")
    }

    // MARK: - Lifecycle

    func testTearDownStopsApplyingUpdatesAndReleasesRenderers() async {
        let renderer = RecordingRenderer()
        let source = FixtureChatSource(scenario: .happy, timeScale: 0)
        let model = ChatScreenModel(source: source, renderer: renderer)
        model.start()
        model.send("q")
        await waitUntil { model.buffer(for: "answer-1")?.text.isEmpty == false }

        model.tearDown()
        let frozen = model.buffer(for: "answer-1")?.text
        let frozenPhase = model.phase
        await source.waitForIdle()
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(model.buffer(for: "answer-1")?.text, frozen, "No deltas after tearDown")
        XCTAssertEqual(model.phase, frozenPhase, "No phase changes after tearDown")
        XCTAssertTrue(renderer.finished.contains(ChatScreenModel.rendererItemID(for: "answer-1")))
    }

    func testRestartAfterTearDownResyncsFromSnapshot() async {
        let source = FixtureChatSource(scenario: .happy, timeScale: 0)
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.start()
        model.send("q")
        await waitUntil { model.buffer(for: "answer-1")?.text.isEmpty == false }
        model.tearDown()
        await source.waitForIdle()

        model.start()
        await waitUntil { model.phase == .settled(outcome: .completed) }
        XCTAssertEqual(model.phase, .settled(outcome: .completed))
        XCTAssertEqual(
            model.buffer(for: "answer-1")?.text,
            FixtureChatSource.answerParagraphs.joined(separator: "\n\n")
        )
        XCTAssertEqual(model.turns.map(\.id), ["user:1"])
    }

    func testDeltaForUnannouncedRowCreatesAnAnswerRow() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("q"))], phase: .streaming))
        model.apply(.textAppended(rowId: "late", text: "Hi", digest: 0, seq: 2))

        XCTAssertEqual(model.turns.last?.rows.map(\.id), ["late"])
        XCTAssertEqual(model.buffer(for: "late")?.text, "Hi")
        XCTAssertEqual(model.streamingRowID, "late")
    }

    // MARK: - Streaming

    func testTextAppendedChangesOnlyTheRowBuffer() {
        let renderer = RecordingRenderer()
        let model = ChatScreenModel(source: RecordingSource(), renderer: renderer)
        model.apply(snapshot(
            rows: [row("user:c1", user("q")), row("a1", answer("", streaming: true))],
            phase: .streaming
        ))
        let turnsBefore = model.turns

        model.apply(.textAppended(rowId: "a1", text: "Neurons ", digest: 1, seq: 2))
        model.apply(.textAppended(rowId: "a1", text: "fire ", digest: 2, seq: 3))
        model.apply(.textAppended(rowId: "a1", text: "spikes.", digest: 3, seq: 4))

        XCTAssertEqual(model.turns, turnsBefore, "Tokens must not touch the turn list")
        XCTAssertEqual(model.buffer(for: "a1")?.text, "Neurons fire spikes.")
        XCTAssertEqual(model.streamingRowID, "a1")
        XCTAssertTrue(model.isStreaming(rowID: "a1"))
        XCTAssertEqual(renderer.appended.map(\.delta), ["Neurons ", "fire ", "spikes."])
        XCTAssertEqual(Set(renderer.appended.map(\.itemID)), [ChatScreenModel.rendererItemID(for: "a1")])
    }

    func testSettlingReleasesTheStreamingRow() {
        let renderer = RecordingRenderer()
        let model = ChatScreenModel(source: RecordingSource(), renderer: renderer)
        model.apply(snapshot(
            rows: [row("user:c1", user("one")), row("a1", answer("", streaming: true))],
            phase: .streaming
        ))
        model.apply(.textAppended(rowId: "a1", text: "Answer one", digest: 1, seq: 2))
        model.apply(.phaseChanged(phase: .settled(outcome: .completed), progressLabel: nil, activeTurnStartedAtMs: nil, seq: 3))

        XCTAssertNil(model.streamingRowID)
        XCTAssertFalse(model.isStreaming(rowID: "a1"))
        XCTAssertEqual(renderer.finished, [ChatScreenModel.rendererItemID(for: "a1")], "Settling releases the renderer")
        XCTAssertEqual(model.liveTurnID, "user:c1", "A settled turn keeps its reserve until the next turn")
    }

    func testNextTurnMovesTheLiveTurn() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("one")), row("a1", answer("x"))], phase: .idle))
        model.apply(.rowsChanged(
            upserts: [row("user:c2", user("two", delivery: .pending))],
            removals: [],
            order: ["user:c1", "a1", "user:c2"],
            seq: 2
        ))
        XCTAssertEqual(model.liveTurnID, "user:c2")
        XCTAssertEqual(model.turns.map(\.id), ["user:c1", "user:c2"])
    }

    func testSnapshotResyncExtendsOrReplacesBufferText() {
        let renderer = RecordingRenderer()
        let model = ChatScreenModel(source: RecordingSource(), renderer: renderer)
        let userRow = row("user:c1", user("q"))
        model.apply(snapshot(rows: [userRow, row("a1", answer("", streaming: true))], phase: .streaming))
        model.apply(.textAppended(rowId: "a1", text: "Hello", digest: 1, seq: 2))
        let buffer = try! XCTUnwrap(model.buffer(for: "a1"))

        model.apply(snapshot(rows: [userRow, row("a1", answer("Hello world", streaming: true))], phase: .streaming, seq: 3))
        XCTAssertTrue(model.buffer(for: "a1") === buffer, "Resync keeps the same buffer object")
        XCTAssertEqual(buffer.text, "Hello world")
        XCTAssertEqual(renderer.appended.last?.delta, " world")
        XCTAssertEqual(buffer.generation, 0)

        // A stale copy behind the live text is ignored.
        model.apply(snapshot(rows: [userRow, row("a1", answer("Hello", streaming: true))], phase: .streaming, seq: 4))
        XCTAssertEqual(buffer.text, "Hello world")

        // A different text replaces and restarts the renderer.
        model.apply(snapshot(rows: [userRow, row("a1", answer("Rewritten", streaming: true))], phase: .streaming, seq: 5))
        XCTAssertEqual(buffer.text, "Rewritten")
        XCTAssertEqual(buffer.generation, 1)
        XCTAssertTrue(renderer.finished.contains(ChatScreenModel.rendererItemID(for: "a1")))
    }

    func testRemovedRowsReleaseBuffersAndRenderers() {
        let renderer = RecordingRenderer()
        let model = ChatScreenModel(source: RecordingSource(), renderer: renderer)
        model.apply(snapshot(rows: [row("a1", answer("x"))], phase: .idle))
        model.apply(.rowsChanged(upserts: [], removals: ["a1"], order: [], seq: 2))

        XCTAssertNil(model.buffer(for: "a1"))
        XCTAssertEqual(renderer.finished, [ChatScreenModel.rendererItemID(for: "a1")])
        XCTAssertTrue(model.turns.isEmpty)
    }

    // MARK: - Phase and connection

    func testConnectionChangesNeverChangeThePhase() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("q"))], phase: .thinking))
        model.apply(.connectionChanged(connection: .reconnecting, seq: 2))
        XCTAssertEqual(model.phase, .thinking)
        XCTAssertEqual(model.connection, .reconnecting)
        model.apply(.connectionChanged(connection: .live, seq: 3))
        XCTAssertEqual(model.phase, .thinking)
    }

    func testStopReachesTheSourceOnlyWhileStoppable() {
        let source = RecordingSource()
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        model.stop()
        XCTAssertEqual(source.stopCount, 0, "Nothing to stop while idle")

        model.apply(snapshot(rows: [row("user:c1", user("q"))], phase: .streaming))
        model.stop()
        XCTAssertEqual(source.stopCount, 1)
        model.apply(.phaseChanged(phase: .stopping, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 2))
        model.stop()
        XCTAssertEqual(source.stopCount, 1, "Stopping twice sends one stop")
    }

    func testProgressLabelComesWithThePhaseAndClearsWhenSettled() {
        let model = ChatScreenModel(source: RecordingSource(), renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("q"))], phase: .queued))
        model.apply(.phaseChanged(phase: .thinking, progressLabel: "Waiting on model…", activeTurnStartedAtMs: 1_000, seq: 2))
        XCTAssertEqual(model.progressLabel, "Waiting on model…")
        XCTAssertEqual(model.activeTurnStartedAt, Date(timeIntervalSince1970: 1))
        model.apply(.phaseChanged(phase: .settled(outcome: .completed), progressLabel: "late", activeTurnStartedAtMs: nil, seq: 3))
        XCTAssertNil(model.progressLabel)
    }

    func testPhasePresentationTable() {
        XCTAssertEqual(ChatPhasePresentation.make(phase: .idle, progress: nil).style, .none)
        let queued = ChatPhasePresentation.make(phase: .queued, progress: nil)
        XCTAssertEqual(queued.style, .caption)
        XCTAssertTrue(queued.trailing)
        let thinking = ChatPhasePresentation.make(phase: .thinking, progress: "Reading")
        XCTAssertEqual(thinking.style, .shimmer)
        XCTAssertEqual(thinking.subtitle, "Reading")
        XCTAssertEqual(ChatPhasePresentation.make(phase: .streaming, progress: nil).style, .none)
        XCTAssertEqual(ChatPhasePresentation.make(phase: .acting, progress: nil).style, .none)
        XCTAssertEqual(ChatPhasePresentation.make(phase: .stopping, progress: nil).label, "Stopping…")
        let failed = ChatPhasePresentation.make(phase: .settled(outcome: .failed(message: "Boom")), progress: nil)
        XCTAssertEqual(failed.style, .error)
        XCTAssertEqual(failed.label, "Boom")
        XCTAssertNil(ChatConnectionPresentation.make(.live))
        XCTAssertEqual(ChatConnectionPresentation.make(.reconnecting)?.label, "Reconnecting…")
    }

    func testRetryProgressDisappearsWhileTheSameTurnKeepsStreaming() {
        let model = ChatScreenModel(source: nil, renderer: RecordingRenderer())
        model.apply(snapshot(rows: [row("user:c1", user("q")), row("a1", answer("Partial"))], phase: .streaming))
        model.apply(.phaseChanged(phase: .streaming, progressLabel: "Reconnecting... 1/5", activeTurnStartedAtMs: nil, seq: 2))
        for phase in [ChatTurnPhase.streaming, .acting] {
            let presentation = ChatPhasePresentation.make(phase: phase, progress: model.progressLabel)
            XCTAssertEqual(presentation.style, .caption)
            XCTAssertEqual(presentation.label, "Reconnecting... 1/5")
        }

        model.apply(.phaseChanged(phase: .streaming, progressLabel: nil, activeTurnStartedAtMs: nil, seq: 3))
        XCTAssertEqual(model.phase, .streaming)
        XCTAssertNil(model.progressLabel)
        XCTAssertEqual(ChatPhasePresentation.make(phase: model.phase, progress: model.progressLabel).style, .none)
        XCTAssertEqual(model.turns[0].rows.map(\.id), ["a1"])
    }

    // MARK: - Fixture scenarios

    func testFixtureHappyPathSettlesWithQuestionAndFold() async {
        let (model, source) = makeFixture(.happy)
        model.send("How do BCIs work?")
        await source.waitForIdle()
        await waitUntil { model.phase == .settled(outcome: .completed) }

        XCTAssertEqual(model.turns.map(\.id), ["user:1"])
        XCTAssertEqual(model.liveTurnID, "user:1")
        XCTAssertEqual(model.turns[0].rows.map(kindName), ["work", "answer", "question", "fold"])
        XCTAssertEqual(
            model.buffer(for: "answer-1")?.text,
            FixtureChatSource.answerParagraphs.joined(separator: "\n\n")
        )
        XCTAssertEqual(model.answerableQuestionRowID, "question-1")
        XCTAssertNil(model.streamingRowID)
    }

    func testFixtureInterruptSettlesAsInterrupted() async {
        let (model, source) = makeFixture(.interrupt)
        model.send("q")
        await source.waitForIdle()
        await waitUntil { !model.phase.isActive }

        XCTAssertEqual(model.phase, .settled(outcome: .interrupted))
        XCTAssertEqual(source.stopCount, 1)
        guard case .fold(let label, _, _)? = model.turns[0].rows.last?.kind else {
            return XCTFail("Expected a fold row")
        }
        XCTAssertTrue(label.hasPrefix("You stopped after"), label)
        let text = model.buffer(for: "answer-1")?.text ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThan(text.count, FixtureChatSource.answerParagraphs.joined(separator: "\n\n").count)
    }

    func testFixtureFailureSettlesAsFailed() async {
        let (model, source) = makeFixture(.failure)
        model.send("q")
        await source.waitForIdle()
        await waitUntil {
            if case .settled(.failed) = model.phase { return true }
            return false
        }

        guard case .settled(.failed(let message)) = model.phase else {
            return XCTFail("Expected failure, got \(model.phase)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(model.buffer(for: "answer-1"))
    }

    func testFixtureReconnectResyncsWithoutDuplicatingText() async {
        let (model, source) = makeFixture(.reconnect)
        model.send("q")
        await source.waitForIdle()
        await waitUntil { !model.phase.isActive }

        XCTAssertEqual(model.connection, .live)
        XCTAssertEqual(model.phase, .settled(outcome: .completed))
        XCTAssertNil(model.progressLabel)
        XCTAssertEqual(
            model.buffer(for: "answer-1")?.text,
            FixtureChatSource.answerParagraphs.joined(separator: "\n\n")
        )
        XCTAssertEqual(model.turns.map(\.id), ["user:1"])
    }

    func testFixtureChosenOptionStartsTheNextTurn() async {
        let (model, source) = makeFixture(.happy)
        model.send("one")
        await source.waitForIdle()
        await waitUntil { !model.phase.isActive }

        XCTAssertTrue(model.choose(option: "Signal decoding", rowID: "question-1"))
        XCTAssertEqual(source.sentMessages.last, "Signal decoding")
        await source.waitForIdle()
        await waitUntil { model.phase == .settled(outcome: .completed) && model.turns.count == 2 }
        XCTAssertEqual(model.turns.map(\.id), ["user:1", "user:2"])
        XCTAssertEqual(model.liveTurnID, "user:2")
        XCTAssertEqual(model.answerableQuestionRowID, "question-2")
    }

    // MARK: - Helpers

    private func row(_ id: String, _ kind: TimelineRowKind) -> ChatTimelineRow {
        ChatTimelineRow(id: id, kind: kind)
    }

    private func user(_ text: String, delivery: MessageDelivery = .sent) -> TimelineRowKind {
        .user(text: text, imageDataUris: [], delivery: delivery)
    }

    private func answer(_ text: String, streaming: Bool = false) -> TimelineRowKind {
        .answer(text: text, isStreaming: streaming, agentLabel: nil)
    }

    private func work() -> TimelineRowKind {
        .work(summary: "", entries: [], isLive: false, hasFailure: false)
    }

    private func notice(_ title: String) -> TimelineRowKind {
        .notice(tone: .info, title: title, message: nil)
    }

    private func fold(_ label: String, folding: [String]) -> TimelineRowKind {
        .fold(label: label, durationMs: nil, foldedRowIds: folding)
    }

    private func question(_ prompt: String, requestID: String? = nil, questionID: String? = nil) -> TimelineRowKind {
        .question(
            prompt: prompt,
            options: ["x", "y"],
            isPending: true,
            allowsFreeText: true,
            requestId: requestID,
            questionId: questionID,
            sourceItemId: nil
        )
    }

    private func snapshot(
        rows: [ChatTimelineRow],
        phase: ChatTurnPhase,
        progress: String? = nil,
        seq: UInt64 = 1
    ) -> ChatUpdate {
        .snapshot(
            rows: rows,
            phase: phase,
            connection: .live,
            progressLabel: progress,
            activeTurnStartedAtMs: nil,
            seq: seq
        )
    }

    private func kindName(_ row: ChatTimelineRow) -> String {
        switch row.kind {
        case .user: "user"
        case .answer: "answer"
        case .work: "work"
        case .question: "question"
        case .plan: "plan"
        case .notice: "notice"
        case .fold: "fold"
        }
    }

    private func makeFixture(_ scenario: FixtureChatSource.Scenario) -> (ChatScreenModel, FixtureChatSource) {
        let source = FixtureChatSource(scenario: scenario, timeScale: 0)
        let model = ChatScreenModel(source: source, renderer: RecordingRenderer())
        source.onAutoStop = { [weak model] in model?.stop() }
        model.start()
        return (model, source)
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met", file: file, line: line)
    }
}

@MainActor
private final class RecordingRenderer: ChatStreamingRendering {
    var appended: [(delta: String, itemID: String)] = []
    var finished: [String] = []

    func append(_ delta: String, itemID: String) {
        appended.append((delta, itemID))
    }

    func finish(itemID: String) {
        finished.append(itemID)
    }
}

@MainActor
private final class RecordingSource: ChatTimelineSource {
    var sent: [String] = []
    var answers: [ChatQuestionAnswer] = []
    var stopCount = 0
    var accepts = true

    func updates() -> AsyncStream<ChatUpdate> {
        AsyncStream { $0.finish() }
    }

    func send(text: String) -> Bool {
        guard accepts else { return false }
        sent.append(text)
        return true
    }

    func stop() {
        stopCount += 1
    }

    func answer(_ answer: ChatQuestionAnswer) {
        answers.append(answer)
    }
}
