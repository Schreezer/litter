import XCTest

final class CourseAssessmentUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testMultipleChoiceRevealsFeedbackAfterSubmissionAndAllowsRetry() {
        let app = launchFixture()
        openFirstPage(in: app)
        assertAssessmentsCollapsed(in: app)
        capture("Optional exercises are collapsed on first opening", app)
        let start = app.buttons["course-assessment-start-oxygen-check"]
        reveal(start, in: app)
        XCTAssertFalse(element("course-assessment-feedback-oxygen-check", in: app).exists)
        XCTAssertFalse(app.staticTexts[
            "ATP supplies energy for ion pumps; when oxygen loss lowers ATP, pumping fails."
        ].exists, "The authored explanation stays hidden before an answer is submitted")
        assertNoRawAssessmentData(in: app)
        capture("Optional native check before starting", app)
        start.tap()

        tap("course-assessment-option-oxygen-check-a", in: app)
        tap("course-assessment-submit-oxygen-check", in: app)
        let feedback = element("course-assessment-feedback-oxygen-check", in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: 15), app.debugDescription)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Worth another look"].exists)
        XCTAssertTrue(app.staticTexts[
            "ATP supplies energy for ion pumps; when oxygen loss lowers ATP, pumping fails."
        ].exists)
        XCTAssertFalse(element("course-page-chat-context", in: app).exists)
        capture("Incorrect option receives supportive feedback", app)

        tap("course-assessment-retry-oxygen-check", in: app)
        XCTAssertFalse(feedback.exists, "A new attempt does not reveal the previous answer key")
        tap("course-assessment-option-oxygen-check-b", in: app)
        tap("course-assessment-submit-oxygen-check", in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: 15))
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Well understood"].exists)
        capture("Correct option after retry", app)
        let next = element("course-next-lesson", in: app)
        reveal(next, in: app)
        XCTAssertTrue(next.isEnabled, "An optional check never gates the next lesson")
    }

    @MainActor
    func testFreeTextDraftAndReviewedResultSurviveRelaunchWithoutOpeningChat() {
        let app = launchFixture()
        openFirstPage(in: app)
        tap("course-assessment-start-energy-explain", in: app)
        let answer = element("course-assessment-answer-energy-explain", in: app)
        reveal(answer, in: app)
        answer.tap()
        answer.typeText("ATP powers pumps")
        dismissAssessmentKeyboard(in: app)
        setAssessmentsExpanded(false, in: app)
        XCTAssertFalse(answer.exists, "Collapsing optional exercises hides the answer field")
        setAssessmentsExpanded(true, in: app)
        reveal(answer, in: app)
        XCTAssertEqual(answer.value as? String, "ATP powers pumps",
                       "Collapsing optional exercises preserves the draft")
        capture("Free text draft", app)

        app.terminate()
        app.launch()
        resumeCourse(in: app, expectedPageID: "article-one")
        assertAssessmentsCollapsed(in: app)
        reveal(answer, in: app)
        XCTAssertEqual(answer.value as? String, "ATP powers pumps")
        XCTAssertFalse(element("course-assessment-feedback-energy-explain", in: app).exists)
        capture("Free text draft restored after relaunch", app)
        tap("course-assessment-submit-energy-explain", in: app)
        let feedback = element("course-assessment-feedback-energy-explain", in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: 15), app.debugDescription)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Well understood"].exists)
        XCTAssertTrue(app.staticTexts["You connected ATP to the energy that ion pumps need."].exists)
        XCTAssertFalse(element("course-page-chat-context", in: app).exists,
                       "A sufficient answer receives feedback on the reading page")
        capture("Free text understood without opening chat", app)
        setAssessmentsExpanded(false, in: app)
        XCTAssertFalse(feedback.exists, "Collapsing the section hides its reviewed cards")
        setAssessmentsExpanded(true, in: app)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["You connected ATP to the energy that ion pumps need."].exists,
                      "Collapsing optional exercises preserves reviewed feedback")

        app.terminate()
        app.launch()
        resumeCourse(in: app, expectedPageID: "article-one")
        assertAssessmentsCollapsed(in: app)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Well understood"].exists)
        XCTAssertTrue(app.staticTexts["You connected ATP to the energy that ion pumps need."].exists)
        XCTAssertEqual(answer.value as? String, "ATP powers pumps")
        XCTAssertFalse(answer.isEnabled)
        XCTAssertFalse(element("course-page-chat-context", in: app).exists)
        capture("Reviewed free text result restored after relaunch", app)
    }

    @MainActor
    func testFreeTextFollowUpOpensPageChatWithTutorSpeakingFirst() {
        let app = launchFixture()
        openFirstPage(in: app)
        tap("course-assessment-start-energy-explain", in: app)
        let answer = element("course-assessment-answer-energy-explain", in: app)
        reveal(answer, in: app)
        answer.tap()
        answer.typeText("DNA makes oxygen")
        dismissAssessmentKeyboard(in: app)
        tap("course-assessment-submit-energy-explain", in: app)

        let context = element("course-page-chat-context", in: app)
        XCTAssertTrue(context.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(context.staticTexts["Molecular machinery and cellular energetics"].exists)
        let question = "What do ion pumps need to keep working?"
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["DNA makes oxygen"].exists,
                       "The learner's exercise answer is context, not a fabricated chat turn")
        assertNoAssessmentControlTurn(in: app)
        XCTAssertFalse(app.staticTexts["Course-only discussion: the complete SNARKs learning plan."].exists)
        capture("Tutor starts the focused page follow-up", app)

        sendChatAnswer("Ion pumps need ATP.", in: app)
        let reply = "Yes. ATP provides the energy that keeps ion pumps working."
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Ion pumps need ATP."].exists)
        assertNoAssessmentControlTurn(in: app)
        capture("Learner answers the tutor's first question", app)
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(element("course-page-title-article-one", in: app).waitForExistence(timeout: 15))
        let feedback = element("course-assessment-feedback-energy-explain", in: app)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Worth another look"].exists)
        XCTAssertTrue(app.staticTexts["DNA stores information; ion pumps need ATP to keep working."].exists)

        tap("course-page-ask-ai", in: app)
        XCTAssertTrue(app.staticTexts[reply].waitForExistence(timeout: 15),
                      "Reopening the page chat keeps the learner's real answer and tutor history")
        XCTAssertTrue(app.staticTexts["Ion pumps need ATP."].exists)
        XCTAssertTrue(app.staticTexts[question].exists)
        assertNoAssessmentControlTurn(in: app)
        capture("Assessment discussion reopens from the page chat button", app)
    }

    @MainActor
    func testDelayedReviewStartsTutorFollowUpInAlreadyOpenPageChat() {
        let app = launchFixture(reviewDelaySeconds: 15)
        openFirstPage(in: app)
        tap("course-assessment-start-energy-explain", in: app)
        let answer = element("course-assessment-answer-energy-explain", in: app)
        reveal(answer, in: app)
        answer.tap()
        answer.typeText("DNA makes oxygen")
        dismissAssessmentKeyboard(in: app)
        tap("course-assessment-submit-energy-explain", in: app)
        XCTAssertTrue(element("course-assessment-reviewing-energy-explain", in: app)
            .waitForExistence(timeout: 5), "Open the page chat while this answer is still being reviewed")

        tap("course-page-ask-ai", in: app)
        let context = element("course-page-chat-context", in: app)
        XCTAssertTrue(context.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(context.staticTexts["Molecular machinery and cellular energetics"].exists)
        let question = "What do ion pumps need to keep working?"
        XCTAssertFalse(app.staticTexts[question].exists, "The chat opens before the delayed review completes")
        capture("Page chat opened while exercise review is pending", app)

        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 25),
                      "The completed review must start its tutor question in the already open chat")
        XCTAssertTrue(context.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", question)).count, 1)
        XCTAssertFalse(app.staticTexts["DNA makes oxygen"].exists)
        XCTAssertFalse(app.staticTexts["What happens to ATP when oxygen delivery stops?"].exists)
        assertNoAssessmentControlTurn(in: app)
        capture("Delayed review hands its question into the open page chat", app)

        sendChatAnswer("Ion pumps need ATP.", in: app)
        XCTAssertTrue(app.staticTexts["Yes. ATP provides the energy that keeps ion pumps working."]
            .waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Ion pumps need ATP."].exists)
        assertNoAssessmentControlTurn(in: app)
        app.navigationBars.buttons["Done"].tap()
        let feedback = element("course-assessment-feedback-energy-explain", in: app)
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Worth another look"].exists)
        XCTAssertTrue(app.staticTexts["DNA stores information; ion pumps need ATP to keep working."].exists)
        XCTAssertEqual(answer.value as? String, "DNA makes oxygen",
                       "The handoff remains linked to the submitted exercise answer")
        capture("Delayed follow-up remains linked to its exercise attempt", app)
    }

    @MainActor
    func testGuidedDiscussionStartsWithOneTutorQuestionAndContinuesExistingChat() {
        let app = launchFixture()
        openFirstPage(in: app)
        tap("course-page-ask-ai", in: app)
        XCTAssertTrue(element("course-page-chat-context", in: app).waitForExistence(timeout: 15))
        let learnerMessagesBeforeDiscussion = learnerBubbles(in: app).count
        app.navigationBars.buttons["Done"].tap()
        tap("course-assessment-discuss-energy-discussion", in: app)
        let question = "What happens to ATP when oxygen delivery stops?"
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(element("course-page-chat-context", in: app).exists)
        assertNoAssessmentControlTurn(in: app)
        XCTAssertEqual(learnerBubbles(in: app).count, learnerMessagesBeforeDiscussion,
                       "The tutor's opening preserves existing learner history without adding a learner turn")
        XCTAssertEqual(learnerBubbles(in: app).matching(NSPredicate(
            format: "label CONTAINS %@", "Discuss how oxygen loss affects a cell's energy supply."
        )).count, 0,
                       "Starting discussion does not manufacture a learner question")
        capture("Guided exercise asks the first question", app)

        app.navigationBars.buttons["Done"].tap()
        let discuss = element("course-assessment-discuss-energy-discussion", in: app)
        reveal(discuss, in: app)
        XCTAssertEqual(discuss.label, "Continue discussion")
        discuss.tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", question)).count, 1,
                       "Continuing the discussion reuses its existing opening question")
        assertNoAssessmentControlTurn(in: app)
        capture("Guided exercise continues its existing page discussion", app)
    }

    @MainActor
    func testQuizDraftIsPageScopedAndMalformedCheckDoesNotExposeDataOrGateNext() {
        let app = launchFixture()
        openFirstPage(in: app)
        tap("course-assessment-start-oxygen-check", in: app)
        tap("course-assessment-option-oxygen-check-b", in: app)
        app.terminate()
        app.launch()
        resumeCourse(in: app, expectedPageID: "article-one")
        assertAssessmentsCollapsed(in: app)
        let selected = app.buttons["course-assessment-option-oxygen-check-b"]
        reveal(selected, in: app)
        XCTAssertTrue(selected.isSelected, "The selected quiz option survives relaunch")
        XCTAssertFalse(element("course-assessment-feedback-oxygen-check", in: app).exists)
        capture("Quiz draft restored without revealing the answer", app)

        tap("course-next-lesson", in: app)
        XCTAssertTrue(element("course-page-title-article-two", in: app).waitForExistence(timeout: 20))
        assertAssessmentsCollapsed(in: app)
        let secondCheck = app.buttons["course-assessment-start-gradient-check"]
        reveal(secondCheck, in: app)
        XCTAssertFalse(element("course-assessment-oxygen-check", in: app).exists,
                       "The second lesson has its own checks and attempts")
        assertNoRawAssessmentData(in: app)
        secondCheck.tap()
        tap("course-assessment-option-gradient-check-c", in: app)
        tap("course-assessment-submit-gradient-check", in: app)
        let feedback = element("course-assessment-feedback-gradient-check", in: app)
        XCTAssertTrue(feedback.waitForExistence(timeout: 15))
        reveal(feedback, in: app)
        XCTAssertTrue(app.staticTexts["Well understood"].exists)
        let unavailable = element("course-assessment-unavailable", in: app)
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.exists)
        assertNoRawAssessmentData(in: app)
        capture("Malformed exercise stays hidden beside a working native check", app)
        let next = element("course-next-lesson", in: app)
        reveal(next, in: app)
        XCTAssertTrue(next.isEnabled, "A malformed exercise does not block continuing the course")
    }

    @MainActor
    private func launchFixture(reviewDelaySeconds: Int = 0) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LEARNFOLD_UI_TESTING"] = "1"
        app.launchEnvironment["SNAPPY_SKIP_AGENT_SETUP"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_TOKEN"] = UUID().uuidString
        app.launchEnvironment["LEARNFOLD_READING_TEST_ASSESSMENTS"] = "1"
        app.launchEnvironment["LEARNFOLD_READING_TEST_REVIEW_DELAY_SECONDS"] = String(reviewDelaySeconds)
        app.launchArguments = ["--ui-test-course-reading"]
        app.launch()
        return app
    }

    @MainActor
    private func openFirstPage(in app: XCUIApplication) {
        resumeCourse(in: app, expectedPageID: "article-one")
    }

    @MainActor
    private func resumeCourse(in app: XCUIApplication, expectedPageID: String) {
        let start = app.buttons["course-continue"]
        XCTAssertTrue(start.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(waitForHittable(start))
        start.tap()
        XCTAssertTrue(element("course-page-title-\(expectedPageID)", in: app)
            .waitForExistence(timeout: 20), app.debugDescription)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication,
                        expandsAssessments: Bool = true, scrollDownFirst: Bool = false) {
        if expandsAssessments {
            setAssessmentsExpanded(true, in: app)
        }
        for index in 0..<12 {
            let frame = target.exists ? target.frame : .null
            if hasFiniteArea(frame), frame.midY > app.frame.minY + 150,
               frame.midY < app.frame.maxY - 130, target.isHittable { return }
            if hasFiniteArea(frame) {
                scrollReader(down: frame.midY < app.frame.minY + 150, in: app)
            } else if scrollDownFirst != (index >= 6) {
                scrollReader(down: true, in: app)
            } else {
                scrollReader(down: false, in: app)
            }
        }
        XCTFail("Could not reveal the requested element within the reading viewport.\n\(app.debugDescription)")
    }

    @MainActor
    private func scrollReader(down: Bool, in app: XCUIApplication) {
        let reader = app.scrollViews.firstMatch
        XCTAssertTrue(reader.exists, app.debugDescription)
        XCTAssertTrue(hasFiniteArea(reader.frame), app.debugDescription)
        if down { reader.swipeDown() }
        else { reader.swipeUp() }
    }

    @MainActor
    private func assertAssessmentsCollapsed(in app: XCUIApplication) {
        let toggle = app.buttons["course-assessment-section-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(element("course-assessment-section-content", in: app).exists)
        for id in ["oxygen-check", "energy-explain", "energy-discussion", "gradient-check"] {
            XCTAssertFalse(element("course-assessment-\(id)", in: app).exists,
                           "Optional question cards stay hidden until the exercise section is expanded")
        }
    }

    @MainActor
    private func setAssessmentsExpanded(_ expanded: Bool, in app: XCUIApplication) {
        let toggle = app.buttons["course-assessment-section-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        let expectedValue = expanded ? "Expanded" : "Collapsed"
        guard toggle.value as? String != expectedValue else { return }
        reveal(toggle, in: app, expandsAssessments: false,
               scrollDownFirst: toggle.value as? String == "Expanded")
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue), object: toggle
        )], timeout: 5), .completed, app.debugDescription)
    }

    @MainActor
    private func dismissAssessmentKeyboard(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let done = app.buttons["course-assessment-answer-done-energy-explain"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(hasFiniteArea(done.frame), app.debugDescription)
        XCTAssertTrue(done.isHittable, app.debugDescription)
        done.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: keyboard
        )], timeout: 5), .completed, app.debugDescription)
    }

    private func hasFiniteArea(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.width > 0 && frame.height > 0
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = app.buttons[identifier]
        if identifier == "course-page-ask-ai" {
            XCTAssertTrue(waitForHittable(target))
        } else {
            reveal(target, in: app, expandsAssessments: identifier.hasPrefix("course-assessment-"))
        }
        XCTAssertTrue(target.isEnabled, app.debugDescription)
        target.tap()
    }

    @MainActor
    private func sendChatAnswer(_ text: String, in app: XCUIApplication) {
        let composer = element("course-chat-composer", in: app)
        XCTAssertTrue(waitForHittable(composer))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        composer.typeText(text)
        let send = app.buttons["course-chat-send"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
            object: send
        )], timeout: 15), .completed, app.debugDescription)
        send.tap()
    }

    @MainActor
    private func learnerBubbles(in app: XCUIApplication) -> XCUIElementQuery {
        element("chat-screen", in: app).descendants(matching: .any)
            .matching(identifier: "chat-user-bubble")
    }

    @MainActor
    private func assertNoRawAssessmentData(in app: XCUIApplication) {
        for text in ["learnfold-assessment", "option_id", "MALFORMED-ANSWER-KEY-DO-NOT-SHOW"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", text, text
            )).count, 0, "Reserved exercise data must stay out of the reading UI")
        }
    }

    @MainActor
    private func assertNoAssessmentControlTurn(in app: XCUIApplication) {
        for text in ["learnfold_assessment_discussion", "LEARNING_DATA", "Begin a teaching discussion"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", text, text
            )).count, 0, "An assistant-first exercise uses a hidden control turn")
        }
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )], timeout: 15) == .completed
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
