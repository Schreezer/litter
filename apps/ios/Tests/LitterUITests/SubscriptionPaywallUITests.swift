import XCTest

/// Drives the real paywall on a bare screen and exports screenshots.
final class SubscriptionPaywallUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPaywallShowsHonestPricingRenewalTermsAndRequiredLinks() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchArguments = ["--ui-test-subscription-paywall"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["paywall.root"].waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["paywall.headline"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.plan.hosted"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["paywall.plan.plus"].exists)

        // Prices only ever come from StoreKit. With products loaded they show
        // here; without them (xcodebuild's test action does not attach the
        // local .storekit file) the paywall must say so and block purchase
        // rather than invent a price. Either state is acceptable here; the
        // StoreKitTest integration test pins the real prices.
        let hostedPrice = app.staticTexts["paywall.price.hosted"]
        let offersError = app.staticTexts["paywall.offers-error"]
        let deadline = Date().addingTimeInterval(20)
        while !hostedPrice.exists && !offersError.exists && Date() < deadline {
            _ = hostedPrice.waitForExistence(timeout: 1)
        }
        if hostedPrice.exists {
            XCTAssertTrue(hostedPrice.label.contains("month"), hostedPrice.label)
            XCTAssertTrue(app.buttons["paywall.subscribe.hosted"].isEnabled)
        } else {
            XCTAssertTrue(offersError.exists, app.debugDescription)
            XCTAssertFalse(app.buttons["paywall.subscribe.hosted"].isEnabled)
            XCTAssertFalse(app.buttons["paywall.subscribe.plus"].isEnabled)
            XCTAssertTrue(app.buttons["paywall.retry"].exists)
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS '$'")).firstMatch.exists,
                "No price may be hardcoded in the UI"
            )
        }
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
