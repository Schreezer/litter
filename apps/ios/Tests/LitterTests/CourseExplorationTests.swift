import NativeEditorMCP
import XCTest
@testable import Litter

@MainActor
final class CourseExplorationTests: XCTestCase {
    // MARK: - Map

    func testReadablePagesIncludeExplorationsAtAnyDepth() {
        let nodes = sampleMap()
        XCTAssertEqual(
            CourseReadingOrder.readablePages(in: nodes).map(\.id),
            ["a", "deep", "deeper", "side", "b"]
        )
        XCTAssertEqual(CourseReadingOrder.lessons(in: nodes).map(\.id), ["a", "b"],
                       "The suggested route still lists only planned lessons.")
    }

    func testContinueResumesInsideAnExploration() {
        let nodes = sampleMap()
        XCTAssertEqual(
            CourseReadingOrder.resume(in: nodes, bookmark: .init(pageID: "page-deeper", offset: 40, isAtEnd: false))?.id,
            "deeper"
        )
        XCTAssertEqual(
            CourseReadingOrder.resume(in: nodes, bookmark: .init(pageID: "deleted", offset: 0, isAtEnd: false))?.id,
            "a",
            "A deleted page falls back to the start of the suggested route."
        )
    }

    func testTrailAndForkParentFollowTheTree() {
        let nodes = sampleMap()
        XCTAssertEqual(
            CourseExplorationMap.trail(toPageID: "page-deeper", in: nodes).map(\.id),
            ["chapter", "a", "deep", "deeper"]
        )
        XCTAssertEqual(CourseExplorationMap.forkParent(ofPageID: "page-deeper", in: nodes)?.id, "deep")
        XCTAssertEqual(CourseExplorationMap.forkParent(ofPageID: "page-deep", in: nodes)?.id, "a")
        XCTAssertNil(CourseExplorationMap.forkParent(ofPageID: "page-a", in: nodes),
                     "A planned lesson is not a fork.")
        XCTAssertEqual(CourseExplorationMap.explorations(in: nodes).map(\.id), ["deep", "deeper", "side"])
    }

