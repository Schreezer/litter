import XCTest
@testable import Litter

final class CoursePlanMarkdownTests: XCTestCase {
    private let treasuryReply = """
    Here is a rigorous, calculation-heavy path.

    ```learnfold-plan
    # Treasury Market Analysis
    **Summary:** Analyst-level Treasury valuation, rate risk, and curve analysis.
    Outcome: Price Treasuries, measure duration and convexity, and explain curve moves.
    Starting point: Knows that bond prices fall when yields rise.
    Focus: Rigorous duration, convexity, and curve math.
    Duration: 12 hours

    ## Chapter 1: Valuation and yield
    Objective: Price Treasury securities from cash flows and quoted yields.
    - Pricing a Treasury note
    - Yield measures
      - Worked example: a 10-year note
      - Day-count conventions (explainer)

    ## 2. Duration and convexity
    Objective: Measure and hedge interest-rate risk.
    - Duration
    - Convexity
    ```
    """

    func testExtractsPlanAndHidesFence() throws {
        let extraction = CoursePlanMarkdown.extract(from: treasuryReply)

        XCTAssertEqual(extraction.text, "Here is a rigorous, calculation-heavy path.")
        XCTAssertFalse(extraction.isIncomplete)
        guard case .plan(let plan) = try XCTUnwrap(extraction.blocks.first) else {
            return XCTFail("Expected a parsed plan")
        }
        XCTAssertEqual(plan.title, "Treasury Market Analysis")
        XCTAssertEqual(plan.summary, "Analyst-level Treasury valuation, rate risk, and curve analysis.")
        XCTAssertEqual(plan.estimatedDuration, "12 hours")
        XCTAssertEqual(plan.chapters.map(\.title), ["Valuation and yield", "Duration and convexity"])
        XCTAssertEqual(plan.chapters[0].children[1].children.map(\.title), [
            "Worked example: a 10-year note",
            "Day-count conventions",
        ])
        XCTAssertEqual(plan.chapters[0].children[1].children[1].role, .explainer)
    }

    func testBuildsTypedBriefThatPassesStrictValidation() throws {
        guard case .plan(let plan) = CoursePlanMarkdown.extract(from: treasuryReply).blocks.first else {
            return XCTFail("Expected a parsed plan")
        }
        let brief = try plan.brief(planID: "treasury-market-analysis", revision: 2).get()

        XCTAssertNil(AppleCoursePlanValidator.issue(in: brief, requiresTypedHierarchy: true))
        XCTAssertEqual(brief.revision, 2)
        XCTAssertEqual(brief.structureVersion, CoursePlanHierarchyPolicy.currentStructureVersion)
        let firstChapter = try XCTUnwrap(brief.learningPath?.first)
        XCTAssertEqual(firstChapter.role, .chapter)
        XCTAssertEqual(firstChapter.id, "valuation-and-yield")
        XCTAssertEqual(firstChapter.children.map(\.role), [.lesson, .subchapter])
        XCTAssertEqual(brief.chapters[1].deliverables, ["Duration", "Convexity"])

        // The brief survives the JSON round trip used by the protected plan file.
        let data = try JSONEncoder.courseFileEncoder.encode(brief)
        XCTAssertEqual(try JSONDecoder().decode(CourseBrief.self, from: data), brief)
    }

    func testStreamingFenceIsHiddenUntilClosed() {
        let partial = "Intro sentence.\n\n```learnfold-plan\n# Treasury"
        let extraction = CoursePlanMarkdown.extract(from: partial)

        XCTAssertTrue(extraction.isIncomplete)
        XCTAssertTrue(extraction.blocks.isEmpty)
        XCTAssertEqual(CoursePlanMarkdown.strippingFences(from: partial), "Intro sentence.")
    }

    func testMissingFieldsProduceSpecificIssue() {
        let reply = """
        ```learnfold-plan
        # Bonds
        Summary: A short course on bonds.
        ## Pricing
        - Present value
        ```
        """
        XCTAssertEqual(
            CoursePlanMarkdown.extract(from: reply).blocks,
            [.invalid("The plan is missing `Outcome:`, `Starting point:`, `Focus:`.")]
        )
    }

