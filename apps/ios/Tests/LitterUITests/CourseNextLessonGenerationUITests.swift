import XCTest

/// Exercises the real reader and native persistence with a local agent fixture.
final class CourseNextLessonGenerationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testReplyWithoutSavedLessonStaysOnCurrentPageAndRetries() {
        verifyIncompleteGenerationAndRetry(scenario: "reply-without-save")
    }

    @MainActor
    func testContentWithoutGeneratedStatusStaysOnCurrentPageAndRetries() {
        verifyIncompleteGenerationAndRetry(scenario: "content-without-completion")
    }

    @MainActor
    func testGeneratedStatusWithoutContentStaysOnCurrentPageAndRetries() {
        verifyIncompleteGenerationAndRetry(scenario: "empty-generated")
    }

    @MainActor
    func testSlowGenerationKeepsButtonBusyUntilSavedLessonOpens() {
        let app = openCurrentLesson(scenario: "delayed-save")
        let next = app.buttons["course-next-lesson"]
        next.tap()
        assertGenerating(next, in: app)
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists)
        capture("Current lesson stays visible during generation", app)
        assertGeneratedLesson(in: app)
        XCTAssertFalse(app.staticTexts["course-reading-error"].exists)
        capture("Saved next lesson opens automatically", app)

        app.terminate()
        app.launch()
        let resume = app.buttons["course-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(waitForHittable(resume))
        resume.tap()
        assertGeneratedLesson(in: app)
        capture("Generated lesson persists after relaunch", app)
    }

    @MainActor
    private func verifyIncompleteGenerationAndRetry(scenario: String) {
        let app = openCurrentLesson(scenario: scenario)
        let next = app.buttons["course-next-lesson"]
        next.tap()
        assertGenerating(next, in: app)
        let error = app.staticTexts["course-reading-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(
            error.label.contains("completed lesson") || error.label.contains("lesson content is empty"),
            error.label
        )
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].exists)
        XCTAssertFalse(app.staticTexts["course-page-title-article-three"].exists)
        XCTAssertTrue(waitForHittable(next))
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(next.label.contains("Try again"))
        capture("\(scenario): incomplete lesson stays closed", app)

        next.tap()
        assertGenerating(next, in: app)
        assertGeneratedLesson(in: app)
        XCTAssertFalse(error.exists)
        capture("\(scenario): retry opens saved lesson", app)
    }

    @MainActor
    private func openCurrentLesson(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_GENERATION_SCENARIO"] = scenario
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(app.staticTexts["course-page-title-article-two"].waitForExistence(timeout: 20), app.debugDescription)
        app.swipeUp()
        XCTAssertTrue(waitForHittable(app.buttons["course-next-lesson"]))
        return app
    }

    @MainActor
    private func assertGenerating(_ next: XCUIElement, in app: XCUIApplication) {
        let busy = NSPredicate(format: "label CONTAINS %@ AND enabled == false", "Generating next lesson")
        XCTAssertEqual(XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: busy, object: next)], timeout: 10
        ), .completed, app.debugDescription)
    }

    @MainActor
    private func assertGeneratedLesson(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["course-page-title-article-three"].waitForExistence(timeout: 20), app.debugDescription)
        let content = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'native-editor-block-' AND (label CONTAINS %@ OR value CONTAINS %@)",
            "Arithmetic wraps around", "Arithmetic wraps around"
        )).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "course-reading-end").firstMatch.exists)
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
