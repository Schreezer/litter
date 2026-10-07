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
        // opens it from the status pill.
        let open = app.buttons["course-exploration-pill-action"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(open.label, "Open")
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "Forking never navigates away from the page being read.")
        capture("Written exploration waits in the pill", app)
        open.tap()

        // The parent page also lists the new title as a link; wait for the new
        // page's own title so the capture shows the exploration itself.
        let explorationTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-page-title-' AND label == %@",
            "Why the challenge must be random"
        )).firstMatch
        XCTAssertTrue(explorationTitle.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(waitForHittable(explorationTitle))
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

        let paragraph = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Try describing a verification step"
        )).firstMatch
        XCTAssertTrue(waitForHittable(paragraph), app.debugDescription)
        paragraph.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40, dy: 12)).press(forDuration: 1.2)

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

        let pill = app.descendants(matching: .any).matching(identifier: "course-exploration-pill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists,
                      "The learner stays on the passage they were reading.")
        capture("Exploration is written while the learner keeps reading", app)

        let open = app.buttons["course-exploration-pill-action"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), app.debugDescription)
        capture("Written exploration is ready to open", app)
        open.tap()
        let explorationTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-page-title-' AND label == %@",
            "Why the challenge must be random"
        )).firstMatch
        XCTAssertTrue(explorationTitle.waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 10))
        XCTAssertFalse(pill.exists, "Opening the exploration clears its notice.")
        capture("The passage keeps a branch marker", app)
    }

    @MainActor
    func testPillNamesEachExplorationAndListsThem() {
        // The first fork is written quickly; the second keeps writing.
        let app = launchReadingFixture(explorationDelays: "6,90")

        let deeper = app.buttons["course-explore-deeper"]
        XCTAssertTrue(scrollUntilHittable(deeper, in: app), app.debugDescription)
        deeper.tap()
        let sideways = app.buttons["course-explore-sideways"]
        XCTAssertTrue(waitForHittable(sideways), app.debugDescription)
        sideways.tap()

        let pill = app.descendants(matching: .any).matching(identifier: "course-exploration-pill").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Writing 2 explorations"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Going deeper · Going sideways"].exists,
                      "The pill names every exploration being written.")
        capture("Pill names both explorations being written", app)

        let open = app.buttons["course-exploration-pill-action"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(open.label, "Open")
        XCTAssertTrue(app.staticTexts["1 more writing"].exists, app.debugDescription)
        capture("Ready exploration leads, the other is still writing", app)

        app.buttons["course-exploration-pill-expand"].tap()
        let rows = app.descendants(matching: .any).matching(identifier: "course-exploration-job")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rows.count, 2, app.debugDescription)
        XCTAssertTrue(app.staticTexts["Going sideways"].exists, "The one still writing is listed by its ask.")
        capture("Expanded pill lists each exploration", app)

        let rowOpen = app.buttons["course-exploration-job-action"]
        XCTAssertEqual(rowOpen.label, "Open")
        // Hold the press so the pressed state can be captured from outside.
        rowOpen.press(forDuration: 1.5)
        let explorationTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'course-page-title-' AND label == %@",
            "Why the challenge must be random"
        )).firstMatch
        XCTAssertTrue(explorationTitle.waitForExistence(timeout: 15), app.debugDescription)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 10))
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "The exploration still writing keeps its notice.")
        XCTAssertTrue(app.staticTexts["Going sideways"].exists, app.debugDescription)
        capture("Opened exploration leaves the one still writing", app)
    }

    @MainActor
    private func launchReadingFixture(explorationDelays: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let explorationDelays {
            app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION_DELAY_SECONDS"] = explorationDelays
        }
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_GENERATION_SCENARIO"] = "delayed-save"
        app.launchEnvironment["LEARNFOLD_READING_TEST_EXPLORATION"] = "1"
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
