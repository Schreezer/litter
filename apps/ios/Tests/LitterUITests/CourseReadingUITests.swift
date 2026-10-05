import XCTest

final class CourseReadingUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testPageChatKeepsSeparateDiscussionHistoryAcrossReopeningAndRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()

        let courseHistory = "Course-only discussion: the complete SNARKs learning plan."
        let firstQuestion = "What can this proof reveal?"
        let firstReply = "Page-one discussion: a proof reveals validity without exposing the secret."
        let secondQuestion = "Why is the challenge random?"
        let secondReply = "The local chat fixture received your question and the current lesson content."
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)

        let courseChat = app.buttons["talk-to-course-agent-button"]
        XCTAssertTrue(waitForHittable(courseChat))
        courseChat.tap()
        XCTAssertTrue(app.staticTexts[courseHistory].waitForExistence(timeout: 15), app.debugDescription)
        capture("Existing course discussion", app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app))

        openPageChat("What a proof reveals", in: app)
        XCTAssertFalse(app.staticTexts[courseHistory].exists, "A new page discussion must not restore course history")
        capture("First page starts its own discussion", app)
        sendChatQuestion(firstQuestion, in: app)
        XCTAssertTrue(app.staticTexts[firstReply].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.staticTexts[courseHistory].exists)
        capture("First page question and answer", app)

        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(waitForPage("article-one", in: app))
        openPageChat("What a proof reveals", in: app)
        XCTAssertTrue(app.staticTexts[firstReply].waitForExistence(timeout: 15), "Reopening the page must restore its linked discussion")
        XCTAssertTrue(app.staticTexts[firstQuestion].exists)
        XCTAssertFalse(app.staticTexts[courseHistory].exists)
        capture("First page reopens its discussion", app)
        app.navigationBars.buttons["Done"].tap()

        let next = app.buttons["course-next-lesson"]
        for _ in 0..<22 where !next.isHittable { app.swipeUp() }
        app.swipeUp()
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        openPageChat("A verifier's challenge", in: app)
        XCTAssertFalse(app.staticTexts[firstReply].exists, "A different page must have a separate discussion")
        XCTAssertFalse(app.staticTexts[firstQuestion].exists)
        XCTAssertFalse(app.staticTexts[courseHistory].exists)
        sendChatQuestion(secondQuestion, in: app)
        XCTAssertTrue(app.staticTexts[secondReply].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(app.staticTexts[firstReply].exists)
        capture("Second page has separate history", app)

        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        openPageChat("A verifier's challenge", in: app)
        XCTAssertTrue(app.staticTexts[secondReply].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts[secondQuestion].exists)
        XCTAssertFalse(app.staticTexts[firstReply].exists)
        capture("Second page reopens its discussion", app)

        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        openPageChat("A verifier's challenge", in: app)
        XCTAssertTrue(app.staticTexts[secondReply].waitForExistence(timeout: 15), "The persisted page link must survive app relaunch")
        XCTAssertTrue(app.staticTexts[secondQuestion].exists)
        XCTAssertFalse(app.staticTexts[firstReply].exists)
        XCTAssertFalse(app.staticTexts[courseHistory].exists)
        capture("Second page discussion restored after relaunch", app)
        app.navigationBars.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(waitForHittable(courseChat))
        courseChat.tap()
        XCTAssertTrue(app.staticTexts[courseHistory].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts[firstReply].exists)
        XCTAssertFalse(app.staticTexts[secondReply].exists)
        capture("Course discussion remains separate", app)
        app.navigationBars.buttons.firstMatch.tap()

        let structure = app.segmentedControls["course-detail-section-picker"].buttons["Structure"]
        XCTAssertTrue(waitForHittable(structure))
        structure.tap()
        let expandSection = app.buttons["course-page-expand-section"]
        XCTAssertTrue(waitForHittable(expandSection))
        if expandSection.label.hasPrefix("Expand") { expandSection.tap() }
        let firstPage = app.descendants(matching: .any)
            .matching(identifier: "course-page-row-article-one").firstMatch
        for _ in 0..<4 where !firstPage.exists || !firstPage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(waitForHittable(firstPage), app.debugDescription)
        firstPage.tap()
        XCTAssertTrue(waitForPage("article-one", in: app))
        openPageChat("What a proof reveals", in: app)
        XCTAssertTrue(app.staticTexts[firstReply].waitForExistence(timeout: 15), "The first page must still restore its original discussion after relaunch")
        XCTAssertTrue(app.staticTexts[firstQuestion].exists)
        XCTAssertFalse(app.staticTexts[secondReply].exists)
        XCTAssertFalse(app.staticTexts[courseHistory].exists)
        capture("First page keeps its original discussion after relaunch", app)
    }

    @MainActor
    func testPageChatOpensWithCurrentPageAndReturnsToReading() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_TEST_APPEARANCE"] = "dark"
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25))
        XCTAssertEqual(app.staticTexts["reading-fixture"].value as? String, "dark")
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app))
        let ask = app.buttons["course-page-ask-ai"]
        XCTAssertTrue(waitForHittable(ask))
        app.swipeUp()
        XCTAssertTrue(ask.isHittable, "Chat stays available while reading")
        capture("Ask AI native page toolbar", app)
        ask.tap()
        let context = app.descendants(matching: .any).matching(identifier: "course-page-chat-context").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(context.staticTexts["What a proof reveals"].exists)
        capture("AI chat with current page context", app)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(waitForPage("article-one", in: app))
        XCTAssertTrue(waitForHittable(ask))
        app.buttons["course-page-edit-toggle"].tap()
        XCTAssertFalse(ask.exists, "Reading chat does not cover editing controls")
        app.buttons["course-page-edit-toggle"].tap()
        XCTAssertTrue(waitForHittable(ask))
        let next = app.buttons["course-next-lesson"]
        for _ in 0..<22 where !next.isHittable { app.swipeUp() }
        // XCTest reports a partly exposed button as hittable, but its center
        // can still lie behind the native bottom toolbar. Reveal it fully.
        app.swipeUp()
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        XCTAssertTrue(waitForHittable(ask))
        ask.tap()
        XCTAssertTrue(context.waitForExistence(timeout: 15))
        XCTAssertTrue(context.staticTexts["A verifier's challenge"].exists)
        XCTAssertFalse(context.staticTexts["What a proof reveals"].exists)
        capture("AI chat follows the next page", app)
        let composer = app.descendants(matching: .any).matching(identifier: "course-chat-composer").firstMatch
        XCTAssertTrue(waitForHittable(composer))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        capture("Rounded composer with keyboard in dark mode", app)
        composer.typeText("Why is the challenge random?")
        let send = app.buttons["course-chat-send"]
        XCTAssertTrue(waitForHittable(send))
        send.tap()
        XCTAssertTrue(app.staticTexts[
            "The local chat fixture received your question and the current lesson content."
        ].waitForExistence(timeout: 20), app.debugDescription)
        capture("Page question dispatched with lesson content", app)

        app.terminate()
        app.launchEnvironment["LEARNFOLD_READING_TEST_APPEARANCE"] = "light"
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 25))
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        XCTAssertTrue(waitForHittable(ask))
        ask.tap()
        XCTAssertTrue(waitForHittable(composer))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        capture("Rounded composer with keyboard in light mode", app)
    }

    @MainActor
    func testInteractiveVisualizationRendersAndRunsJavaScript() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()

        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app), app.debugDescription)

        let webView = app.webViews.matching(identifier: "html-block-0").firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 15), app.debugDescription)
        let advance = app.buttons["Advance simulation"].firstMatch
        XCTAssertTrue(advance.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForHittable(advance))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Round 1: prover sends a commitment."))
                .firstMatch.exists
        )
        capture("Interactive visualization initial state", app)

        advance.tap()

        let changedState = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label == %@",
                "Round 2: verifier sends a random challenge."
            ))
            .firstMatch
        XCTAssertTrue(changedState.waitForExistence(timeout: 10), app.debugDescription)
        capture("Interactive visualization after JavaScript interaction", app)
    }

    @MainActor
    func testLegacyQuestionSectionStaysHiddenWhileReading() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_TEST_APPEARANCE"] = "dark"
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app))
        let next = app.buttons["course-next-lesson"]
        for _ in 0..<22 where !next.isHittable { app.swipeUp() }
        app.swipeUp()
        XCTAssertTrue(next.isHittable)
        next.tap()
        XCTAssertTrue(waitForPage("article-two", in: app))

        // Pages written before the questions feature was removed still carry a
        // trailing "Keep asking" list. Reading must not surface it, as prompts
        // or as page text.
        XCTAssertFalse(app.buttons["course-follow-up-question-0"].exists)
        let questionBlocks = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'native-editor-block-' AND (label CONTAINS %@ OR value CONTAINS %@)",
            "Why is the challenge random?", "Why is the challenge random?"
        ))
        XCTAssertEqual(questionBlocks.count, 0, app.debugDescription)
        capture("Lesson end without question prompts", app)

        // Editing still shows the leftover section so it can be deleted.
        app.buttons["course-page-edit-toggle"].tap()
        XCTAssertTrue(questionBlocks.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["course-page-edit-toggle"].tap()
        XCTAssertTrue(waitForPage("article-two", in: app))
        XCTAssertEqual(questionBlocks.count, 0, app.debugDescription)
    }

    @MainActor
    func testResumeNextGenerationRetryAndCourseEnd() {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        XCTAssertTrue(app.buttons["talk-to-course-agent-button"].isHittable)
        capture("Floating course actions", app)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app), app.debugDescription)
        let next = app.buttons["course-next-lesson"]
        for _ in 0..<22 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.isHittable)
        app.swipeUp()
        capture("Article end with Next", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(start.label.contains("Continue course"))
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(next.isHittable, "Continue must restore the end without another scroll")
        capture("Continue restored article end", app)
        next.tap()
        XCTAssertTrue(waitForPage("article-two", in: app), app.debugDescription)
        XCTAssertTrue(next.isHittable)
        next.tap()
        let generating = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Generating next lesson"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [generating], timeout: 10), .completed)
        XCTAssertFalse(next.isEnabled)
        capture("Generating next lesson", app)
        XCTAssertTrue(app.staticTexts["course-reading-error"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(next.isEnabled)
        capture("Generation retry", app)
        next.tap()
        XCTAssertTrue(waitForPage("article-three", in: app))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "course-reading-end").firstMatch.exists)
        capture("Generated final lesson", app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Back should return directly to the course")
    }

    @MainActor
    func testContinueRestoresPositionWithinLongArticle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(waitForPage("article-one", in: app), app.debugDescription)
        app.swipeUp()
        app.swipeUp()
        let visible = app.descendants(matching: .any).allElementsBoundByIndex.first {
            $0.identifier.hasPrefix("native-editor-block-")
                && $0.frame.minY > 170 && $0.frame.maxY < 740 && $0.isHittable
        }
        let landmark = try XCTUnwrap(visible, app.debugDescription)
        let identifier = landmark.identifier
        let originalY = landmark.frame.minY
        capture("Mid-article saved position", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        let restored = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 15), app.debugDescription)
        let positionRestored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(restored.frame.minY - originalY) < 30 }, object: restored
        )
        XCTAssertEqual(XCTWaiter.wait(for: [positionRestored], timeout: 10), .completed)
        capture("Mid-article position restored", app)
    }

    @MainActor
    private func waitForPage(_ pageID: String, in app: XCUIApplication) -> Bool {
        app.staticTexts["course-page-title-\(pageID)"].waitForExistence(timeout: 20)
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )], timeout: 20) == .completed
    }

    @MainActor
    private func openPageChat(_ title: String, in app: XCUIApplication) {
        let ask = app.buttons["course-page-ask-ai"]
        XCTAssertTrue(waitForHittable(ask))
        ask.tap()
        let context = app.descendants(matching: .any)
            .matching(identifier: "course-page-chat-context").firstMatch
        XCTAssertTrue(context.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(context.staticTexts[title].exists)
    }

    @MainActor
    private func sendChatQuestion(_ question: String, in app: XCUIApplication) {
        let composer = app.descendants(matching: .any)
            .matching(identifier: "course-chat-composer").firstMatch
        XCTAssertTrue(waitForHittable(composer))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        for character in question {
            composer.typeText(String(character))
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", question), object: composer
        )], timeout: 10), .completed, app.debugDescription)
        XCTAssertEqual(composer.value as? String, question, app.debugDescription)
        let send = app.buttons["course-chat-send"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
            object: send
        )], timeout: 20), .completed, app.debugDescription)
        send.tap()
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
