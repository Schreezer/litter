import XCTest

/// Opening the keyboard on a settled chat must not move the newest turn out
/// of view: it stays where it was if it fits above the composer, and
/// otherwise its end sits just above the composer.
final class ChatScreenKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testKeyboardKeepsShortSettledTurnInPlace() {
        let app = launchSettledHarness(scenario: "brief")
        let bubble = liveUserBubble(in: app)
        let answer = app.descendants(matching: .any)["chat-answer-answer-2"]
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let bubbleTop = bubble.frame.minY
        capture("Settled before keyboard", app)

        openKeyboard(in: app)
        capture("Settled with keyboard", app)

        XCTAssertEqual(bubble.frame.minY, bubbleTop, accuracy: 2, "The newest turn stays put")
        XCTAssertLessThanOrEqual(answer.frame.maxY, composerTop(in: app) + 1, "The reply stays above the composer")

        hideKeyboard(in: app)
        capture("Settled after hiding keyboard", app)
        XCTAssertEqual(bubble.frame.minY, bubbleTop, accuracy: 2, "Closing the keyboard doesn't move the turn")
    }

    @MainActor
    func testKeyboardKeepsEndOfLongSettledTurnAboveComposer() {
        let app = launchSettledHarness(scenario: "happy")
        let lastOption = app.buttons["Brain aging and repair"]
        XCTAssertTrue(lastOption.waitForExistence(timeout: 5))
        capture("Long turn before keyboard", app)

        openKeyboard(in: app)
        capture("Long turn with keyboard", app)

        let gap = composerTop(in: app) - lastOption.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, -1, "The end of the reply stays above the composer")
        XCTAssertLessThan(gap, 120, "The end of the reply sits just above the composer")

        hideKeyboard(in: app)
        capture("Long turn after hiding keyboard", app)
        let gapAfter = composerTop(in: app) - lastOption.frame.maxY
        XCTAssertGreaterThanOrEqual(gapAfter, -1, "The end of the reply stays above the composer")
        XCTAssertLessThan(gapAfter, 120, "The end of the reply sits just above the composer")
    }

    /// The course flow from the bug report: send (the course composer drops
    /// the keyboard), read the reply, then tap the composer to answer.
    @MainActor
    func testComposerFocusAfterReplyKeepsTurnInPlace() {
        let app = launchSettledHarness(scenario: "brief")
        openKeyboard(in: app)
        app.typeText("What scars the brain?")
        app.buttons["chat-send"].tap()
        hideKeyboard(in: app)
        let bubble = liveUserBubble(in: app)
        // Simulator typing can garble the draft, so wait for the live turn
        // to stop being the auto-sent one rather than for exact text.
        let sent = NSPredicate(format: "NOT (label BEGINSWITH 'It picks up')")
        wait(for: [expectation(for: sent, evaluatedWith: bubble)], timeout: 10)
        waitUntilSettled(app)

        let bubbleTop = bubble.frame.minY
        XCTAssertLessThan(bubbleTop - app.navigationBars.firstMatch.frame.maxY, 40, "The new turn starts at the top")
        capture("Reply before keyboard", app)

        openKeyboard(in: app)
        capture("Reply with keyboard", app)
        XCTAssertEqual(bubble.frame.minY, bubbleTop, accuracy: 2, "The newest turn stays put")
    }

    // MARK: - Helpers

    @MainActor
    private func launchSettledHarness(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--chat-screen-harness",
            "--chat-history",
            "--chat-autosend",
            "--chat-scenario", scenario,
            "--chat-time-scale", "0.1",
        ]
        app.launch()
        waitUntilSettled(app)
        return app
    }

    @MainActor
    private func waitUntilSettled(_ app: XCUIApplication) {
        let probe = app.descendants(matching: .any)["chat-state-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        let settled = NSPredicate(format: "value CONTAINS 'phase=settled'")
        wait(for: [expectation(for: settled, evaluatedWith: probe)], timeout: 30)
        // Let the send hand-off and fold animations finish.
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func liveUserBubble(in app: XCUIApplication) -> XCUIElement {
        let liveTurn = app.descendants(matching: .any)["chat-live-turn"]
        XCTAssertTrue(liveTurn.waitForExistence(timeout: 5))
        let bubble = liveTurn.descendants(matching: .any)["chat-user-bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        return bubble
    }

    /// Needs the software keyboard: a simulator with a hardware keyboard
    /// connected never shows it.
    @MainActor
    private func openKeyboard(in app: XCUIApplication) {
        let composer = app.descendants(matching: .any)["chat-composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func hideKeyboard(in app: XCUIApplication) {
        app.buttons["chat-harness-hide-keyboard"].tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)], timeout: 10)
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func composerTop(in app: XCUIApplication) -> CGFloat {
        app.descendants(matching: .any)["chat-composer-container"].frame.minY
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
