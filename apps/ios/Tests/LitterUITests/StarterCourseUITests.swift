import XCTest
import UIKit

final class StarterCourseUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testDefaultCourseOpensChatsEditsAndResumesWithoutDuplication() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_STARTER_TEST_TOKEN"] = UUID().uuidString
        app.launchArguments = ["--ui-test-starter-course"]
        app.launch()

        openStarterCourse(in: app)
        let start = app.buttons["course-continue"]
        XCTAssertTrue(waitForHittable(start), app.debugDescription)
        XCTAssertTrue(start.label.contains("Start course"))
        capture("Bundled practice course learning path", app)
        start.tap()

        let pageTitle = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "course-page-title-learnfold-getting-started-"
        )).firstMatch
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 20), app.debugDescription)
        let firstTitle = pageTitle.label
        capture("First hands-on lesson", app)

        let next = app.buttons["course-next-lesson"]
        for _ in 0..<12 where !next.isHittable { app.swipeUp() }
        // Reveal the button's center above the native bottom toolbar.
        app.swipeUp()
        XCTAssertTrue(waitForHittable(next), app.debugDescription)
        next.tap()
        XCTAssertTrue(waitForHittable(app.buttons["course-page-ask-ai"]))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in pageTitle.exists && pageTitle.label != firstTitle },
            object: pageTitle
        )], timeout: 20) == .completed)
        let secondTitle = pageTitle.label
        assertPracticeParagraphIsVisible(in: app)
        capture("Next practice lesson", app)

        app.buttons["course-page-ask-ai"].tap()
        let context = app.descendants(matching: .any)
            .matching(identifier: "course-page-chat-context").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(context.staticTexts[secondTitle].exists, app.debugDescription)
        capture("Practice page supplied to Ask AI", app)
        app.navigationBars.buttons["Done"].tap()

        let edit = app.buttons["course-page-edit-toggle"]
        XCTAssertTrue(waitForHittable(edit))
        XCTAssertEqual(edit.label, "Edit page")
        edit.tap()
        XCTAssertEqual(edit.label, "Finish editing")
        XCTAssertFalse(app.buttons["course-page-ask-ai"].exists)
        capture("Practice lesson in the native editor", app)
        edit.tap()
        XCTAssertTrue(waitForHittable(app.buttons["course-page-ask-ai"]))

        app.terminate()
        app.launch()
        openStarterCourse(in: app)
        XCTAssertTrue(waitForHittable(start))
        XCTAssertTrue(start.label.contains("Continue course"))
        start.tap()
        XCTAssertTrue(pageTitle.waitForExistence(timeout: 20))
        XCTAssertEqual(pageTitle.label, secondTitle)
        assertPracticeParagraphIsVisible(in: app)
        capture("Continue restores the practice lesson after relaunch", app)
    }

    @MainActor
    func testReadingSelectionExpandsAskButtonAndKeepsParagraphWhenDragging() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_STARTER_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_STARTER_TEST_SELECTION"] = "1"
        app.launchArguments = ["--ui-test-starter-course"]
        app.launch()
        openStarterCourse(in: app)
        let start = app.buttons["course-continue"]
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        let next = app.buttons["course-next-lesson"]
        for _ in 0..<12 where !next.isHittable { app.swipeUp() }
        app.swipeUp()
        XCTAssertTrue(waitForHittable(next))
        next.tap()
        let paragraph = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@", "Imagine learning a short recipe."
        )).firstMatch
        XCTAssertTrue(waitForHittable(paragraph), app.debugDescription)
        let ask = app.buttons["course-page-ask-ai"]
        XCTAssertEqual(ask.label, "Ask AI about this page")
        paragraph.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 30, dy: 12)).press(forDuration: 1.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Ask about this"), object: ask
        )], timeout: 10), .completed, app.debugDescription)
        XCTAssertGreaterThan(ask.frame.width, 100, "The action must visibly expand beyond its icon")
        capture("Selected word expands the reading AI button", app)
        let origin = paragraph.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 70, dy: 26)).press(
            forDuration: 0.2,
            thenDragTo: origin.withOffset(CGVector(dx: paragraph.frame.width - 5, dy: paragraph.frame.height + 40)),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        XCTAssertEqual(ask.label, "Ask about this", app.debugDescription)
        capture("Selection extended through the practice paragraph", app)
        ask.tap()
        let context = app.descendants(matching: .any).matching(identifier: "focused-qa-state").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), app.debugDescription)
        let passage = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Passage preview. Imagine learning a short recipe."
        )).firstMatch
        XCTAssertTrue(passage.exists, app.debugDescription)
        XCTAssertTrue(passage.label.hasSuffix("explain without help."), passage.label)
        capture("Whole selected paragraph attached to passage chat", app)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(waitForHittable(ask))
        XCTAssertEqual(ask.label, "Ask AI about this page")
    }

    @MainActor
    private func openStarterCourse(in app: XCUIApplication) {
        let title = app.staticTexts["Make Learnfold yours"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), app.debugDescription)
        let splash = app.descendants(matching: .any)
            .matching(identifier: "learnfold-splash-branded-frame").firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: splash
        )], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Make Learnfold yours")).count, 1)
        XCTAssertTrue(waitForHittable(title))
        capture("Default course in an otherwise empty library", app)
        title.tap()
    }

    @MainActor
    private func assertPracticeParagraphIsVisible(in app: XCUIApplication) {
        let paragraph = app.staticTexts.matching(NSPredicate(
            format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
            "You can ask questions while you read.", "You can ask questions while you read."
        )).firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 10), app.debugDescription)
        guard let image = paragraph.screenshot().image.cgImage else {
            XCTFail("The reading paragraph needs a rendered screenshot")
            return
        }
        var luminance = [UInt8](repeating: 0, count: image.width * image.height)
        luminance.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        // AX can find a paragraph whose cached text color matches its background.
        XCTAssertGreaterThan(
            Int(luminance.max() ?? 0) - Int(luminance.min() ?? 0), 80,
            "The paragraph must contain visible text in the current appearance"
        )
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )], timeout: 20) == .completed
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
