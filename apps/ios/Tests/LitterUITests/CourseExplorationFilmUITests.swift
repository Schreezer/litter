import XCTest

/// Drives the Learnfold launch film's two simulator recordings (REC-A and
/// REC-B in videos/learnfold-launch/review/v2-shotlist.json) on the local
/// reading fixture's film course. Every action fires on a beat clock relative
/// to the clip's T0 and every story moment is logged, so raw footage can be
/// trimmed against the markers.
///
/// Skipped unless `FILM_MARKER_DIR` is set (pass `TEST_RUNNER_FILM_MARKER_DIR`
/// to xcodebuild), so normal test runs never execute it. Run REC-A, then REC-B
/// on the same token: REC-B continues REC-A's course state.
///
/// Output, all in `$FILM_MARKER_DIR`:
/// - `REC-A.markers.jsonl` / `REC-B.markers.jsonl`: one JSON object per line,
///   `{"name", "t_epoch", "kind"}`; taps add `x`/`y` (pt), frames add `x`/`y`/`w`/`h`.
/// - stdout lines `FILM-MARK <name> <epoch>`, `FILM-TAP <name> <epoch> <midX> <midY>`,
///   `FILM-FRAME <id> x y w h`, `FILM-WARN …`, `FILM-LATE …`.
/// - handshake files `ready-<clip>` (written), `rolling-<clip>` (awaited, from
///   the recorder), `cut-<clip>` (written), and `token` (REC-A writes, REC-B reads).
/// - keepAlways screenshot attachments named `P1 …` to `P15 …`.
///
/// Optional runner environment (each passed as `TEST_RUNNER_<NAME>`):
/// - `FILM_DRY_RUN=1`: do not wait for `rolling-<clip>`.
/// - `FILM_STRICT=0`: take-quality checks print `FILM-WARN` instead of failing.
/// - `FILM_TOKEN`: reuse a fixture token instead of REC-A's fresh one.
/// - `FILM_DELAYS_A` (default `7.4,6.0,1.6`), `FILM_DELAYS_B` (default `7.3`):
///   the app's per-fork exploration writing delays.
/// - `FILM_GATED`: comma list of exploration triggers (`go_deeper`,
///   `passage_why`, `own_question`, `nested_go_deeper`, or `all`) the app holds
///   after their delay until this test releases them on their beat (never
///   before the fork they follow), minus `FILM_GATE_LEAD` (default 0.15 s).
///   With gating, delays of `0` are typical.
/// - `FILM_QUIESCENCE=1`: keep XCUITest's wait-for-idle around events.
/// - Timing: `FILM_TAP_LEAD` (0.10 s), `FILM_TYPE_INTERVAL` (0.06 s).
/// - Gestures: `FILM_KEEP_READING_DY` (pt), `FILM_KEEP_READING_SECONDS` (0.75),
///   `FILM_SELECT_DX` (10), `FILM_LONG_PRESS` (0.8), `FILM_HANDLE_DX` (24),
///   `FILM_HANDLE_DY` (10), `FILM_HANDLE_PRESS` (0.2), `FILM_HANDLE_VELOCITY`
///   (1000), `FILM_HANDLE_HOLD` (0.15), `FILM_HANDLE_END_INSET` (4),
///   `FILM_FLING_MODE` (`aimed` or `momentum`), `FILM_FLING1_TARGET` (0.54),
///   `FILM_FLING2_TARGET` (0.45), `FILM_AIMED_VELOCITY` (350),
///   `FILM_FLING_OVERSHOOT` (0), `FILM_FLING_HOLD` (0.25), `FILM_DRAG_SLOP` (10),
///   and for momentum flings `FILM_FLING1_FROM` (0.82), `FILM_FLING1_TO` (0.14),
///   `FILM_FLING2_FROM` (0.86), `FILM_FLING2_TO` (0.12), `FILM_FLING_VELOCITY` (1600).
final class CourseExplorationFilmUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var markerDirectory = URL(fileURLWithPath: "/tmp")
    private var clip = ""
    private var marks: [String: TimeInterval] = [:]
    private var app = XCUIApplication()
    private var window = CGRect(x: 0, y: 0, width: 402, height: 874)

    override func setUpWithError() throws {
        continueAfterFailure = false
        let directory = environment["FILM_MARKER_DIR"] ?? ""
        try XCTSkipIf(directory.isEmpty, "Film footage only: set TEST_RUNNER_FILM_MARKER_DIR to record.")
        markerDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        // XCUITest otherwise waits for the app to go idle around every event,
        // which takes 0.5-40 s while a spinner animates and breaks the beat clock.
        if environment["FILM_QUIESCENCE"] != "1" { FilmQuiescence.disable() }
    }

    override func tearDown() {
        // Never leave a gated exploration waiting in a running app.
        if !clip.isEmpty { release("all") }
        FilmQuiescence.restore()
        super.tearDown()
    }

    // MARK: - REC-A

    @MainActor
    func testFilmA_Journey() throws {
        begin(clip: "A")
        let token = environment["FILM_TOKEN"] ?? UUID().uuidString
        try Data(token.utf8).write(to: markerDirectory.appendingPathComponent("token"))
        launch(token: token, delays: environment["FILM_DELAYS_A"] ?? "7.4,6.0,1.6")

        // PRE-ROLL: open the lesson.
        let continueButton = app.buttons["course-continue"]
        XCTAssertTrue(poll(timeout: 25) {
            continueButton.exists && continueButton.isHittable
                && continueButton.label.hasPrefix("Continue course")
                && continueButton.label.contains("What bees see")
        }, "Continue course · What bees see never appeared: \(continueButton.debugDescription)")
        continueButton.tap()
        let lessonTitle = app.staticTexts["course-page-title-article-two"]
        XCTAssertTrue(poll(timeout: 20) { lessonTitle.exists }, app.debugDescription)
        XCTAssertEqual(lessonTitle.label, "What bees see")
        window = app.windows.firstMatch.frame
        check(!app.staticTexts["reading-fixture"].exists, "The fixture banner is visible.")

        // PRE-ROLL: park "Where next?" at 190-230 pt with slow drags.
        let whereNext = element("course-where-next")
        parkWhereNext(whereNext)
        logFrames(["course-where-next", "course-explore-deeper", "course-explore-sideways",
                   "course-explore-wider", "course-explore-question-field"])
        let deeper = app.buttons["course-explore-deeper"]
        XCTAssertTrue(waitForHittable(deeper), app.debugDescription)

        startRolling()
        let doorsSettled = mark("A.doorsSettled")
        plate("P1 A.doorsSettled")
        sleep(until: doorsSettled + 3.0)

        // T0: Go deeper. T0 is the beat the tap targets, one tap lead after it fires.
        let tapDeeper = tap(deeper, "A.tapDeeper")
        let t0 = tapDeeper + tapLead
        mark("A.T0", at: t0)

        let pill = element("course-exploration-pill")
        let writingOne = pillText(pill, "Writing “Deeper into What bees see”")
        let poppy = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "To a bee, a red poppy"
        )).firstMatch
        let keepReadingDY = keepReadingDistance(poppy)
        // The pill check and plate only run while they fit before the drag.
        var sawWritingOne = poll(until: t0 + 0.969 - tapLead - 0.15) { writingOne.exists }
        if sawWritingOne {
            mark("A.pillWriting")
            if now() < t0 + 0.969 - tapLead - 0.45 { plate("P2 A.pillWriting") }
        }

        // Keep reading upward until the poppy sentence is framed, in one drag.
        at(t0 + 0.969)
        mark("A.keepReading")
        // One drag of about 0.75 s (film 6.774 → 7.733 leaves 0.96 s with the hold).
        drag(fromY: 0.30, byPoints: keepReadingDY,
             velocity: max(420, abs(keepReadingDY) / number("FILM_KEEP_READING_SECONDS", 0.75)), hold: 0.2)
        mark("A.poppyFramed")
        if !sawWritingOne {
            sawWritingOne = poll(timeout: 3) { writingOne.exists }
            XCTAssertTrue(sawWritingOne, "Writing pill: \(pill.debugDescription)")
            mark("A.pillWriting")
            plate("P2 A.pillWriting")
        }
        logFrame(pill, "course-exploration-pill")
        XCTAssertTrue(poppy.exists && poppy.isHittable, "Poppy paragraph: \(poppy.debugDescription)")
        logFrame(poppy, "poppy-paragraph")
        let poppyMid = poppy.frame.midY / window.height
        check((0.38...0.50).contains(poppyMid), "Poppy paragraph midY is \(poppyMid) of the window, not 0.38-0.50.")
        check(pill.exists, "The pill left the screen while reading upward.")

        // Select the whole sentence: long-press "To", then drag the end handle to the period.
        at(t0 + 2.412)
        mark("A.selectStart")
        selectWholeParagraph(poppy)
        mark("A.selectEnd")
        let exploreSelection = app.buttons["course-page-explore-selection"]
        XCTAssertTrue(poll(timeout: 3) { exploreSelection.exists }, app.debugDescription)

        // Toolbar Explore opens the sheet; Why? fills the question.
        tap(exploreSelection, "A.tapExploreToolbar", at: t0 + 3.878)
        let promptField = element("course-explore-prompt-field")
        XCTAssertTrue(poll(timeout: 10) { promptField.exists }, app.debugDescription)
        mark("A.sheetUp")

        tap(app.buttons["course-explore-intent-why"], "A.tapWhy", at: t0 + 4.847, settled: true)
        XCTAssertTrue(poll(timeout: 2) { (promptField.value as? String) == "Why is this the case?" },
                      "Field value: \(String(describing: promptField.value))")
        // Checks wait until after Why? and frames only run while they fit, so
        // neither delays the sheet's Explore beat (taps log their own points).
        let quote = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Selected passage:'")).firstMatch
        check(quote.label == "Selected passage: To a bee, a red poppy isn't red at all.",
              "The sheet quotes “\(quote.label)”; retune the handle drag.")
        check(app.keyboards.count == 0, "A software keyboard is up in the Explore sheet.")
        for identifier in ["course-explore-prompt-field", "course-explore-prompt-submit"]
            where now() < t0 + 5.805 - tapLead - 0.6 {
            logFrame(element(identifier), identifier)
        }
        if now() < t0 + 5.805 - tapLead - 0.45 { plate("P3 A.sheetUp after Why?") }

        tap(app.buttons["course-explore-prompt-submit"], "A.tapExploreSheet", at: t0 + 5.805, settled: true)
        XCTAssertTrue(poll(timeout: 5) { !promptField.exists }, app.debugDescription)
        let sheetGone = mark("A.sheetGone")
        // Gated writes land on their beat, but never before the fork they
        // follow, so “Writing 2 explorations” shows even in a late take.
        scheduleRelease("go_deeper", at: max(t0 + 7.732, sheetGone + 1.5))
        let writingTwo = pillText(pill, "Writing 2 explorations")
        var markedWritingTwo = false
        func noteWritingTwo() {
            if !markedWritingTwo, writingTwo.exists { mark("A.writing2"); markedWritingTwo = true }
        }

        // Hold without touching; capture the violet branch marker.
        sleep(until: sheetGone + 0.5)
        plate("P4a marker +0.5")
        noteWritingTwo()
        sleep(until: sheetGone + 0.6)
        if exploreSelection.exists {
            // The selection is still up: tap the blank right margin level with the nav bar.
            let bar = app.navigationBars.firstMatch.frame
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.maxX - 8, dy: bar.isEmpty ? 80 : bar.midY)).tap()
            mark("A.deselect")
        }
        sleep(until: sheetGone + 1.0)
        plate("P4 marker +1.0")
        noteWritingTwo()
        sleep(until: sheetGone + 1.5)
        plate("P4b marker +1.5")
        let pillAction = app.buttons["course-exploration-pill-action"]
        if !markedWritingTwo {
            _ = poll(timeout: 3) { writingTwo.exists || pillAction.exists }
            noteWritingTwo()
            check(markedWritingTwo, "The pill never read “Writing 2 explorations”.")
        }

        // Open #1: Landing strips is ready while the poppy is still writing.
        XCTAssertTrue(poll(timeout: 20) { pillAction.exists && pillAction.label == "Open" }, app.debugDescription)
        let ready1 = mark("A.pillReady1")
        report("A.pillReady1 - T0", ready1 - t0, target: 7.732, tolerance: 0.25)
        check(pillText(pill, "Landing strips you can't see").exists,
              "Ready pill #1 title: \(pill.staticTexts.allElementsBoundByIndex.map(\.label))")
        check(pillText(pill, prefix: "Still writing “Why is this the case?").exists,
              "Ready pill #1 caption: \(pill.staticTexts.allElementsBoundByIndex.map(\.label))")
        logFrames(["course-exploration-pill", "course-exploration-pill-action"])
        plate("P5 A.pillReady1")

        let tapOpen1 = tap(pillAction, "A.tapOpen1", at: max(t0 + 8.697, ready1 + 0.45))
        scheduleRelease("passage_why", at: max(t0 + 11.8, tapOpen1 + 1.0))
        let landingTitle = pageTitle("Landing strips you can't see")
        XCTAssertTrue(waitForHittable(landingTitle), "Open #1 did not land on Landing strips: \(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.45)
        mark("A.landed1")
        plate("P6 A.landed1")

        // Fling down Landing strips to its question field.
        let questionField = element("course-explore-question-field")
        at(t0 + 10.628)
        mark("A.fling1")
        fling(questionField, toMidY: number("FILM_FLING1_TARGET", 0.54),
              from: number("FILM_FLING1_FROM", 0.82), to: number("FILM_FLING1_TO", 0.14))
        settle(questionField)
        logFrame(questionField, "course-explore-question-field")
        let fieldMid = questionField.frame.midY / window.height
        check((0.48...0.60).contains(fieldMid), "Question field midY is \(fieldMid) of the window, not 0.48-0.60.")
        bringIntoView(questionField)

        tap(questionField, "A.tapField", at: t0 + 11.587)
        at(t0 + 11.80)
        mark("A.typeStart")
        humanType("Can I see ultraviolet?")
        mark("A.typeEnd")
        check(app.keyboards.count == 0, "A software keyboard appeared while typing.")

        let tapSend = tap(app.buttons["course-explore-question-submit"], "A.tapSend", at: t0 + 13.537)
        scheduleRelease("own_question", at: max(t0 + 15.464, tapSend + 1.5))
        XCTAssertTrue(poll(timeout: 10) { self.pillText(pill, "Writing “Can I see ultraviolet?”").exists },
                      "Writing pill #2: \(pill.debugDescription)")
        mark("A.pillWriting2")

        XCTAssertTrue(poll(timeout: 20) { pillAction.exists && pillAction.label == "Open" }, app.debugDescription)
        let ready2 = mark("A.pillReady2")
        report("A.pillReady2 - T0", ready2 - t0, target: 15.464, tolerance: 0.2)
        check(pillText(pill, "Humans who see ultraviolet").exists && pillText(pill, "Ready to read").exists,
              "Ready pill #2: \(pill.staticTexts.allElementsBoundByIndex.map(\.label))")
        plate("P7 A.pillReady2")

        tap(pillAction, "A.tapOpen2", at: max(t0 + 16.433, ready2 + 0.45))
        XCTAssertTrue(waitForHittable(pageTitle("Humans who see ultraviolet")), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.45)
        mark("A.landed2")
        plate("P8 A.landed2")

        // Fling to Humans' doors and park there (not at the page end).
        let humansDeeper = app.buttons["course-explore-deeper"]
        at(t0 + 17.895)
        mark("A.fling2")
        fling(humansDeeper, toMidY: number("FILM_FLING2_TARGET", 0.45),
              from: number("FILM_FLING2_FROM", 0.86), to: number("FILM_FLING2_TO", 0.12))
        settle(humansDeeper)
        bringIntoView(humansDeeper)
        let parked = mark("A.parked")
        logFrames(["course-where-next", "course-explore-deeper"])
        let deeperMid = humansDeeper.frame.midY / window.height
        check((0.35...0.55).contains(deeperMid), "Humans' Go deeper midY is \(deeperMid) of the window, not about 0.45.")
        plate("P9 A.parked")

        // Hold, and let the poppy page finish writing before the app stops.
        sleep(until: max(parked + 3.0, t0 + 20.0))
        cut()
        Thread.sleep(forTimeInterval: 1.5)
        app.terminate()
    }

    // MARK: - REC-B

    @MainActor
    func testFilmB_MapContinue() throws {
        begin(clip: "B")
        let tokenURL = markerDirectory.appendingPathComponent("token")
        let token = try environment["FILM_TOKEN"]
            ?? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(UUID(uuidString: token), "REC-B needs REC-A's token in \(tokenURL.path).")
        launch(token: token, delays: environment["FILM_DELAYS_B"] ?? "7.3")

        // PRE-ROLL: the map remembers REC-A's journey.
        let continueButton = app.buttons["course-continue"]
        XCTAssertTrue(poll(timeout: 25) {
            continueButton.exists && continueButton.isHittable
                && continueButton.label.contains("Continue exploring")
                && continueButton.label.contains("Humans who see ultraviolet")
        }, "Continue exploring · Humans never appeared: \(continueButton.debugDescription)")
        window = app.windows.firstMatch.frame
        check(!app.staticTexts["reading-fixture"].exists, "The fixture banner is visible.")
        let poppyBranch = branch(containing: "A poppy's secret color")
        XCTAssertTrue(poll(timeout: 10) { poppyBranch.exists }, app.debugDescription)
        check(poppyBranch.label.contains("New") && !poppyBranch.label.contains("Tap to write"),
              "Poppy card: \(poppyBranch.label)")
        let humansBranch = branch(containing: "Humans who see ultraviolet")
        XCTAssertTrue(humansBranch.exists, app.debugDescription)
        check(humansBranch.label.contains("You are here")
                && !humansBranch.label.components(separatedBy: ", ").contains("Read"),
              "Humans card: \(humansBranch.label)")
        let humansBranchID = String(humansBranch.identifier.dropFirst("course-branch-".count))
        // Frame the map now: the Learn screen keeps its scroll position across
        // the push and pop, so after B.back it is already (nearly) framed.
        parkMap(lessonNode: element("course-learning-node-article-two"), humans: humansBranch,
                poppy: poppyBranch, continueButton: continueButton, quiet: true)

        startRolling()
        Thread.sleep(forTimeInterval: 1.0)
        mark("B.rolling")

        tap(continueButton, "B.continueIn")
        // The restored offset scrolls the title away, so it only has to exist.
        XCTAssertTrue(poll(timeout: 15) { self.pageTitle("Humans who see ultraviolet").exists }, app.debugDescription)
        let deeper = app.buttons["course-explore-deeper"]
        XCTAssertTrue(waitForHittable(deeper), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.6)
        let resumed1 = mark("B.resumed1")
        logFrame(deeper, "course-explore-deeper")
        plate("P10 B.resumed1")
        sleep(until: resumed1 + 2.0)

        // B.T0: Go deeper on Humans, then straight back to the map.
        let tapDeeper = tap(deeper, "B.tapDeeper3")
        let t0 = tapDeeper + tapLead
        mark("B.T0", at: t0)
        let pill = element("course-exploration-pill")
        XCTAssertTrue(poll(timeout: 10) {
            self.pillText(pill, prefix: "Writing “Deeper into Humans who see ultraviolet").exists
        }, "Writing pill #3: \(pill.debugDescription)")
        mark("B.pill3")
        plate("P11 B.pill3")

        tap(app.navigationBars.buttons.element(boundBy: 0), "B.back", at: t0 + 0.95)
        let tree = element("course-learning-tree")
        XCTAssertTrue(poll(timeout: 10) { tree.exists }, app.debugDescription)
        let continueExploring = app.buttons["course-continue"]
        XCTAssertTrue(poll(timeout: 5) {
            continueExploring.exists && continueExploring.label.contains("Continue exploring")
                && continueExploring.label.contains("Humans who see ultraviolet")
        }, "Continue after back: \(continueExploring.debugDescription)")
        check(branch(containing: "Humans who see ultraviolet").label.contains("You are here"),
              "Humans card after back: \(branch(containing: "Humans who see ultraviolet").label)")
        let toggle = app.buttons["course-branch-toggle-\(humansBranchID)"]
        XCTAssertTrue(poll(timeout: 5) { toggle.exists }, app.debugDescription)
        check(toggle.label.hasPrefix("Show 1"), "Humans toggle: \(toggle.label)")

        // Frame the map: lesson near the top, Humans above centre, poppy clear of Continue.
        parkMap(lessonNode: element("course-learning-node-article-two"),
                humans: branch(containing: "Humans who see ultraviolet"),
                poppy: branch(containing: "A poppy's secret color"),
                continueButton: continueExploring)
        let mapPost = mark("B.mapPost")
        if mapPost > t0 + 3.4 { print("FILM-LATE B.mapPost \(format(mapPost - t0 - 3.4)) s after B.T0 + 3.4") }
        logFrame(element("course-learning-node-article-two"), "course-learning-node-article-two")
        for card in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'course-branch-'"))
            .allElementsBoundByIndex {
            logFrame(card, card.identifier)
        }
        logFrame(continueExploring, "course-continue")
        plate("P12 B.mapPost")

        // Unfold the Humans card's deeper trail and watch Writing… become New.
        let unfold = tap(toggle, "B.unfold", at: t0 + 5.805, settled: true)
        scheduleRelease("nested_go_deeper", at: max(t0 + 7.755, unfold + 1.2))
        // A card that is still writing is disabled, so it is not a button.
        let nestedWriting = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-branch-explore-' AND label CONTAINS %@ AND label CONTAINS %@",
            "Deeper into Humans who see ultraviolet", "Writing…"
        )).firstMatch
        let nestedNew = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-branch-explore-' AND label CONTAINS %@ AND label CONTAINS %@",
            "The filter in your eye", "New"
        )).firstMatch
        XCTAssertTrue(poll(timeout: 10) {
            let began = self.now()
            defer {
                if self.now() - began > 0.5 { print("FILM-WARN a map query took \(self.format(self.now() - began)) s") }
            }
            return nestedWriting.exists || nestedNew.exists
        }, app.debugDescription)
        if nestedWriting.exists {
            mark("B.nestedWriting")
            logFrame(nestedWriting, "nested-card-writing")
            plate("P13 B.nestedWriting")
        } else {
            check(false, "The nested card was already New when it unfolded.")
        }
        XCTAssertTrue(poll(timeout: 30) { nestedNew.exists }, app.debugDescription)
        let flipNew = mark("B.flipNew")
        report("B.flipNew - B.T0", flipNew - t0, target: 7.755, tolerance: 0.25)
        logFrame(nestedNew, "nested-card-new")
        sleep(until: flipNew + 1.0)
        plate("P14 B.flipNew + 1.0")

        // Continue exploring returns to the parked offset, where the last door is ready.
        let tapContinue = tap(continueExploring, "B.tapContinue", at: flipNew + 1.928)
        XCTAssertTrue(poll(timeout: 15) { self.pageTitle("Humans who see ultraviolet").exists }, app.debugDescription)
        let pillAction = app.buttons["course-exploration-pill-action"]
        XCTAssertTrue(poll(timeout: 15) {
            pillAction.exists && pillAction.label == "Open"
                && self.pillText(pill, "The filter in your eye").exists
                && self.pillText(pill, "Ready to read").exists
        }, "Final pill: \(pill.debugDescription)")
        Thread.sleep(forTimeInterval: 0.3)
        mark("B.resumed2")
        logFrames(["course-exploration-pill", "course-exploration-pill-action", "course-explore-deeper"])
        plate("P15 B.resumed2")

        tap(pillAction, "B.tapOpenFinal", at: tapContinue + 2.919 + tapLead)
        Thread.sleep(forTimeInterval: 1.0)
        cut()
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: - Fling calibration (TEMP)

    @MainActor
    func testFilmZ_CalibrateFlings() throws {
        try XCTSkipUnless(environment["FILM_CALIBRATE"] == "1", "Calibration only.")
        begin(clip: "Z")
        launch(token: UUID().uuidString, delays: "1")
        let continueButton = app.buttons["course-continue"]
        XCTAssertTrue(poll(timeout: 25) { continueButton.exists && continueButton.isHittable })
        continueButton.tap()
        let lessonTitle = app.staticTexts["course-page-title-article-two"]
        XCTAssertTrue(poll(timeout: 20) { lessonTitle.exists })
        window = app.windows.firstMatch.frame
        let ref = element("course-where-next")
        Thread.sleep(forTimeInterval: 1.0)
        let configs = (environment["FILM_CAL_CONFIGS"] ?? "200:600:0,200:1000:0,200:1600:0,400:1600:0.1,400:1600:0.25,400:600:0.25,400:350:0.25")
            .split(separator: ",").map { $0.split(separator: ":").map { CGFloat(Double($0)!) } }
        for config in configs {
            let stroke = config[0], velocity = config[1], hold = config[2]
            let y0 = ref.frame.minY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.86))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.86 - stroke / window.height))
            let began = now()
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: XCUIGestureVelocity(velocity),
                        thenHoldForDuration: hold)
            let released = now()
            var trail: [String] = []
            while now() < released + 2.5 {
                let y = ref.frame.minY
                trail.append("\(format(now() - released)):\(format(y0 - y))")
            }
            print("FILM-CAL stroke \(stroke) v \(velocity) hold \(hold) gesture \(format(released - began)) s travel \(trail.joined(separator: " "))")
            // Back to the top with a hard fling down.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.9)),
                       withVelocity: XCUIGestureVelocity(4000), thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 2.5)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.9)),
                       withVelocity: XCUIGestureVelocity(4000), thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 2.5)
        }
    }

    // MARK: - Launch and handshake

    @MainActor
    private func begin(clip: String) {
        self.clip = clip
        marks = [:]
        for name in ["ready-\(clip)", "rolling-\(clip)", "cut-\(clip)", "REC-\(clip).markers.jsonl"] {
            try? FileManager.default.removeItem(at: markerDirectory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: gateDirectory)
        try? FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)
    }

    @MainActor
    private func launch(token: String, delays: String) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-test-course-reading"]
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = token
        app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_GENERATION_SCENARIO"] = "delayed-save"
        app.launchEnvironment["LEARNFOLD_READING_TEST_APPEARANCE"] = "light"
        app.launchEnvironment["LEARNFOLD_READING_TEST_HIDE_BANNER"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_FILM_COURSE"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION_DELAY_SECONDS"] = delays
        if !gatedTriggers.isEmpty {
            app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION_GATE_DIR"] = gateDirectory.path
            app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION_GATED"] = gatedTriggers.joined(separator: ",")
        }
        print("FILM-CLIP \(clip) token \(token) delays \(delays) gated \(gatedTriggers)")
        app.launch()
    }

    /// Signals the recorder, then waits (up to 15 s) for it to start rolling.
    private func startRolling() {
        touch("ready-\(clip)")
        mark("\(clip).ready")
        if environment["FILM_DRY_RUN"] == "1" { return }
        let rolling = markerDirectory.appendingPathComponent("rolling-\(clip)").path
        if !poll(timeout: 15, interval: 0.05, { FileManager.default.fileExists(atPath: rolling) }) {
            print("FILM-WARN rolling-\(clip) never appeared; continuing without a recorder.")
        }
        mark("\(clip).rolling")
    }

    private func cut() {
        mark("\(clip).cut")
        touch("cut-\(clip)")
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: markerDirectory.appendingPathComponent(name).path, contents: Data())
    }

    // MARK: - Exploration release gate

    private var gateDirectory: URL { markerDirectory.appendingPathComponent("gate-\(clip)", isDirectory: true) }

    private var gatedTriggers: [String] {
        (environment["FILM_GATED"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Releases a gated exploration so its saved write lands on `beat`.
    private func scheduleRelease(_ trigger: String, at beat: TimeInterval) {
        guard gatedTriggers.contains(trigger) || gatedTriggers.contains("all") else { return }
        let fireAt = beat - number("FILM_GATE_LEAD", 0.15)
        let path = gateDirectory.appendingPathComponent("release-\(trigger)").path
        DispatchQueue.global().asyncAfter(wallDeadline: .now() + max(0, fireAt - now())) {
            FileManager.default.createFile(atPath: path, contents: Data())
            print("FILM-RELEASE \(trigger) \(String(format: "%.3f", Date().timeIntervalSince1970))")
        }
    }

    private func release(_ trigger: String) {
        FileManager.default.createFile(
            atPath: gateDirectory.appendingPathComponent("release-\(trigger)").path, contents: Data()
        )
    }

    // MARK: - Markers

    private func now() -> TimeInterval { Date().timeIntervalSince1970 }

    private func format(_ value: Double) -> String { String(format: "%.3f", value) }

    private func record(_ fields: [String: Any], line: String) {
        print(line)
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        let url = markerDirectory.appendingPathComponent("REC-\(clip).markers.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    @discardableResult
    private func mark(_ name: String, at time: TimeInterval? = nil) -> TimeInterval {
        let time = time ?? now()
        marks[name] = time
        record(["name": name, "t_epoch": time, "kind": "mark"], line: "FILM-MARK \(name) \(format(time))")
        return time
    }

    private func logFrame(_ element: XCUIElement, _ name: String) {
        guard element.exists else {
            print("FILM-FRAME \(name) missing")
            return
        }
        let frame = element.frame
        record([
            "name": name, "t_epoch": now(), "kind": "frame",
            "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height,
        ], line: "FILM-FRAME \(name) \(format(frame.minX)) \(format(frame.minY)) \(format(frame.width)) \(format(frame.height))")
    }

    private func logFrames(_ identifiers: [String]) {
        for identifier in identifiers { logFrame(element(identifier), identifier) }
    }

    private func report(_ name: String, _ value: TimeInterval, target: TimeInterval, tolerance: TimeInterval) {
        let drift = value - target
        print("FILM-TIMING \(name) \(format(value)) target \(format(target)) drift \(format(drift))")
        check(abs(drift) <= tolerance, "\(name) is \(format(value)) s, outside \(format(target)) ± \(format(tolerance)); retune the delay.")
    }

    /// A take-quality check: fails the take by default, warns with FILM_STRICT=0.
    private func check(_ condition: Bool, _ message: @autoclosure () -> String,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        if environment["FILM_STRICT"] == "0" {
            print("FILM-WARN \(message())")
        } else {
            XCTFail(message(), file: file, line: line)
        }
    }

    @MainActor
    private func plate(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Timing

    private var tapLead: TimeInterval { number("FILM_TAP_LEAD", 0.10) }

    /// Waits for `target` minus the tap lead, so the UI responds on the beat.
    private func at(_ target: TimeInterval) {
        sleep(until: target - tapLead)
    }

    private func sleep(until time: TimeInterval) {
        let remaining = time - now()
        if remaining > 0 {
            Thread.sleep(forTimeInterval: remaining)
        } else if remaining < -0.02 {
            print("FILM-LATE \(format(-remaining)) s late at \(format(time))")
        }
    }

    /// Polls until `deadline` (epoch) at most; checks at least once.
    private func poll(until deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
        poll(timeout: max(0, deadline - now()), condition)
    }

    @discardableResult
    private func poll(timeout: TimeInterval, interval: TimeInterval = 0.05, _ condition: () -> Bool) -> Bool {
        let deadline = now() + timeout
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        } while now() < deadline
        return condition()
    }

    // MARK: - Actions

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func pageTitle(_ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-page-title-' AND label == %@", title
        )).firstMatch
    }

    private func branch(containing title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-branch-explore-' AND label CONTAINS %@", title
        )).firstMatch
    }

    private func pillText(_ pill: XCUIElement, _ label: String) -> XCUIElement {
        pill.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func pillText(_ pill: XCUIElement, prefix: String) -> XCUIElement {
        pill.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Taps an element's centre by coordinate, at `target` minus the tap lead
    /// when given. The frame is read before waiting so the tap fires on time;
    /// `settled` first waits for a just-presented control to stop moving.
    @discardableResult
    private func tap(_ element: XCUIElement, _ name: String, at target: TimeInterval? = nil,
                     settled: Bool = false) -> TimeInterval {
        XCTAssertTrue(poll(timeout: 10) { element.exists }, "\(name): \(element.debugDescription)")
        if settled { settle(element, timeout: 1.5) }
        let frame = element.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        if let target { at(target) }
        let time = now()
        marks[name] = time
        record(["name": name, "t_epoch": time, "kind": "tap", "x": point.x, "y": point.y],
               line: "FILM-TAP \(name) \(format(time)) \(format(point.x)) \(format(point.y))")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        return time
    }

    /// Selects the one-sentence paragraph. By default a long-press on its first
    /// word, then the end handle dragged to the period. The shot list's .slow
    /// handle drag and 0.3 s hold take about 3.8 s in all with XCUITest's
    /// synthesis overhead, far past the 1.47 s before the toolbar tap, so the
    /// defaults drag faster while keeping the 0.8 s long-press (0.6 s does not
    /// select in this reader) and the 0.2 s handle grab. (A triple tap only
    /// selects the first word here.)
    private func selectWholeParagraph(_ paragraphView: XCUIElement) {
        // Absolute app coordinates: element-relative ones re-resolve the
        // paragraph several times per gesture, which adds about 0.5 s each.
        let paragraph = paragraphView.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: paragraph.minX, dy: paragraph.minY))
        origin.withOffset(CGVector(dx: number("FILM_SELECT_DX", 10), dy: paragraph.height / 2))
            .press(forDuration: number("FILM_LONG_PRESS", 0.8))
        origin.withOffset(CGVector(
            dx: number("FILM_HANDLE_DX", 24),
            dy: paragraph.height / 2 + number("FILM_HANDLE_DY", 10)
        )).press(
            forDuration: number("FILM_HANDLE_PRESS", 0.2),
            thenDragTo: origin.withOffset(CGVector(
                dx: paragraph.width - number("FILM_HANDLE_END_INSET", 4), dy: paragraph.height / 2
            )),
            withVelocity: XCUIGestureVelocity(number("FILM_HANDLE_VELOCITY", 1000)),
            thenHoldForDuration: number("FILM_HANDLE_HOLD", 0.15)
        )
    }

    /// One character at a time on a fixed schedule, like a person typing.
    /// Falls back to one typeText call for the rest when a single character
    /// takes far longer than the interval (a software keyboard, where each
    /// call costs about 0.3 s).
    private func humanType(_ text: String) {
        let interval = number("FILM_TYPE_INTERVAL", 0.06)
        let start = now()
        for (index, character) in text.enumerated() {
            let due = start + Double(index) * interval
            if now() < due { Thread.sleep(forTimeInterval: due - now()) }
            let began = now()
            app.typeText(String(character))
            // Slow hosts take longer per key; keep typing one key at a time so
            // the footage shows real typing (the edit re-times this stretch).
            if index == 0, now() - began > 3 * interval {
                print("FILM-WARN one character took \(format(now() - began)) s; typing stays per key.")
            }
        }
    }

    /// A slow drag on the right margin; positive points move the content down.
    private func drag(fromY: CGFloat, byPoints points: CGFloat, velocity: CGFloat, hold: TimeInterval) {
        let toY = min(max(fromY + points / window.height, 0.05), 0.95)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: hold)
    }

    /// Scrolls `element` to `toMidY` (fraction of the window) in one fast stroke.
    ///
    /// `FILM_FLING_MODE=aimed` (default) sizes one drag from the element's
    /// off-screen frame so the page lands near `toMidY` and does not run on to
    /// its end (which would mark it Read). Holding at the end of a synthesized
    /// drag does not cancel scroll momentum (600 pt/s overran by about 180 pt),
    /// so the stroke runs at `FILM_AIMED_VELOCITY` (default 350, which lands
    /// within a few points), shortened by `FILM_FLING_OVERSHOOT` (default 0).
    /// Longer trips take a second stroke, and a landing more than 30 pt off
    /// gets one slow correction drag (logged as FILM-WARN). `FILM_FLING_MODE=momentum` is the shot list's fixed momentum
    /// fling from `from` to `to` (fractions of the window) at
    /// `FILM_FLING_VELOCITY` (1600); on the 17 Pro it runs both pages to
    /// their end.
    private func fling(_ element: XCUIElement, toMidY target: CGFloat, from: CGFloat, to: CGFloat) {
        let velocity = XCUIGestureVelocity(number("FILM_FLING_VELOCITY", 1600))
        let before = element.exists && !element.frame.isEmpty ? element.frame.midY : nil
        if let before { print("FILM-FRAME \(element.identifier)-before-fling midY \(format(before))") }
        if environment["FILM_FLING_MODE"] != "momentum", let before {
            var remaining = before - target * window.height - number("FILM_FLING_OVERSHOOT", 0)
            let maxStroke = 0.84 * window.height
            var strokes = 0
            while remaining > 4, strokes < 2 {
                let stroke = min(remaining, maxStroke)
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.90))
                let end = app.coordinate(withNormalizedOffset: CGVector(
                    dx: 0.92, dy: 0.90 - (stroke + number("FILM_DRAG_SLOP", 10)) / window.height
                ))
                start.press(forDuration: 0.05, thenDragTo: end,
                            withVelocity: XCUIGestureVelocity(number("FILM_AIMED_VELOCITY", 350)),
                            thenHoldForDuration: number("FILM_FLING_HOLD", 0.25))
                remaining -= stroke
                strokes += 1
            }
            if strokes > 1 { print("FILM-WARN \(element.identifier) needed \(strokes) strokes.") }
            settle(element, timeout: 2)
            let miss = element.exists ? target * window.height - element.frame.midY : 0
            if abs(miss) > 30 {
                print("FILM-WARN \(element.identifier) landed \(format(miss)) pt off; correcting.")
                drag(fromY: miss < 0 ? 0.70 : 0.30, byPoints: miss + (miss < 0 ? -10 : 10), velocity: 300, hold: 0.3)
            }
            return
        }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }

    /// Waits until an element's frame stops moving (scroll momentum finished).
    private func settle(_ element: XCUIElement, timeout: TimeInterval = 4) {
        var last = element.exists ? element.frame : .null
        var stable = 0
        var trail = [last.minY]
        let deadline = now() + timeout
        while now() < deadline, stable < 3 {
            Thread.sleep(forTimeInterval: 0.05)
            let frame = element.exists ? element.frame : .null
            stable = frame == last ? stable + 1 : 0
            last = frame
            trail.append(frame.minY)
        }
        // The minY trajectory while settling, for gesture calibration.
        print("FILM-SETTLE \(element.identifier) " + trail.map { $0.isFinite ? format($0) : "-" }.joined(separator: " "))
    }

    /// Drags "Where next?" to 190-230 pt from the top with slow, held drags.
    /// Each drag adds the touch slop the previous one lost, so short
    /// corrections still move the page.
    private func parkWhereNext(_ whereNext: XCUIElement) {
        var slop: CGFloat = 12
        var stalled = 0
        for _ in 0..<24 {
            let before = whereNext.exists && !whereNext.frame.isEmpty ? whereNext.frame.minY : nil
            let offset: CGFloat
            if let before {
                if (190...230).contains(before) { return }
                offset = 210 - before
            } else {
                offset = -0.40 * window.height
            }
            let limit = 0.40 * window.height
            let wanted = max(min(offset, limit), -limit)
            let requested = wanted + (wanted < 0 ? -slop : slop)
            drag(fromY: requested < 0 ? 0.78 : 0.38, byPoints: requested, velocity: 350, hold: 0.3)
            settle(whereNext, timeout: 1.5)
            if let before, whereNext.exists {
                let moved = abs(whereNext.frame.minY - before)
                stalled = moved < 1 ? stalled + 1 : 0
                if stalled >= 2 {
                    // Two drags past the slop moved nothing: this is the page's end.
                    print("FILM-WARN “Where next?” stops at \(format(before)) pt (page end).")
                    return
                }
                slop = min(max(abs(requested) - moved, 0), 40)
            }
        }
        check(false, "Could not park “Where next?” at 190-230 pt: \(whereNext.frame)")
    }

    /// The single keep-reading drag that frames the poppy sentence at 0.44 of the window.
    private func keepReadingDistance(_ poppy: XCUIElement) -> CGFloat {
        if let override = environment["FILM_KEEP_READING_DY"].flatMap(Double.init) { return CGFloat(override) }
        if poppy.exists, !poppy.frame.isEmpty {
            return min(0.44 * window.height - poppy.frame.midY, 0.62 * window.height)
        }
        // Measured on the iPhone 17 Pro with “Where next?” parked at 190-230 pt.
        return 0.54 * window.height
    }

    /// A safety net after a calibrated fling: slow drags until the element is
    /// hittable, logged as a warning so the take can be retuned.
    private func bringIntoView(_ element: XCUIElement) {
        guard !(element.exists && element.isHittable) else { return }
        print("FILM-WARN \(element.identifier) not hittable after the fling; correcting with slow drags.")
        for _ in 0..<10 {
            if element.exists, element.isHittable { return }
            let offset = element.exists && !element.frame.isEmpty
                ? 0.5 * window.height - element.frame.midY : -0.35 * window.height
            let step = max(min(offset, 0.35 * window.height), -0.35 * window.height)
            drag(fromY: step < 0 ? 0.75 : 0.30, byPoints: step, velocity: 500, hold: 0.3)
            settle(element, timeout: 1.5)
        }
    }

    /// Frames the Learn map for the S12 plate with slow, held drags.
    private func parkMap(lessonNode: XCUIElement, humans: XCUIElement, poppy: XCUIElement,
                         continueButton: XCUIElement, quiet: Bool = false) {
        func framed() -> Bool {
            guard lessonNode.exists, humans.exists, poppy.exists, continueButton.exists else { return false }
            let top = lessonNode.frame.minY / window.height
            return (0.14...0.22).contains(top)
                && humans.frame.midY / window.height <= 0.50
                && poppy.frame.maxY <= continueButton.frame.minY - 8
        }
        // One drag sized from the lesson row's frame (plus touch slop) usually
        // frames it; a second corrects what the first missed.
        for _ in 0..<4 {
            if framed() { return }
            let offset = lessonNode.exists && !lessonNode.frame.isEmpty
                ? 0.18 * window.height - lessonNode.frame.minY : -0.34 * window.height
            if abs(offset) < 4 { break }
            let limit = 0.62 * window.height
            let step = max(min(offset, limit), -limit)
            let slop = number("FILM_DRAG_SLOP", 10)
            drag(fromY: step < 0 ? 0.80 : 0.18, byPoints: step + (step < 0 ? -slop : slop),
                 velocity: 500, hold: 0.3)
            settle(lessonNode, timeout: 0.8)
        }
        if quiet { return }
        check(framed(), "Map framing: lesson \(lessonNode.frame), Humans \(humans.frame), poppy \(poppy.frame), continue \(continueButton.frame)")
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        poll(timeout: timeout) { element.exists && element.isHittable }
    }

    private func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
        environment[key].flatMap(Double.init).map { CGFloat($0) } ?? fallback
    }
}

