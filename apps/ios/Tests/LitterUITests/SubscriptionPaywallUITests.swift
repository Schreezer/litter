import XCTest

/// Drives the real paywall on a bare screen and exports screenshots. The
/// store behind it is the debug fixture (no Apple Account, sandbox or network).
final class SubscriptionPaywallUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = ["--ui-test-subscription-paywall"] + extraArguments
        app.launch()
        dismissSimulatorAccountAlert()
        return app
    }

    /// A simulator that is signed in to an Apple Account can raise a system
    /// "Apple Account Verification" alert over any app that has just launched.
    /// It comes from SpringBoard, not Learnfold, and would otherwise cover the
    /// paywall in screenshots. Decline it so the evidence shows the real UI.
    @MainActor
    private func dismissSimulatorAccountAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 4), alert.buttons["Not Now"].exists {
            alert.buttons["Not Now"].tap()
        }
    }

    @MainActor
    func testPaywallShowsPlansPricingRenewalTermsAndRequiredLinks() {
        let app = launch()

        XCTAssertTrue(app.descendants(matching: .any)["paywall.root"].waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["paywall.headline"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.plan.hosted"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.plan.plus"].exists)

        let hostedPrice = app.staticTexts["paywall.price.hosted"]
        XCTAssertTrue(hostedPrice.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(hostedPrice.label.contains("month"), hostedPrice.label)
        XCTAssertTrue(app.staticTexts["paywall.price.plus"].exists)
        XCTAssertTrue(app.buttons["paywall.subscribe.hosted"].isEnabled)
        XCTAssertTrue(app.buttons["paywall.subscribe.plus"].isEnabled)
        XCTAssertFalse(app.staticTexts["paywall.offers-error"].exists)
        capture("Paywall plans", app)

        let restore = app.buttons["paywall.restore"]
        app.swipeUp()
        for _ in 0..<6 where !restore.isHittable { app.swipeUp() }
        XCTAssertTrue(restore.exists)
        XCTAssertTrue(app.buttons["paywall.manage"].exists)
        XCTAssertTrue(app.staticTexts["paywall.terms"].exists)
        XCTAssertTrue(app.staticTexts["paywall.terms"].label.contains("renews automatically"))
        XCTAssertTrue(app.links["Terms of Use"].exists || app.buttons["Terms of Use"].exists)
        XCTAssertTrue(app.links["Privacy Policy"].exists || app.buttons["Privacy Policy"].exists)
        capture("Paywall terms and links", app)
    }

    @MainActor
    func testSubscribingClosesThePaywallOnceThePlanCoversWhatWasRequested() {
        let app = launch()
        let subscribe = app.buttons["paywall.subscribe.hosted"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(subscribe.waitForNonExistence(after: { subscribe.tap() }, timeout: 20), app.debugDescription)
    }

    @MainActor
    func testWithoutPurchaseSupportThePaywallSaysSoAndDoesNotBreak() {
        let app = launch(extraArguments: ["--ui-test-subscriptions-unavailable"])

        XCTAssertTrue(app.descendants(matching: .any)["paywall.root"].waitForExistence(timeout: 60), app.debugDescription)
        let unavailable = app.staticTexts["paywall.offers-error"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(unavailable.label.contains("Purchases are unavailable"), unavailable.label)
        XCTAssertFalse(app.buttons["paywall.subscribe.hosted"].isEnabled)
        XCTAssertFalse(app.buttons["paywall.subscribe.plus"].isEnabled)
        XCTAssertFalse(app.buttons["paywall.retry"].exists, "Retrying can't help a build with no purchase backend")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '$'")).firstMatch.exists,
            "No price may be shown or invented when purchases are unavailable"
        )
        capture("Paywall purchases unavailable", app)

        // Restore, terms and legal links remain reachable and don't crash.
        let restore = app.buttons["paywall.restore"]
        for _ in 0..<6 where !restore.isHittable { app.swipeUp() }
        restore.tap()
        XCTAssertTrue(app.staticTexts["paywall.error"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["paywall.terms"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.root"].exists)
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        dismissSimulatorAccountAlert()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    /// Runs `action`, then waits for this element to go away.
    func waitForNonExistence(after action: () -> Void, timeout: TimeInterval) -> Bool {
        action()
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
