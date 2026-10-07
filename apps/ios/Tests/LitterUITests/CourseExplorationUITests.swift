import XCTest

/// Forks an exploration from a lesson with the real reader, native persistence,
/// and generation dispatcher, using the local reading fixture's agent.
final class CourseExplorationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testForkingGoesDeeperThenShowsOnTheMap() {
        let app = launchReadingFixture()

        let deeper = app.buttons["course-explore-deeper"]
        XCTAssertTrue(scrollUntilHittable(deeper, in: app), app.debugDescription)
        capture("Where next doors at the end of a lesson", app)
        deeper.tap()

        // The learner keeps reading while the exploration is written, then
        // opens it from the toolbar's exploration status.
        XCTAssertTrue(waitForStatus("Explorations: 1 ready", in: app), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "Forking never navigates away from the page being read.")
        capture("Written exploration waits in the toolbar status", app)
        openReadyExploration(titled: "Why the challenge must be random", in: app)

        // The parent page also lists the new title as a link; wait for the new
        // page's own title so the capture shows the exploration itself.
        let opened = explorationTitle("Why the challenge must be random", in: app)
        XCTAssertTrue(opened.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitForHittable(opened))
        Thread.sleep(forTimeInterval: 1.0)
        capture("Forked exploration opens once written", app)