    func testOpenThreadsAreUnfinishedTipsMostRecentFirst() {
        let nodes = sampleMap()
        var progress = CourseExplorationProgress()
        progress.lastVisitedAt["page-side"] = Date(timeIntervalSince1970: 200)
        progress.lastVisitedAt["page-deeper"] = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            CourseExplorationMap.openThreads(in: nodes, progress: progress).map(\.id),
            ["side", "deeper"],
            "“deep” continues into “deeper”, so only the tip is open."
        )
        progress.finishedPageIDs.insert("page-side")
        XCTAssertEqual(CourseExplorationMap.openThreads(in: nodes, progress: progress).map(\.id), ["deeper"])
        XCTAssertEqual(
            CourseExplorationMap.openThreads(in: nodes, progress: progress, excludingPageID: "page-deeper").map(\.id),
            []
        )
    }

    func testPinnedGoalContinuesAtItsMostRecentPage() {
        let nodes = sampleMap()
        let goal = try! XCTUnwrap(CourseExplorationMap.node(withID: "deep", in: nodes))
        var progress = CourseExplorationProgress()
        XCTAssertEqual(CourseExplorationMap.resume(inside: goal, progress: progress).id, "deep")
        progress.lastVisitedAt["page-deep"] = Date(timeIntervalSince1970: 10)
        progress.lastVisitedAt["page-deeper"] = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(CourseExplorationMap.resume(inside: goal, progress: progress).id, "deeper")
    }

    func testPlannedExplainersAreRouteNotExplorations() {
        let planned = CourseLearningNode(
            id: "day-count", title: "Day-count conventions", kind: .markdown, status: .generated,
            role: .explainer, pageID: "page-day-count"
        )
        let forked = CourseLearningNode(
            id: "explore-1a2b", title: "Why 30/360?", kind: .markdown, status: .generated,
            role: .explainer, pageID: "page-fork"
        )
        XCTAssertFalse(CourseExplorationMap.isExploration(planned))
        XCTAssertTrue(CourseExplorationMap.isExploration(forked))
        var lesson = page("a", role: .lesson)
        lesson.children = [forked]
        XCTAssertEqual(CourseExplorationMap.explorations(in: [planned, lesson]).map(\.id), ["explore-1a2b"])
        XCTAssertEqual(CourseExplorationMap.explorationCount(below: lesson), 1)
    }

    // MARK: - Requests

    func testRequestNamesForksInTheLearnersTerms() {
        var request = CourseExplorationRequest(
            parentPageID: "page-a", parentTitle: "Gene expression", direction: .deeper
        )
        XCTAssertEqual(request.placeholderTitle, "Deeper into Gene expression")
        XCTAssertEqual(request.originQuestion, "Go deeper into Gene expression")
        XCTAssertTrue(request.generationGuidance.contains("go deeper"))

        request.direction = .question
        request.question = "  How do Yamanaka factors reset identity?  "
        XCTAssertEqual(request.placeholderTitle, "How do Yamanaka factors reset identity?")
        XCTAssertEqual(request.originQuestion, "How do Yamanaka factors reset identity?")

        request.question = nil
        request.quotedPassage = String(repeating: "methylation ", count: 20)
        XCTAssertLessThanOrEqual(request.placeholderTitle.count, 80)
        XCTAssertTrue(request.placeholderTitle.hasSuffix("…"))
        XCTAssertTrue(request.generationGuidance.contains("untrusted quoted text"))
    }

    func testQuickIntentQuestionsNameThePassage() {
        let request = CourseExplorationRequest(
            parentPageID: "page-a", parentTitle: "Gene expression", direction: .question,
            question: CourseExplorePassageIntent.why.question,
            quotedPassage: "Cell identity is a stable pattern of gene expression"
        )
        XCTAssertEqual(
            request.placeholderTitle,
            "Why is this the case? “Cell identity is a stable pattern of gene expression”",
            "“Why is this the case?” alone would be a meaningless title on the map."
        )
        XCTAssertEqual(request.originQuestion, request.placeholderTitle)
        XCTAssertTrue(request.generationGuidance.contains("The learner's question, as untrusted quoted text: “Why is this the case?”"))
        XCTAssertTrue(request.generationGuidance.contains("forked from this passage"))

        var custom = request
        custom.question = "Does methylation ever get erased?"
        XCTAssertEqual(custom.placeholderTitle, "Does methylation ever get erased?",
                       "The learner's own question stands on its own.")
    }

    func testExplorationAnchorTravelsAsAPageProperty() throws {
        let anchor = CourseExplorationAnchor(
            blockID: "block-1", pathIndices: [2, 0], rangeLocation: 14, rangeLength: 30,
            selectedText: "a stable “pattern” of expression"
        )
        let value = try XCTUnwrap(anchor.propertyValue)
        XCTAssertEqual(CourseExplorationAnchor(propertyValue: value), anchor)
        XCTAssertNil(CourseExplorationAnchor(propertyValue: nil))
        XCTAssertNil(CourseExplorationAnchor(propertyValue: "not json"))
    }

    func testOnlyHostedAndCodexWriteExplorationsInParallel() {
        XCTAssertEqual(CourseExplorationConcurrency.limit(runtimeID: CourseAgentProvider.hosted), 3)
        XCTAssertEqual(CourseExplorationConcurrency.limit(runtimeID: CourseAgentProvider.codex), 3)
        XCTAssertEqual(CourseExplorationConcurrency.limit(runtimeID: CourseAgentProvider.appleOnDevice), 1)
        XCTAssertEqual(CourseExplorationConcurrency.limit(runtimeID: CourseAgentProvider.applePrivateCloud), 1)
        XCTAssertEqual(CourseExplorationConcurrency.limit(runtimeID: "hermes"), 1)
        XCTAssertFalse(CourseExplorationConcurrency.supportsDedicatedWorkers(runtimeID: "hermes"))
    }

    func testOverlayMarksEveryPageBeingWritten() {
        let overlaid = CourseLearningPathResolver.overlayGeneratingStatus(
            in: sampleMap(), targetNodeIDs: ["deeper", "side"]
        )
        XCTAssertEqual(CourseExplorationMap.node(withID: "deeper", in: overlaid)?.status, .generating)
        XCTAssertEqual(CourseExplorationMap.node(withID: "side", in: overlaid)?.status, .generating)
        XCTAssertEqual(CourseExplorationMap.node(withID: "deep", in: overlaid)?.status,
                       CourseExplorationMap.node(withID: "deep", in: sampleMap())?.status,
                       "A page that holds a writing exploration is not itself being written.")
        XCTAssertEqual(
            CourseLearningPathResolver.overlayGeneratingStatus(in: sampleMap(), targetNodeIDs: []),
            sampleMap()
        )
    }

    func testSynthesisListsTheExplorationsToConnect() {
        let request = CourseExplorationRequest(
            parentPageID: "page-a", parentTitle: "Gene expression", direction: .synthesis,
            exploredTitles: ["Reprogramming", "Organoids", "Chromatin"]
        )
        XCTAssertTrue(request.generationGuidance.contains("Explorations to connect:\n- Reprogramming"))
        XCTAssertEqual(request.placeholderTitle, "Tying the threads together")
    }

    func testExplorationPromptWritesOnlyItsOwnPageAndNamesIt() {
        let node = CourseLearningNode(
            id: "explore-1", title: "Deeper into A", kind: .markdown, status: .pendingGeneration,
            role: .explainer, pageID: "page-explore-1", originQuestion: "Go deeper into A"
        )
        let request = CourseExplorationRequest(parentPageID: "page-a", parentTitle: "A", direction: .wider)
        let prompt = CourseExperienceStore.explorationGenerationPrompt(for: node, request: request)
        XCTAssertTrue(CourseAgentInternalPromptPolicy.isInternalInstruction(prompt))
        XCTAssertTrue(prompt.contains("purpose: generate_course_node"))
        XCTAssertTrue(prompt.contains("Its native editor page ID is page-explore-1."))
        XCTAssertTrue(prompt.contains("It forks from the page ‘A’ (page ID: page-a)."))
        XCTAssertTrue(prompt.contains("zoom out"))
        XCTAssertTrue(prompt.contains("a specific properties.title"))
        XCTAssertTrue(prompt.contains("never create other pages"))

        let fallback = CourseExperienceStore.explorationGenerationPrompt(for: node, request: nil)
        XCTAssertTrue(fallback.contains("“Go deeper into A”"))
    }

    // MARK: - Progress

    @MainActor
    func testReadingProgressRecordsVisitsFinishesAndPinsPerCourse() throws {
        let suite = "CourseExplorationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let course = LearningCourse(
            id: "one", title: "Exploration", subtitle: "", accentHex: "007AFF", progress: 0,
            lessonCount: 1, duration: "", status: .ready, workspaceID: "one"
        )
        let store = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        let start = Date(timeIntervalSince1970: 1_000)

        store.recordReading(pageID: "page-deep", isAtEnd: false, for: course, now: start)
        let firstVersion = store.explorationProgressVersion
        store.recordReading(pageID: "page-deep", isAtEnd: false, for: course, now: start.addingTimeInterval(5))
        XCTAssertEqual(store.explorationProgress(for: course).lastVisitedAt["page-deep"], start,
                       "Scroll updates inside a minute keep the first visit stamp.")
        XCTAssertEqual(store.explorationProgressVersion, firstVersion)

        store.recordReading(pageID: "page-deep", isAtEnd: true, for: course, now: start.addingTimeInterval(10))
        XCTAssertEqual(store.explorationProgress(for: course).finishedPageIDs, ["page-deep"])
        XCTAssertGreaterThan(store.explorationProgressVersion, firstVersion)

        store.togglePinnedGoal(nodeID: "deep", for: course)
        let reopened = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        XCTAssertEqual(reopened.explorationProgress(for: course).pinnedNodeIDs, ["deep"])
        reopened.togglePinnedGoal(nodeID: "deep", for: course)
        XCTAssertEqual(reopened.explorationProgress(for: course).pinnedNodeIDs, [])

        let other = LearningCourse(
            id: "two", title: "Other", subtitle: "", accentHex: "007AFF", progress: 0,
            lessonCount: 1, duration: "", status: .ready, workspaceID: "one"
        )
        XCTAssertEqual(reopened.explorationProgress(for: other), CourseExplorationProgress())
    }

    // MARK: - Forking

    func testForkCreatesAPendingExplorationUnderTheReadPage() async throws {
        let suite = "CourseExplorationFork.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = "fork-\(UUID().uuidString.lowercased())"
        let course = LearningCourse(
            id: workspaceID, title: "Fork", subtitle: "", accentHex: "007AFF", progress: 0,
            lessonCount: 1, duration: "", status: .ready, workspaceID: workspaceID
        )
        let store = CourseExperienceStore(defaults: defaults, coursesRootURL: root)
        let repository = try await store.documentRepository(for: course)
        let plan = CourseReadingUITestHarness.approvablePlan(title: "Fork")
        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        let lessonPageID = try await repository.rootPageSnapshot().id

        let request = CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: "Fork", direction: .question,
            question: "Why does a random challenge stop cheating?"
        )
        let anchor = CourseExplorationAnchor(
            blockID: "block-1", pathIndices: [1], rangeLocation: 4, rangeLength: 16,
            selectedText: "random challenge"
        )
        let node = try await store.forkExploration(request, anchor: anchor, in: course)
        XCTAssertEqual(node.originAnchor, anchor, "The parent marks where the branch starts.")

        XCTAssertTrue(node.id.hasPrefix("explore-"))
        XCTAssertEqual(node.role, .explainer)
        XCTAssertEqual(node.status, .pendingGeneration)
        XCTAssertEqual(node.title, "Why does a random challenge stop cheating?")
        XCTAssertEqual(node.originQuestion, "Why does a random challenge stop cheating?")
        let page = try await repository.pageSnapshot(id: try XCTUnwrap(node.pageID))
        XCTAssertEqual(page.parentID, lessonPageID)
        XCTAssertEqual(
            CourseExperienceStore.directGenerationRequest(for: node, runtimeID: CourseAgentProvider.codex)?.target.id,
            node.id,
            "A fresh exploration is generated like any pending page."
        )

        // The agent's save: content, status, and a real title in one call.
        let arguments: [String: Any] = [
            "page_id": page.id,
            "expected_revision": page.revision,
            "command": "replace_content",
            "new_str": "## Why randomness matters\n\nA predictable challenge lets a prover cheat.",
            "properties": ["title": "Why the challenge must be random", "generation_status": "generated"],
        ]
        let result = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        )
        XCTAssertFalse(result.isError, "\(result.value)")
        let outline = try await repository.outline()
        let written = try XCTUnwrap(CourseExplorationMap.node(withID: node.id, in: outline.learningPages))
        XCTAssertEqual(written.status, .generated)
        XCTAssertEqual(written.title, "Why the challenge must be random")
        XCTAssertEqual(written.originAnchor, anchor, "The agent's save keeps the branch anchor.")
        let savedPage = try await repository.pageSnapshot(id: page.id)
        XCTAssertTrue(CourseExperienceStore.generatedLessonIsReady(savedPage))
    }

    // MARK: - Thread roles

    func testDiscussionInstructionsNeverAssessOrReplanTheCourse() {
        let course = CourseExperienceStore.courseAgentInstructions(
            planInstructions: CoursePlanMarkdownPromptPolicy.instructions
        )
        let discussion = CourseExperienceStore.courseAgentInstructions(
            planInstructions: CoursePlanMarkdownPromptPolicy.instructions,
            role: .discussion
        )
        XCTAssertTrue(course.contains("you MUST assess the learner"))
        XCTAssertTrue(course.contains(CoursePlanMarkdownPromptPolicy.instructions))
        XCTAssertTrue(course.contains(CourseExplorationPromptPolicy.instructions))

        XCTAssertFalse(discussion.contains("you MUST assess the learner"))
        XCTAssertFalse(discussion.contains(CoursePlanMarkdownPromptPolicy.instructions))
        XCTAssertTrue(discussion.contains("never creates or replans one"))
        XCTAssertTrue(discussion.contains("Never propose, present, or revise a course plan"))
        XCTAssertTrue(discussion.contains(CourseExplorationPromptPolicy.instructions))
        XCTAssertTrue(discussion.contains("Tool discipline:"))
        XCTAssertTrue(CourseExplorationPromptPolicy.instructions.contains("never cap how deep"))
    }

    func testDiscussionThreadsLaunchWithTheDiscussionRole() throws {
        let discussion = try CourseExperienceStore.courseThreadLaunchConfig(
            runtimeID: "codex", workspaceID: "w", modelID: nil, role: .discussion, courseMCPURL: nil
        )
        XCTAssertFalse(discussion.developerInstructions?.contains("you MUST assess the learner") ?? true)
        let course = try CourseExperienceStore.courseThreadLaunchConfig(
            runtimeID: "codex", workspaceID: "w", modelID: nil, courseMCPURL: nil
        )
        XCTAssertTrue(course.developerInstructions?.contains("you MUST assess the learner") ?? false)
    }

    func testHermesDiscussionsGetNoPlanTool() throws {
        let toolName = "\"name\":\"\(CourseAgentTools.presentPlan)\""
        let course = try CourseExperienceStore.remoteHermesDeveloperInstructions(workspaceID: "w")
        let discussion = try CourseExperienceStore.remoteHermesDeveloperInstructions(
            workspaceID: "w", role: .discussion
        )
        XCTAssertTrue(course.contains(toolName))
        XCTAssertFalse(discussion.contains(toolName))
        XCTAssertFalse(discussion.contains("you MUST assess the learner"))
    }

    func testAppleDiscussionsNeverEnterPlanning() {
        let target = PreparedCourseLessonTarget(nodeID: "a", pageID: "page-a", revision: 1)
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.applePrivateCloud, hasApprovedPlan: true,
                learnerPrompt: "Explain this", lessonTarget: target
            ),
            .editing
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice, hasApprovedPlan: false,
                learnerPrompt: "Revise the plan with more chapters", lessonTarget: target
            ),
            .editing
        )
        XCTAssertEqual(
            AppleCourseToolMode.forTurn(
                providerID: CourseAgentProvider.appleOnDevice, hasApprovedPlan: false,
                learnerPrompt: "Build a course"
            ),
            .planning,
            "The course's own thread still plans."
        )
    }

    func testAppleLessonToolAcceptsExplorationsButNotOtherUnplannedPages() {
        let plan = CourseReadingUITestHarness.approvablePlan(title: "Fork")
        let exploration = PreparedCourseLessonTarget(
            nodeID: "explore-abc123", title: "Why randomness matters", pageID: "p", revision: 1,
            courseRole: "explainer"
        )
        guard case .bound = AppleCourseLessonSemanticRequirementPolicy.binding(
            approvedPlan: plan, target: exploration
        ) else { return XCTFail("An exploration page must be writable by the Apple lesson tool.") }

        let stranger = PreparedCourseLessonTarget(
            nodeID: "made-up-lesson", title: "Not planned", pageID: "p", revision: 1, courseRole: "lesson"
        )
        guard case .rejected = AppleCourseLessonSemanticRequirementPolicy.binding(
            approvedPlan: plan, target: stranger
        ) else { return XCTFail("Unplanned non-exploration pages stay locked.") }
        XCTAssertFalse(CourseExplorationPolicy.isExplorationNode(id: "explore-x", role: .lesson))
        XCTAssertFalse(CourseExplorationPolicy.isExplorationNode(id: "why-bey", role: .explainer))
    }

    // MARK: - Fixtures

    /// chapter
    /// ├─ a (lesson)
    /// │  ├─ deep (exploration)
    /// │  │  └─ deeper (exploration)
    /// │  └─ side (exploration)
    /// └─ b (lesson)
    private func sampleMap() -> [CourseLearningNode] {
        let deeper = page("deeper", role: .explainer)
        var deep = page("deep", role: .explainer)
        deep.children = [deeper]
        let side = page("side", role: .explainer)
        var a = page("a", role: .lesson)
        a.children = [deep, side]
        let b = page("b", role: .lesson)
        return [CourseLearningNode(
            id: "chapter", title: "Chapter", kind: .folder, status: .partiallyGenerated,
            role: .chapter, children: [a, b]
        )]
    }

    private func page(_ id: String, role: CourseLearningNode.Role) -> CourseLearningNode {
        CourseLearningNode(
            id: id, title: id, kind: .markdown, status: .generated, role: role, pageID: "page-\(id)",
            originQuestion: role == .explainer ? "What about \(id)?" : nil
        )
    }
}
