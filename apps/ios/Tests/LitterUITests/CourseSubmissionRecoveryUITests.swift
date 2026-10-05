import XCTest

/// A learner sends a course-chat message, the app is killed while the reply is
/// pending, and the app is reopened. Check Status must settle whether the
/// message arrived instead of leaving the chat stuck on "Unable to continue".
final class CourseSubmissionRecoveryUITests: XCTestCase {
    private let answer = "The telomeres keep getting shorter until cells stop dividing"

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testCheckStatusRestoresAMessageThatNeverReachedTheServer() {
        let app = relaunchAfterInterruptedSend(delivery: "lost")

        let strip = element("course-submission-recovery", in: app)
        XCTAssertTrue(
            strip.staticTexts["Message not sent · Draft restored"].waitForExistence(timeout: 10),
            app.debugDescription
        )
        let composer = element("course-chat-composer", in: app)
        XCTAssertEqual(composer.value as? String, answer, "The unsent message is back in the composer")

        // The learner can send it again and the conversation continues.
        let send = app.buttons["course-chat-send"]
        XCTAssertTrue(waitForEnabled(send), app.debugDescription)
        send.tap()
        XCTAssertTrue(app.staticTexts[replyText].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitForDisappearance(strip))
    }

    @MainActor
    func testCheckStatusResumesAMessageTheServerAlreadyReceived() {
        let app = relaunchAfterInterruptedSend(delivery: "received")

        let strip = element("course-submission-recovery", in: app)
        XCTAssertTrue(waitForDisappearance(strip), app.debugDescription)
        XCTAssertTrue(app.staticTexts[answer].exists, "The delivered message stays in the thread")
        XCTAssertTrue(app.staticTexts[replyText].waitForExistence(timeout: 10), app.debugDescription)
        let composer = element("course-chat-composer", in: app)
        XCTAssertNotEqual(
            composer.value as? String,
            answer,
            "A delivered message must not stay in the composer, where sending it would duplicate it"
        )
    }

    // MARK: - Scenario

    private let replyText = "Good start. Telomere shortening is one hallmark of aging; we will build from there."

    /// Sends `answer`, kills the app while the reply is pending, reopens it,
    /// and taps Check Status on the preserved draft.
    @MainActor
    private func relaunchAfterInterruptedSend(delivery: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_SUBMISSION_RECOVERY_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_SUBMISSION_RECOVERY_DELIVERY"] = delivery
        app.launchEnvironment["LEARNFOLD_SUBMISSION_RECOVERY_PHASE"] = "interrupt"
        app.launchArguments = ["--ui-test-course-submission-recovery"]
        app.launch()

        let question = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "why you think humans age")
        ).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 25), app.debugDescription)

        let composer = element("course-chat-composer", in: app)
        XCTAssertTrue(waitForHittable(composer), app.debugDescription)
        composer.tap()
        composer.typeText(answer)
        let send = app.buttons["course-chat-send"]
        XCTAssertTrue(waitForEnabled(send), app.debugDescription)
        send.tap()
        XCTAssertTrue(app.staticTexts[answer].waitForExistence(timeout: 10), app.debugDescription)
        // Let the pending submission reach durable storage, then kill the app
        // mid-reply, as when the learner swipes it away.
        Thread.sleep(forTimeInterval: 2)
        app.terminate()

        app.launchEnvironment["LEARNFOLD_SUBMISSION_RECOVERY_PHASE"] = "resume"
        app.launch()

        let strip = element("course-submission-recovery", in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(
            strip.staticTexts["Status unknown · Draft preserved"].exists,
            "Reopening shows the interrupted message as unconfirmed"
        )
        let checkStatus = element("course-submission-recovery.check-status", in: app)
        XCTAssertTrue(waitForHittable(checkStatus), app.debugDescription)
        checkStatus.tap()

        // The check has finished once the strip moves off "Status unknown".
        let settled = NSPredicate { _, _ in
            !strip.exists || !strip.staticTexts["Status unknown · Draft preserved"].exists
                || app.staticTexts["Unable to continue"].exists
        }
        _ = XCTWaiter.wait(for: [expectation(for: settled, evaluatedWith: nil)], timeout: 15)
        XCTAssertFalse(
            app.staticTexts["Unable to continue"].exists,
            "Check Status must settle the interrupted message, not report it as still unconfirmed. \(app.debugDescription)"
        )
        return app
    }

    // MARK: - Helpers

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        return XCTWaiter.wait(
            for: [expectation(for: predicate, evaluatedWith: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        return XCTWaiter.wait(
            for: [expectation(for: predicate, evaluatedWith: element)],
            timeout: timeout
        ) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter.wait(
            for: [expectation(for: predicate, evaluatedWith: element)],
            timeout: timeout
        ) == .completed
    }
}