        let pin = app.buttons["course-explore-pin"]
        XCTAssertTrue(scrollUntilHittable(pin, in: app), app.debugDescription)
        pin.tap()
        XCTAssertTrue(app.buttons["course-explore-back"].exists)
        capture("Exploration footer offers going back and pinning", app)
        app.buttons["course-explore-back"].tap()

        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 10))
        let explored = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'course-explored-explore-'")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(explored, in: app), app.debugDescription)
        XCTAssertTrue(explored.label.contains("Why the challenge must be random"), explored.label)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let goals = app.descendants(matching: .any).matching(identifier: "course-goals").firstMatch
        XCTAssertTrue(goals.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "course-open-threads").firstMatch.exists,
            "A pinned goal is not repeated as an open thread."
        )
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '1 explored'")
        ).firstMatch.exists, app.debugDescription)
        capture("Learn map shows the goal and explored count", app)

        let branch = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'course-branch-explore-'")
        ).firstMatch
        XCTAssertTrue(scrollUntilHittable(branch, in: app), app.debugDescription)
        XCTAssertTrue(branch.label.contains("Why the challenge must be random"), branch.label)
        capture("The exploration hangs off its lesson on the path", app)
    }

    @MainActor
    func testExploringASelectedPassageAsksWhatToExploreFirst() {
        let app = launchReadingFixture()

        selectPassage(in: app)

        let explore = app.buttons["course-page-explore-selection"]
        XCTAssertTrue(waitForHittable(explore), app.debugDescription)
        explore.tap()

        let field = app.descendants(matching: .any)
            .matching(identifier: "course-explore-prompt-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["course-explore-intent-why"].tap()
        XCTAssertEqual(field.value as? String, "Why is this the case?",
                       "A quick intent fills the question so it can still be reworded.")
        capture("Explore asks what to explore about the passage", app)
        app.buttons["course-explore-prompt-submit"].tap()

        let status = app.buttons["course-exploration-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "The learner stays on the passage they were reading.")
        capture("Exploration is written while the learner keeps reading", app)

        XCTAssertTrue(waitForStatus("Explorations: 1 ready", in: app), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "A finished exploration never opens by itself.")
        capture("Written exploration is ready to open", app)

        // The highlighted passage lists what starts there; a tap opens it.
        tapPassage(in: app)
        let row = passageRow(in: app)
        XCTAssertTrue(waitForHittable(row), app.debugDescription)
        XCTAssertTrue(row.label.contains("Why the challenge must be random"), row.label)
        capture("Tapping the passage shows what starts there", app)
        row.tap()
        XCTAssertTrue(explorationTitle("Why the challenge must be random", in: app)
            .waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 10))
        XCTAssertFalse(status.exists, "Opening the exploration clears its notice.")
        capture("The passage keeps a branch marker", app)
    }

    @MainActor
    func testTappingAWritingExplorationNeverOpensIt() {
        let app = launchReadingFixture(explorationDelaySeconds: 8)
        explorePassage(in: app)
        XCTAssertTrue(waitForStatus("Explorations: 1 writing", in: app), app.debugDescription)

        tapPassage(in: app)
        let threads = app.descendants(matching: .any).matching(identifier: "course-passage-threads").firstMatch
        XCTAssertTrue(threads.waitForExistence(timeout: 10), app.debugDescription)
        let writing = passageRow(in: app)
        XCTAssertTrue(writing.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(writing.label.contains("being written"), writing.label)
        capture("A passage still being written says so and stays put", app)

        // When it finishes, the row turns into one that opens it; nothing else moves.
        let written = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-passage-exploration-' AND label CONTAINS %@",
            "Why the challenge must be random"
        )).firstMatch
        XCTAssertTrue(written.waitForExistence(timeout: 40), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "A finished exploration never opens by itself.")
        capture("The row becomes openable in place", app)
        written.tap()
        XCTAssertTrue(explorationTitle("Why the challenge must be random", in: app)
            .waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    func testTwoExplorationsAreCountedCourseWide() {
        // Each fork takes a few seconds of taps, so the writes run long
        // enough for both to be in flight at once.
        let app = launchReadingFixture(explorationDelaySeconds: 25)
        explorePassage(at: 40, in: app)
        explorePassage(at: 200, in: app)
        XCTAssertTrue(waitForStatus("Explorations: 2 writing", in: app), app.debugDescription)
        capture("Two explorations are written at once", app)

        XCTAssertTrue(waitForStatus("Explorations: 2 ready", in: app, timeout: 45), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "Finished explorations never open by themselves.")
        app.buttons["course-exploration-status"].tap()
        capture("The status menu lists both ready explorations", app)
        let ready = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Why the challenge must be random"
        ))
        XCTAssertTrue(ready.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(ready.count, 2, app.debugDescription)
        ready.firstMatch.tap()

        // The other one is still waiting, wherever the learner reads next.
        XCTAssertTrue(waitForStatus("Explorations: 1 ready", in: app), app.debugDescription)
        XCTAssertFalse(app.staticTexts["course-page-title-article-two"].exists)
        capture("The other ready exploration follows the learner", app)
    }

    @MainActor
    func testSamePassageForkedTwiceListsBoth() {
        let app = launchReadingFixture()
        explorePassage(intent: "why", in: app)
        XCTAssertTrue(waitForStatus("Explorations: 1 ready", in: app), app.debugDescription)

        selectPassage(in: app)
        let explore = app.buttons["course-page-explore-selection"]
        XCTAssertTrue(waitForHittable(explore), app.debugDescription)
        explore.tap()
        let already = app.descendants(matching: .any)
            .matching(identifier: "course-explore-prompt-already").firstMatch
        XCTAssertTrue(already.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(already.label.contains("Why the challenge must be random"), already.label)
        capture("Explore says what this passage already led to", app)
        app.buttons["course-explore-intent-how"].tap()
        app.buttons["course-explore-prompt-submit"].tap()
        XCTAssertTrue(waitForStatus("Explorations: 2 ready", in: app), app.debugDescription)

        tapPassage(in: app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'course-passage-exploration-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(rows.count, 2, "Both explorations of the passage are listed.")
        capture("A passage explored twice lists both", app)
    }

    @MainActor
    func testFailedExplorationRetriesInPlace() {
        let app = launchReadingFixture(explorationScenario: "fail-first")
        explorePassage(in: app)
        XCTAssertTrue(waitForStatus("Explorations: 1 didn’t finish", in: app), app.debugDescription)

        tapPassage(in: app)
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'course-passage-retry-'")).firstMatch
        XCTAssertTrue(waitForHittable(retry), app.debugDescription)
        capture("A failed exploration offers Try Again in place", app)
        retry.tap()

        let written = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-passage-exploration-' AND label CONTAINS %@",
            "Why the challenge must be random"
        )).firstMatch
        XCTAssertTrue(written.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists)
        capture("The retried exploration is ready in place", app)
    }

    // MARK: - Helpers

    @MainActor
    private func paragraph(in app: XCUIApplication) -> XCUIElement {
        // Reading pages render passages as static text, editing as text views.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "value BEGINSWITH %@", "Try describing a verification step"
        )).firstMatch
    }

    @MainActor
    private func selectPassage(at dx: CGFloat = 40, in app: XCUIApplication) {
        let paragraph = paragraph(in: app)
        XCTAssertTrue(waitForHittable(paragraph), app.debugDescription)
        paragraph.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dx, dy: 12)).press(forDuration: 1.2)
    }

    @MainActor
    private func tapPassage(at dx: CGFloat = 40, in app: XCUIApplication) {
        paragraph(in: app).coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dx, dy: 12)).tap()
    }

    /// Selects a word, explores it, and waits for the prompt to close.
    @MainActor
    private func explorePassage(at dx: CGFloat = 40, intent: String? = nil, in app: XCUIApplication) {
        selectPassage(at: dx, in: app)
        let explore = app.buttons["course-page-explore-selection"]
        XCTAssertTrue(waitForHittable(explore), app.debugDescription)
        explore.tap()
        let submit = app.buttons["course-explore-prompt-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), app.debugDescription)
        if let intent { app.buttons["course-explore-intent-\(intent)"].tap() }
        submit.tap()
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: submit
        )], timeout: 15) == .completed, "The prompt closes once the exploration exists.")
    }

    @MainActor
    private func passageRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-passage-exploration-'"
        )).firstMatch
    }

    @MainActor
    private func explorationTitle(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-page-title-' AND label == %@", title
        )).firstMatch
    }

    @MainActor
    private func waitForStatus(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", label),
            object: app.buttons["course-exploration-status"]
        )], timeout: timeout) == .completed
    }

    @MainActor
    private func openReadyExploration(titled title: String, in app: XCUIApplication) {
        app.buttons["course-exploration-status"].tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), app.debugDescription)
        item.tap()
    }

    @MainActor
    private func launchReadingFixture(
        explorationDelaySeconds: Double = 1,
        explorationScenario: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_GENERATION_SCENARIO"] = "delayed-save"
        app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_EXPLORATION_DELAY_SECONDS"] = String(explorationDelaySeconds)
        if let explorationScenario {
            app.launchEnvironment["LEARNFOLD_READING_EXPLORATION_SCENARIO"] = explorationScenario
        }
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()

        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )], timeout: 15) == .completed
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