/// Skips XCUITest's wait-for-idle around synthesized events while the film
/// test runs, so taps and drags fire on the beat clock instead of after the
/// app's spinner animations settle. Restored in tearDown.
private enum FilmQuiescence {
    private static var replaced: [(Method, IMP)] = []

    static func disable() {
        var count: UInt32 = 0
        guard replaced.isEmpty, let process = NSClassFromString("XCUIApplicationProcess"),
              let methods = class_copyMethodList(process, &count) else { return }
        defer { free(methods) }
        for method in UnsafeBufferPointer(start: methods, count: Int(count)) {
            let name = NSStringFromSelector(method_getName(method))
            guard name.hasPrefix("waitForQuiescenceIncludingAnimationsIdle:") else { continue }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            let returnsBool = returnType.pointee == CChar(UInt8(ascii: "B"))
                || returnType.pointee == CChar(UInt8(ascii: "c"))
            let block: Any = returnsBool
                ? ({ _ in true } as @convention(block) (AnyObject) -> Bool)
                : ({ _ in } as @convention(block) (AnyObject) -> Void)
            replaced.append((method, method_setImplementation(method, imp_implementationWithBlock(block))))
            print("FILM-QUIESCENCE skipping \(name)")
        }
    }

    static func restore() {
        for (method, original) in replaced { method_setImplementation(method, original) }
        replaced = []
    }
}
