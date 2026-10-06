import XCTest
@testable import Litter

final class ContinuedTurnPresentationTests: XCTestCase {
    private typealias Formatter = ContinuedTurnBannerFormatter

    private let lesson = ContinuedTurnContext(
        agentName: "Codex",
        intent: .writeLesson(title: "Light Reactions", pageID: "page-light"),
        pageTitlesByID: [
            "page-light": "Light Reactions",
            "page-chlorophyll": "Chlorophyll basics",
        ]
    )
    private let exploration = ContinuedTurnContext(
        agentName: "Codex",
        intent: .exploreTopic(title: "Why leaves look green", pageID: "page-green"),
        pageTitlesByID: ["page-chlorophyll": "Chlorophyll basics"]
    )
    private let question = ContinuedTurnContext(
        agentName: "Codex",
        intent: .answerQuestion(pageTitle: "Chlorophyll basics")
    )
    private let courseChat = ContinuedTurnContext(
        agentName: "Codex",
        intent: .courseChat(courseTitle: "Photosynthesis")
    )
    private let generic = ContinuedTurnContext(
        agentName: "Codex",
        intent: .generic(title: "Fix flaky login test")
    )

    // MARK: - Before/after rows

    func testExplorationWorkerFetchNamesTopicAndPage() {
        let banner = running(
            exploration,
            activity(.readingCourse, pageId: "page-chlorophyll")
        )
        XCTAssertEqual(banner.title, "Exploring “Why leaves look green”")
        XCTAssertEqual(banner.subtitle, "Reading “Chlorophyll basics”")
    }

    func testSecondExplorationWorkerSearchIsDistinguishable() {
        let context = ContinuedTurnContext(
            agentName: "Codex",
            intent: .exploreTopic(title: "Light vs. dark reactions", pageID: nil)
        )
        let banner = running(context, activity(.searchingCourse, subject: "Calvin cycle"))
        XCTAssertEqual(banner.title, "Exploring “Light vs. dark reacti…”")
        XCTAssertEqual(banner.subtitle, "Searching for “Calvin cycle”")
    }

    func testSubmittedBannerIsGettingStarted() {
        XCTAssertEqual(
            Formatter.submitted(exploration),
            ContinuedTurnBanner(title: "Exploring “Why leaves look green”", subtitle: "Getting started")
        )
    }

    func testLessonFetchOfTargetReadsTheCurrentDraft() {
        let banner = running(lesson, activity(.readingCourse, pageId: "page-light"))
        XCTAssertEqual(banner.title, "Writing “Light Reactions”")
        XCTAssertEqual(banner.subtitle, "Reading the current draft")
    }

    func testLessonThinkingAfterReadsCountsPages() {
        let banner = running(lesson, activity(.thinking, isRunning: false, read: 4))
        XCTAssertEqual(banner.subtitle, "Thinking · read 4 pages")
        XCTAssertEqual(
            running(lesson, activity(.thinking, isRunning: false, read: 1)).subtitle,
            "Thinking · read 1 page"
        )
        XCTAssertEqual(
            running(lesson, activity(.thinking, isRunning: false)).subtitle,
            "Thinking it through"
        )
    }

    func testLessonWriteOfTargetSavesTheLesson() {
        XCTAssertEqual(
            running(lesson, activity(.writingCoursePage, pageId: "page-light")).subtitle,
            "Saving the lesson"
        )
    }

    func testLessonVerifyOfTargetChecksTheSavedLesson() {
        XCTAssertEqual(
            running(lesson, activity(.verifyingCoursePage, pageId: "page-light", written: 1)).subtitle,
            "Checking the saved lesson"
        )
    }

    func testSelectionDiscussionSearchShowsQuery() {
        let banner = running(question, activity(.searchingCourse, subject: "absorption spectrum"))
        XCTAssertEqual(banner.title, "Answering about “Chlorophyll bas…”")
        XCTAssertEqual(banner.subtitle, "Searching for “absorption spectrum”")
    }

    func testGenericShellCommandIsShortened() {
        let banner = running(
            generic,
            activity(.runningCommand, subject: "cargo test -p codex-mobile-client --lib turn_activity")
        )
        XCTAssertEqual(banner.title, "Fix flaky login test")
        XCTAssertEqual(banner.subtitle, "Running cargo test -p codex-mobile-client -…")
        XCTAssertEqual(banner.subtitle.count, Formatter.subtitleLimit)
    }