    func testLargePlanHasNoChapterOrLessonLimit() throws {
        let chapters = (1...10).map { chapter in
            let lessons = (1...8).map { "- Topic \(chapter) lesson \($0)" }.joined(separator: "\n")
            return "## Chapter topic \(chapter)\nObjective: Learn topic \(chapter).\n\(lessons)"
        }.joined(separator: "\n")
        let reply = """
        ```learnfold-plan
        # Bonds
        Summary: A long course on bonds.
        Outcome: Price bonds.
        Starting point: New to bonds.
        Focus: Pricing math.
        \(chapters)
        ```
        """
        guard case .plan(let plan) = CoursePlanMarkdown.extract(from: reply).blocks.first else {
            return XCTFail("Expected a parsed plan")
        }
        let brief = try plan.brief(planID: "bonds", revision: 1).get()
        XCTAssertEqual(brief.learningPath?.count, 10)
        XCTAssertEqual(brief.learningPath?.allSatisfy { $0.children.count == 8 }, true)
        XCTAssertEqual(brief.chapters.first?.deliverables.count, 8)
    }

    func testOverlyDeepSectionNamesTheSection() throws {
        let reply = """
        ```learnfold-plan
        # Bonds
        Summary: A short course on bonds.
        Outcome: Price bonds.
        Starting point: New to bonds.
        Focus: Pricing math.
        ## Pricing
        - Cash flows
          - Coupons
            - Coupon timing
              - Odd first coupons
        ```
        """
        guard case .plan(let plan) = CoursePlanMarkdown.extract(from: reply).blocks.first else {
            return XCTFail("Expected a parsed plan")
        }
        guard case .failure(let issue) = plan.brief(planID: "bonds", revision: 1) else {
            return XCTFail("Expected an overly deep section to be rejected")
        }
        XCTAssertTrue(issue.message.contains("“Odd first coupons” is nested 5 levels deep"), issue.message)
    }

    func testChapterWithoutLessonsGetsOneLesson() throws {
        let reply = """
        ```learnfold-plan
        # Bonds
        Summary: A short course on bonds.
        Outcome: Price bonds.
        Starting point: New to bonds.
        Focus: Pricing math.
        ## Pricing
        ```
        """
        guard case .plan(let plan) = CoursePlanMarkdown.extract(from: reply).blocks.first else {
            return XCTFail("Expected a parsed plan")
        }
        let brief = try plan.brief(planID: "bonds", revision: 1).get()
        XCTAssertEqual(brief.learningPath?.first?.children.first?.role, .lesson)
        XCTAssertEqual(brief.chapters[0].objective, "Build a working understanding of Pricing.")
    }

    func testTitlesKeepLeadingYears() {
        let reply = """
        ```learnfold-plan
        # Crises
        Summary: Financial crises.
        Outcome: Explain crises.
        Starting point: Some history.
        Focus: Causes.
        ## 1987 crash
        - 2008 collapse
        ```
        """
        guard case .plan(let plan) = CoursePlanMarkdown.extract(from: reply).blocks.first else {
            return XCTFail("Expected a parsed plan")
        }
        XCTAssertEqual(plan.chapters[0].title, "1987 crash")
        XCTAssertEqual(plan.chapters[0].children[0].title, "2008 collapse")
    }

    func testCodexInstructionsUseThePlanBlockInsteadOfTheTool() {
        let instructions = CourseExperienceStore.courseAgentInstructions
        XCTAssertTrue(instructions.contains(CoursePlanMarkdown.fenceLanguage))
        XCTAssertFalse(instructions.contains("call `present_course_plan`"))
        XCTAssertTrue(
            CourseExperienceStore.toolPlanCourseAgentInstructions.contains("call `present_course_plan`")
        )
        XCTAssertFalse(
            try CourseAgentTools.mcpToolDefinitions(includePresentPlan: false)
                .contains(where: { $0.name == CourseAgentTools.presentPlan })
        )
    }

    func testStrippingQuestionsAlsoHidesPlanFences() {
        let item = ConversationItem(
            id: "assistant-1",
            content: .assistant(ConversationAssistantMessageData(
                text: treasuryReply,
                agentNickname: nil,
                agentRole: nil,
                phase: nil
            ))
        )
        let stripped = CourseChatQuestionPolicy.strippingQuestions(from: [item])
        guard case .assistant(let data) = stripped.first?.content else {
            return XCTFail("Expected an assistant item")
        }
        XCTAssertEqual(data.text, "Here is a rigorous, calculation-heavy path.")
    }
}
