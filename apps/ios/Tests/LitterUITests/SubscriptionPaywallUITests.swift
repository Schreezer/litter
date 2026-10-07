import XCTest

/// Drives the real paywall against the local StoreKit configuration
/// (`Support/Learnfold.storekit`) and exports screenshots for review.
final class SubscriptionPaywallUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPaywallShowsLocalizedPricesRenewalTermsAndRequiredLinks() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = ["--ui-test-subscription-paywall"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["paywall.root"].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["paywall.headline"].exists)

        // Prices come from StoreKit, so these only exist once products load.
        let hostedPrice = app.staticTexts["paywall.price.hosted"]
        let plusPrice = app.staticTexts["paywall.price.plus"]
        XCTAssertTrue(hostedPrice.waitForExistence(timeout: 20), "Products did not load: \n\(app.debugDescription)")
        XCTAssertTrue(plusPrice.exists)
        XCTAssertTrue(hostedPrice.label.contains("5"), hostedPrice.label)
        XCTAssertTrue(plusPrice.label.contains("1"), plusPrice.label)
        XCTAssertTrue(hostedPrice.label.contains("month"), hostedPrice.label)

        XCTAssertTrue(app.buttons["paywall.subscribe.hosted"].isEnabled)
        XCTAssertTrue(app.buttons["paywall.subscribe.plus"].isEnabled)
        capture("Paywall plans", app)

        let restore = app.buttons["paywall.restore"]
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
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