    func testGenericFileSearchShowsQuery() {
        XCTAssertEqual(
            running(generic, activity(.searchingFiles, subject: "refreshToken")).subtitle,
            "Searching files for “refreshToken”"
        )
    }

    func testGenericFileEditCountsOtherFiles() {
        XCTAssertEqual(
            running(generic, activity(.editingFiles, subject: "AppModel.swift", unitCount: 3)).subtitle,
            "Editing AppModel.swift +2 more"
        )
        XCTAssertEqual(
            running(generic, activity(.editingFiles, subject: "AppModel.swift", unitCount: 1)).subtitle,
            "Editing AppModel.swift"
        )
    }

    func testPlanShowsStepCounterAndStepText() {
        let banner = running(
            generic,
            activity(.runningCommand, subject: "xcodebuild test"),
            plan: plan([.completed, .inProgress, .pending, .pending])
        )
        XCTAssertEqual(banner.subtitle, "Step 2 of 4 · Add retry to token refresh")
    }

    func testPlanWithoutInProgressStepUsesNextStep() {
        XCTAssertEqual(
            running(generic, nil, plan: plan([.completed, .completed, .pending])).subtitle,
            "Step 3 of 3 · Run the login suite"
        )
        XCTAssertEqual(
            running(generic, nil, plan: plan([.completed, .completed, .completed])).subtitle,
            "Step 3 of 3 · Run the login suite"
        )
    }

    func testThirdPartyToolUsesServerAndToolWords() {
        XCTAssertEqual(
            running(generic, activity(.usingTool, subject: "Linear · create issue")).subtitle,
            "Using Linear · create issue"
        )
    }

    func testGenericReasoningShowsHeadline() {
        XCTAssertEqual(
            running(generic, activity(.thinking, subject: "Tracing the token refresh path", isRunning: false)).subtitle,
            "Tracing the token refresh path"
        )
        XCTAssertEqual(
            running(generic, activity(.thinking, isRunning: false)).subtitle,
            "Codex is thinking"
        )
    }

    func testApprovalPendingNeedsTheLearner() {
        let banner = running(generic, activity(.runningCommand, subject: "rm -rf build"), needsApproval: true)
        XCTAssertEqual(banner.subtitle, "Needs your approval")
    }

    func testCompletedTurnDoesNotVerifyLessonReadiness() {
        let result = Formatter.finished(
            context: lesson,
            activity: activity(.responding, isRunning: false, written: 1),
            outcome: .completed
        )
        XCTAssertEqual(
            result.banner,
            ContinuedTurnBanner(title: "Codex finished", subtitle: "Open Learnfold to check “Light Reactions”")
        )
        XCTAssertTrue(result.success)
    }

    func testFailedLessonCouldNotFinish() {
        let result = Formatter.finished(
            context: lesson,
            activity: nil,
            outcome: .failed(message: "model overloaded")
        )
        XCTAssertEqual(
            result.banner,
            ContinuedTurnBanner(title: "Couldn’t finish “Light Reactions”", subtitle: "Open Learnfold to try again")
        )
        XCTAssertFalse(result.success)
    }

    // MARK: - Truncation

    func testFitShortensOnlyTheQuotedSubject() {
        XCTAssertEqual(
            Formatter.fit(prefix: "Writing ", quoted: "Ownership & Borrowing in Depth", suffix: "", limit: 34),
            "Writing “Ownership & Borrowing i…”"
        )
        XCTAssertEqual(
            Formatter.fit(prefix: "Updating ", quoted: "A very long chapter title indeed", suffix: " details", limit: 30),
            "Updating “A very lon…” details"
        )
        XCTAssertEqual(
            Formatter.fit(prefix: "Reading ", quoted: "Short", suffix: "", limit: 44),
            "Reading “Short”"
        )
        XCTAssertEqual(
            Formatter.fit(prefix: "Running ", quoted: nil, suffix: "a very long command line here", limit: 20),
            "Running a very long…"
        )
    }

    func testLongTitleKeepsVerbAndBothQuotes() {
        let context = ContinuedTurnContext(
            agentName: "Codex",
            intent: .writeLesson(title: "Ownership & Borrowing in Depth", pageID: nil)
        )
        let title = Formatter.submitted(context).title
        XCTAssertEqual(title, "Writing “Ownership & Borrowing i…”")
        XCTAssertEqual(title.count, Formatter.titleLimit)
    }

