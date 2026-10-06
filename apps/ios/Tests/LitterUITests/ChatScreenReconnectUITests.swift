import XCTest

final class ChatScreenReconnectUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testRetryProgressDisappearsWhenAnswerResumes() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--chat-screen-harness",
            "--chat-autosend",
            "--chat-scenario", "reconnect",
            "--chat-time-scale", "1.5",
        ]
        app.launch()

        let progress = app.staticTexts["chat-phase-caption"]
        let retry = NSPredicate(format: "exists == true AND label == %@", "Reconnecting... 1/5")
        wait(for: [expectation(for: retry, evaluatedWith: progress)], timeout: 35)
        XCTAssertFalse(app.descendants(matching: .any)["chat-notice"].exists)
        capture("Retry in progress", app)

        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: progress)], timeout: 10)
        let probe = app.descendants(matching: .any)["chat-state-probe"]
        XCTAssertTrue((probe.value as? String)?.contains("phase=streaming") == true)
        XCTAssertFalse(app.descendants(matching: .any)["chat-connection-banner"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat-notice"].exists)
        capture("Answer resumed without retry notice", app)

        let settled = NSPredicate(format: "value CONTAINS 'phase=settled'")
        wait(for: [expectation(for: settled, evaluatedWith: probe)], timeout: 40)
        XCTAssertFalse(progress.exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat-notice"].exists)
        capture("Completed without retry notice", app)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
