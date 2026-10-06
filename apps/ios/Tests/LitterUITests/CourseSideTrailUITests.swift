import XCTest

/// Captures how explorations branch off the Learn path, using the static
/// learning-path harness (nested trails, read, pinned, writing, and new).
final class CourseSideTrailUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testSideTrailsBranchOffTheirLesson() {
        let app = launch()
        let lesson = app.descendants(matching: .any)["course-learning-node-intro"]
        XCTAssertTrue(lesson.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(lesson.label.contains("6 explorations"), lesson.label)

        let read = app.buttons["course-branch-why-bey"]
        XCTAssertTrue(read.exists)
        XCTAssertTrue(read.label.contains("Read"), read.label)
        let goal = app.buttons["course-branch-bey-history"]
        XCTAssertTrue(goal.exists, "Short first forks stay open to show their deeper trails.")
        XCTAssertTrue(goal.label.contains("Goal"), goal.label)
        XCTAssertFalse(app.buttons["course-branch-explore-auction"].exists,
                       "Third-level trails stay folded until the learner opens them.")
        capture("Side trails off a lesson", app)

        app.buttons["course-branch-toggle-bey-history"].tap()
        XCTAssertTrue(app.buttons["course-branch-explore-auction"].waitForExistence(timeout: 5))
        capture("A deeper trail unfolds", app)

        app.swipeUp()
        capture("Side trails continue below", app)
    }

    @MainActor
    func testLearnerDeepInATrailSeesWhereTheyAre() {
        let app = launch(arguments: ["--ui-test-learning-path-in-exploration"])
        let here = app.buttons["course-branch-explore-auction"]
        XCTAssertTrue(here.waitForExistence(timeout: 20), "The trail to the learner opens by itself.")
        XCTAssertTrue(here.label.contains("You are here"), here.label)
        if !here.isHittable { app.swipeUp() }
        capture("You are here, three trails deep", app)
    }

    @MainActor
    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-course-learning-path"] + arguments
        app.launch()
        dismissSystemPrompt()
        return app
    }

    /// The simulator's Apple Account may ask for a password over the app.
    @MainActor
    private func dismissSystemPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = springboard.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 4) { notNow.tap() }
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