    func testStepCounterSurvivesLongStepText() {
        let steps = [
            AppPlanStep(step: "Reproduce", status: .completed),
            AppPlanStep(
                step: "Add exponential backoff and jitter to the token refresh retry loop",
                status: .inProgress
            ),
            AppPlanStep(step: "Ship", status: .pending),
            AppPlanStep(step: "Verify", status: .pending),
        ]
        let subtitle = running(
            generic,
            nil,
            plan: AppPlanProgressSnapshot(turnId: "turn", explanation: nil, plan: steps)
        ).subtitle
        XCTAssertEqual(subtitle, "Step 2 of 4 · Add exponential backoff and j…")
        XCTAssertEqual(subtitle.count, Formatter.subtitleLimit)
    }

    func testTruncationCountsGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let emojiTitle = Formatter.submitted(ContinuedTurnContext(
            agentName: "Codex",
            intent: .writeLesson(title: String(repeating: family, count: 40), pageID: nil)
        )).title
        XCTAssertEqual(emojiTitle, "Writing “" + String(repeating: family, count: 23) + "…”")
        XCTAssertEqual(emojiTitle.count, Formatter.titleLimit)

        let cjkTitle = Formatter.submitted(ContinuedTurnContext(
            agentName: "Codex",
            intent: .writeLesson(title: "光合作用の明反応と暗反応についての詳しい解説とその応用と実験", pageID: nil)
        )).title
        XCTAssertEqual(cjkTitle, "Writing “光合作用の明反応と暗反応についての詳しい解説と…”")
        XCTAssertEqual(cjkTitle.count, Formatter.titleLimit)
    }

    // MARK: - Precedence

    func testSubtitlePrecedenceIsNeedsYouThenPlanThenActivity() {
        let reading = activity(.readingCourse, subject: "Chlorophyll basics")
        let steps = plan([.inProgress, .pending, .pending, .pending])
        XCTAssertEqual(
            running(lesson, reading, plan: steps, needsApproval: true, needsInput: true).subtitle,
            "Needs your approval"
        )
        XCTAssertEqual(
            running(lesson, reading, plan: steps, needsInput: true).subtitle,
            "Waiting for your answer"
        )
        XCTAssertEqual(
            running(lesson, reading, plan: steps).subtitle,
            "Step 1 of 4 · Reproduce the flake"
        )
        XCTAssertEqual(running(lesson, reading).subtitle, "Reading “Chlorophyll basics”")
        XCTAssertEqual(running(lesson, nil).subtitle, "Codex is working")
        XCTAssertEqual(
            running(lesson, nil, plan: AppPlanProgressSnapshot(turnId: "t", explanation: nil, plan: [])).subtitle,
            "Codex is working"
        )
    }

    // MARK: - Target page wording

    func testTargetPageWordingDependsOnContextPage() {
        XCTAssertEqual(
            running(lesson, activity(.readingCourse, pageId: "page-chlorophyll")).subtitle,
            "Reading “Chlorophyll basics”"
        )
        XCTAssertEqual(
            running(lesson, activity(.readingCourse, pageId: "page-unknown", stepCount: 3)).subtitle,
            "Reading course pages (3)"
        )
        XCTAssertEqual(
            running(lesson, activity(.readingCourse, pageId: "page-unknown")).subtitle,
            "Reading a course page"
        )
        XCTAssertEqual(
            running(lesson, activity(.verifyingCoursePage, pageId: "page-chlorophyll")).subtitle,
            "Checking “Chlorophyll basics”"
        )
        XCTAssertEqual(
            running(lesson, activity(.writingCoursePage, pageId: "page-chlorophyll")).subtitle,
            "Saving “Chlorophyll basics”"
        )
        XCTAssertEqual(
            running(lesson, activity(.writingCoursePage)).subtitle,
            "Saving the lesson"
        )
        XCTAssertEqual(
            running(question, activity(.writingCoursePage)).subtitle,
            "Saving a course page"
        )
        XCTAssertEqual(
            running(courseChat, activity(.readingCourse, pageId: "page-light")).subtitle,
            "Reading a course page"
        )
    }

    func testRustSubjectWinsOverPageTitleLookup() {
        XCTAssertEqual(
            running(lesson, activity(.updatingCourseDetails, subject: "Unit 2", pageId: "page-chlorophyll")).subtitle,
            "Updating “Unit 2” details"
        )
        XCTAssertEqual(
            running(lesson, activity(.updatingCourseDetails)).subtitle,
            "Updating page details"
        )
    }

    func testCourseOnlyPhrases() {
        XCTAssertEqual(running(lesson, activity(.readingCourseOutline)).subtitle, "Reading the course outline")
        XCTAssertEqual(running(lesson, activity(.searchingCourse)).subtitle, "Searching the course")
        XCTAssertEqual(running(lesson, activity(.addingCoursePages, unitCount: 3)).subtitle, "Adding 3 pages")
        XCTAssertEqual(
            running(lesson, activity(.addingCoursePages, subject: "Dark reactions", unitCount: 1)).subtitle,
            "Adding “Dark reactions”"
        )
        XCTAssertEqual(running(lesson, activity(.addingCoursePages)).subtitle, "Adding a page")
        XCTAssertEqual(running(lesson, activity(.organizingCourse)).subtitle, "Reorganizing pages")
        XCTAssertEqual(running(lesson, activity(.savingCourseChanges)).subtitle, "Finishing a large save")
        XCTAssertEqual(running(courseChat, activity(.planningCourse)).subtitle, "Preparing your course plan")
        XCTAssertEqual(running(lesson, activity(.checkingCourseFiles)).subtitle, "Checking your source files")
        XCTAssertEqual(running(lesson, activity(.starting)).subtitle, "Getting started")
    }

    func testRespondingAndWrappingUp() {
        XCTAssertEqual(running(question, activity(.responding)).subtitle, "Writing your answer")
        XCTAssertEqual(running(courseChat, activity(.responding)).subtitle, "Writing a reply")
        XCTAssertEqual(running(lesson, activity(.responding, written: 1)).subtitle, "Wrapping up")
        XCTAssertEqual(running(exploration, activity(.thinking, read: 3, written: 1)).subtitle, "Wrapping up")
        XCTAssertEqual(running(courseChat, activity(.thinking, read: 3, written: 1)).subtitle, "Thinking · read 3 pages")
    }

    func testCourseTurnsHideCommandsFilesAndReasoning() {
        XCTAssertEqual(
            running(lesson, activity(.runningCommand, subject: "cat secrets.txt")).subtitle,
            "Running a command"
        )
        XCTAssertEqual(
            running(lesson, activity(.thinking, subject: "Considering the learner’s gaps")).subtitle,
            "Thinking it through"
        )
        XCTAssertEqual(
            running(lesson, activity(.editingFiles, subject: "notes.md", unitCount: 3)).subtitle,
            "Editing 3 files"
        )
        XCTAssertEqual(
            running(lesson, activity(.readingFiles, subject: "notes.md", stepCount: 2)).subtitle,
            "Reading 2 files"
        )
        XCTAssertEqual(
            running(lesson, activity(.searchingFiles, subject: "password")).subtitle,
            "Searching files"
        )
    }

    func testGenericOnlyPhrases() {
        XCTAssertEqual(running(generic, activity(.readingFiles, subject: "AppModel.swift")).subtitle, "Reading AppModel.swift")
        XCTAssertEqual(running(generic, activity(.readingFiles, unitCount: 4)).subtitle, "Reading 4 files")
        XCTAssertEqual(running(generic, activity(.editingFiles, unitCount: 2)).subtitle, "Editing 2 files")
        XCTAssertEqual(
            running(generic, activity(.searchingWeb, subject: "BGContinuedProcessingTask")).subtitle,
            "Searching the web for “BGContinuedProcessi…”"
        )
        XCTAssertEqual(running(generic, activity(.delegating, unitCount: 3)).subtitle, "Working with 3 helpers")
        XCTAssertEqual(running(generic, activity(.delegating, unitCount: 1)).subtitle, "Working with a helper")
        XCTAssertEqual(running(generic, activity(.generatingImage)).subtitle, "Generating an image")
        XCTAssertEqual(running(generic, activity(.usingTool)).subtitle, "Using a tool")
    }

    func testPhraseWithoutContextKeepsGenericDetails() {
        XCTAssertEqual(
            Formatter.activityPhrase(activity(.runningCommand, subject: "cargo test"), context: nil, limit: 48),
            "Running cargo test"
        )
        XCTAssertEqual(
            Formatter.activityPhrase(activity(.thinking, isRunning: false), context: nil, limit: 48),
            "Thinking"
        )
        XCTAssertEqual(
            Formatter.activityPhrase(activity(.readingCourse, pageId: "page-light"), context: nil, limit: 48),
            "Reading a course page"
        )
    }

    // MARK: - Finished copy

    func testFinishedCopyForEachIntentAndOutcome() {
        func finished(
            _ context: ContinuedTurnContext,
            written: UInt32 = 0,
            _ outcome: TurnOutcome?
        ) -> (ContinuedTurnBanner, Bool) {
            let result = Formatter.finished(
                context: context,
                activity: activity(.responding, isRunning: false, written: written),
                outcome: outcome
            )
            return (result.banner, result.success)
        }

        XCTAssertTrue(finished(lesson, .completed)
            == (ContinuedTurnBanner(title: "Codex finished", subtitle: "Open Learnfold to check “Light Reactions”"), true))
        XCTAssertTrue(finished(exploration, written: 1, .completed)
            == (ContinuedTurnBanner(title: "Codex finished", subtitle: "Open Learnfold to check “Why leaves look g…”"), true))
        XCTAssertTrue(finished(question, .completed)
            == (ContinuedTurnBanner(title: "Your answer is ready", subtitle: "About “Chlorophyll basics”"), true))
        XCTAssertTrue(finished(courseChat, .completed)
            == (ContinuedTurnBanner(title: "Codex replied", subtitle: "Photosynthesis"), true))
        XCTAssertTrue(finished(generic, .completed)
            == (ContinuedTurnBanner(title: "Codex finished", subtitle: "Fix flaky login test"), true))
        XCTAssertTrue(finished(lesson, written: 1, nil)
            == (ContinuedTurnBanner(title: "Status unconfirmed", subtitle: "Open Learnfold to check the result"), false))
        XCTAssertTrue(finished(lesson, .interrupted)
            == (ContinuedTurnBanner(title: "Stopped “Light Reactions”", subtitle: "Pick it up again in Learnfold"), false))
        XCTAssertTrue(finished(question, .failed(message: "boom"))
            == (ContinuedTurnBanner(title: "Couldn’t finish your answer", subtitle: "Open Learnfold to try again"), false))
        XCTAssertTrue(finished(question, .interrupted)
            == (ContinuedTurnBanner(title: "Stopped answering", subtitle: "Pick it up again in Learnfold"), false))
        XCTAssertTrue(finished(generic, .failed(message: "boom"))
            == (ContinuedTurnBanner(title: "Couldn’t finish “Fix flaky login…”", subtitle: "Open Learnfold to try again"), false))
        XCTAssertTrue(finished(ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: nil)), .completed)
            == (ContinuedTurnBanner(title: "Hermes finished", subtitle: "Your task is ready"), true))
        XCTAssertTrue(finished(ContinuedTurnContext(agentName: "Codex", intent: .writeLesson(title: nil, pageID: nil)), written: 1, .completed)
            == (ContinuedTurnBanner(title: "Codex finished", subtitle: "Open Learnfold to check the lesson"), true))
    }

    func testUnrelatedPageWriteCannotAnnounceTheTargetLessonReady() {
        let result = Formatter.finished(
            context: lesson,
            activity: activity(.writingCoursePage, pageId: "page-notes", isRunning: false, written: 1),
            outcome: .completed
        )
        XCTAssertEqual(result.banner.title, "Codex finished")
        XCTAssertEqual(result.banner.subtitle, "Open Learnfold to check “Light Reactions”")
        XCTAssertTrue(result.success, "The turn completed, but its target lesson is not verified.")
    }

    func testMissingOutcomeDoesNotAnnounceAnAnswerReady() {
        let result = Formatter.finished(context: question, activity: nil, outcome: nil)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.banner.title, "Status unconfirmed")
        XCTAssertEqual(result.banner.subtitle, "Open Learnfold to check the result")
    }

    // MARK: - Titles

    func testTitlesForEachIntent() {
        XCTAssertEqual(Formatter.submitted(question).title, "Answering about “Chlorophyll bas…”")
        XCTAssertEqual(Formatter.submitted(courseChat).title, "Working on “Photosynthesis”")
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(agentName: "Codex", intent: .writeLesson(title: nil, pageID: nil))).title,
            "Writing a lesson"
        )
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(agentName: "Codex", intent: .answerQuestion(pageTitle: nil))).title,
            "Answering your question"
        )
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(agentName: "Codex", intent: .courseChat(courseTitle: "  "))).title,
            "Working on your course"
        )
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(agentName: "Hermes", intent: .generic(title: nil))).title,
            "Hermes is working"
        )
    }

    func testGenericTitlePrefersThreadTitleThenFirstTypedLine() {
        XCTAssertEqual(
            ContinuedTurnContext.genericTitle(threadTitle: " Fix flaky login test ", typedText: "Ignored"),
            "Fix flaky login test"
        )
        XCTAssertEqual(
            ContinuedTurnContext.genericTitle(threadTitle: nil, typedText: "\n  Why does login   fail?\nMore detail"),
            "Why does login fail?"
        )
        XCTAssertNil(ContinuedTurnContext.genericTitle(threadTitle: "  ", typedText: " \n "))
    }

    func testSwiftTitlesKeepTheLearnersOwnWords() {
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(
                agentName: "Codex",
                intent: .writeLesson(title: "<div> and <span>", pageID: nil)
            )).title,
            "Writing “<div> and <span>”"
        )
        let flexbox = ContinuedTurnContext(
            agentName: "Codex",
            intent: .writeLesson(title: "[Optional] Flexbox", pageID: "page-flex"),
            pageTitlesByID: ["page-grid": "[Optional] Grid"]
        )
        XCTAssertEqual(Formatter.submitted(flexbox).title, "Writing “[Optional] Flexbox”")
        XCTAssertEqual(
            running(flexbox, activity(.readingCourse, pageId: "page-grid")).subtitle,
            "Reading “[Optional] Grid”"
        )
        XCTAssertEqual(
            Formatter.submitted(ContinuedTurnContext(
                agentName: "Codex",
                intent: .generic(title: "MCP server won't connect")
            )).title,
            "MCP server won't connect"
        )
    }

    func testGenericTitleReadsOnlyTheFirstTypedLine() {
        XCTAssertEqual(
            ContinuedTurnContext.genericTitle(
                threadTitle: nil,
                typedText: "[WIP] login fails\n    at LoginView.swift:42"
            ),
            "[WIP] login fails"
        )
        XCTAssertNil(ContinuedTurnContext.genericTitle(
            threadTitle: nil,
            typedText: "<learnfold_internal_course_instruction version=\"1\">\nWrite the lesson"
        ))
        XCTAssertNil(ContinuedTurnContext.genericTitle(
            threadTitle: nil,
            typedText: "{\n  \"page_id\": \"abc\"\n}"
        ))
        XCTAssertEqual(
            ContinuedTurnContext.genericTitle(
                threadTitle: "<learnfold_internal_course_instruction ve",
                typedText: "Why does login fail?"
            ),
            "Why does login fail?"
        )
    }

    // MARK: - Course plan steps

    func testCoursePlanStepsHideIDsAndInternalNames() {
        let page = "4f6c2b1a-0d3e-4c7a-9b52-8e1f0a6d3c21"
        func steps(_ texts: [String], current: Int) -> AppPlanProgressSnapshot {
            AppPlanProgressSnapshot(
                turnId: "turn",
                explanation: nil,
                plan: texts.enumerated().map { index, text in
                    AppPlanStep(
                        step: text,
                        status: index < current ? .completed : index == current ? .inProgress : .pending
                    )
                }
            )
        }
        let texts = [
            "Fetch target page \(page)",
            "Draft the lesson sections",
            "Save it with update-page",
            "Verify generation_status=generated via MCP fetch",
        ]
        let reading = activity(.readingCourse, pageId: "page-light")
        XCTAssertEqual(
            running(lesson, reading, plan: steps(texts, current: 0)).subtitle,
            "Step 1 of 4 · Reading the current draft"
        )
        XCTAssertEqual(
            running(lesson, reading, plan: steps(texts, current: 1)).subtitle,
            "Step 2 of 4 · Draft the lesson sections"
        )
        XCTAssertEqual(
            running(lesson, activity(.writingCoursePage, pageId: "page-light"), plan: steps(texts, current: 2)).subtitle,
            "Step 3 of 4 · Saving the lesson"
        )
        XCTAssertEqual(
            running(lesson, nil, plan: steps(texts, current: 3)).subtitle,
            "Step 4 of 4"
        )
        XCTAssertEqual(
            running(exploration, nil, plan: steps(["Check the outline with MCP"], current: 0)).subtitle,
            "Step 1 of 1"
        )
        // Generic chats keep the model's own step text.
        XCTAssertEqual(
            running(generic, nil, plan: steps(["Rename user_id to account_id"], current: 0)).subtitle,
            "Step 1 of 1 · Rename user_id to account_id"
        )
    }

    // MARK: - Exploration topics

    func testExplorationBannersNameThePassageOrQuestion() {
        func request(question: String?, passage: String?) -> CourseExplorationRequest {
            CourseExplorationRequest(
                parentPageID: "page-light",
                parentTitle: "Light Reactions",
                direction: .question,
                question: question,
                quotedPassage: passage
            )
        }
        func title(_ request: CourseExplorationRequest) -> String {
            Formatter.submitted(ContinuedTurnContext(
                agentName: "Codex",
                intent: .exploreTopic(title: request.bannerTopic, pageID: nil)
            )).title
        }
        let why = CourseExplorePassageIntent.why.question
        let chlorophyll = request(question: why, passage: "Chlorophyll absorbs red and blue light")
        let calvin = request(question: why, passage: "The Calvin cycle fixes carbon")
        XCTAssertEqual(chlorophyll.bannerTopic, "Chlorophyll absorbs red and blue light")
        XCTAssertNotEqual(title(chlorophyll), title(calvin))
        for banner in [title(chlorophyll), title(calvin)] {
            XCTAssertTrue(banner.hasPrefix("Exploring “"), banner)
            XCTAssertTrue(banner.hasSuffix("”"), banner)
            XCTAssertFalse(banner.contains(why), banner)
            XCTAssertEqual(banner.filter { $0 == "“" }.count, 1, banner)
        }

        let passageOnly = request(question: nil, passage: "Chlorophyll")
        XCTAssertEqual(passageOnly.placeholderTitle, "Exploring “Chlorophyll”")
        XCTAssertEqual(title(passageOnly), "Exploring “Chlorophyll”")
        XCTAssertEqual(
            Formatter.finished(
                context: ContinuedTurnContext(
                    agentName: "Codex",
                    intent: .exploreTopic(title: passageOnly.bannerTopic, pageID: nil)
                ),
                activity: activity(.responding, isRunning: false, written: 1),
                outcome: .completed
            ).banner.title,
            "Codex finished"
        )

        let typed = request(question: "Does this explain autumn colours?", passage: "Chlorophyll")
        XCTAssertEqual(typed.bannerTopic, "Does this explain autumn colours?")
        XCTAssertEqual(request(question: nil, passage: nil).bannerTopic, "Light Reactions")
        XCTAssertEqual(
            request(question: nil, passage: "the “light” reactions").bannerTopic,
            "the ‘light’ reactions"
        )

        // After a relaunch only the placeholder title is left.
        XCTAssertEqual(
            CourseExplorationRequest.bannerTopic(forTitle: passageOnly.placeholderTitle),
            "Chlorophyll"
        )
        XCTAssertEqual(
            CourseExplorationRequest.bannerTopic(forTitle: chlorophyll.placeholderTitle),
            "Chlorophyll absorbs red and blue light"
        )
        XCTAssertEqual(
            CourseExplorationRequest.bannerTopic(forTitle: "Exploring Light Reactions"),
            "Light Reactions"
        )
        XCTAssertEqual(
            CourseExplorationRequest.bannerTopic(forTitle: "Why leaves look green"),
            "Why leaves look green"
        )
    }

    // MARK: - Wire names

    func testNoOutputContainsWireNames() {
        let wireSubjects: [String?] = [
            nil,
            "native-editor-fetch",
            "MCP native-editor-search",
            "mcp__learnfold_course__fetch",
            "learnfold_generate_lesson",
            "{\"id\":\"self\"}",
            "[\"page-1\"]",
            "<learnfold_internal_course_instruction version=\"1\">",
        ]
        let wirePageIDs: [String?] = [nil, "native-editor://page/abc", "page-light"]
        let contexts: [ContinuedTurnContext?] = [
            nil,
            lesson,
            exploration,
            question,
            courseChat,
            generic,
            ContinuedTurnContext(
                agentName: "Codex",
                intent: .generic(title: "<learnfold_internal_course_instruction ve")
            ),
            ContinuedTurnContext(
                agentName: "Codex",
                intent: .writeLesson(title: "{\"id\":\"self\"}", pageID: "page-light"),
                pageTitlesByID: ["native-editor://page/abc": "<learnfold_internal_course_instruction>"]
            ),
        ]
        let outcomes: [TurnOutcome?] = [nil, .completed, .interrupted, .failed(message: "native-editor failed")]

        var outputs: [String] = []
        for context in contexts {
            for kind in Self.allKinds {
                for subject in wireSubjects {
                    for pageID in wirePageIDs {
                        let current = activity(kind, subject: subject, pageId: pageID, unitCount: 2, stepCount: 2, read: 2, written: 1)
                        outputs.append(Formatter.activityPhrase(current, context: context, limit: 44))
                        guard let context else { continue }
                        let banner = running(context, current)
                        outputs += [banner.title, banner.subtitle]
                    }
                }
            }
            guard let context else { continue }
            let submitted = Formatter.submitted(context)
            outputs += [submitted.title, submitted.subtitle]
            for outcome in outcomes {
                let finished = Formatter.finished(context: context, activity: nil, outcome: outcome).banner
                outputs += [finished.title, finished.subtitle]
            }
            let planned = running(
                context,
                nil,
                plan: AppPlanProgressSnapshot(
                    turnId: "t",
                    explanation: nil,
                    plan: [AppPlanStep(step: "Call mcp__learnfold_course__fetch", status: .inProgress)]
                )
            )
            outputs += [planned.title, planned.subtitle]
        }

        XCTAssertFalse(outputs.isEmpty)
        for output in outputs {
            XCTAssertFalse(output.contains("native-editor"), output)
            XCTAssertFalse(output.contains("MCP "), output)
            XCTAssertFalse(output.contains("learnfold_"), output)
            XCTAssertFalse(output.contains("mcp__"), output)
            XCTAssertFalse(output.isEmpty)
        }
    }

    // MARK: - Helpers

    static let allKinds: [AppTurnActivityKind] = [
        .starting, .thinking, .responding, .readingCourse, .readingCourseOutline,
        .searchingCourse, .verifyingCoursePage, .writingCoursePage, .updatingCourseDetails,
        .addingCoursePages, .organizingCourse, .savingCourseChanges, .planningCourse,
        .checkingCourseFiles, .runningCommand, .readingFiles, .searchingFiles, .editingFiles,
        .searchingWeb, .usingTool, .delegating, .generatingImage,
    ]

    private func running(
        _ context: ContinuedTurnContext,
        _ activity: AppTurnActivity?,
        plan: AppPlanProgressSnapshot? = nil,
        needsApproval: Bool = false,
        needsInput: Bool = false
    ) -> ContinuedTurnBanner {
        Formatter.running(
            context: context,
            activity: activity,
            plan: plan,
            needsApproval: needsApproval,
            needsInput: needsInput
        )
    }

    private func plan(_ statuses: [AppPlanStepStatus]) -> AppPlanProgressSnapshot {
        let names = [
            "Reproduce the flake",
            "Add retry to token refresh",
            "Run the login suite",
            "Open a pull request",
        ]
        return AppPlanProgressSnapshot(
            turnId: "turn-1",
            explanation: nil,
            plan: statuses.enumerated().map { index, status in
                AppPlanStep(step: names[index], status: status)
            }
        )
    }

    private func activity(
        _ kind: AppTurnActivityKind,
        subject: String? = nil,
        pageId: String? = nil,
        isRunning: Bool = true,
        unitCount: UInt32 = 0,
        stepCount: UInt32 = 1,
        read: UInt32 = 0,
        written: UInt32 = 0
    ) -> AppTurnActivity {
        AppTurnActivity(
            kind: kind,
            subject: subject,
            pageId: pageId,
            isRunning: isRunning,
            unitCount: unitCount,
            stepCount: stepCount,
            coursePagesRead: read,
            coursePagesWritten: written
        )
    }
}
