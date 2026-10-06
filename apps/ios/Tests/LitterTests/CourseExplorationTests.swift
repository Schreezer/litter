import NativeBlockEditorCore
import NativeBlockEditorUI
import NativeEditorMCP
import XCTest
@testable import Litter
#if canImport(FoundationModels)
import FoundationModels
#endif

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
        XCTAssertTrue(prompt.contains("learnfold_generate_lesson instead, use that tool, pass that specific title as its title argument"),
                      "Apple runtimes name the page through the lesson tool.")
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

    // MARK: - Exploration state

    func testStateFollowsTheLiveJobBeforeThePage() {
        let pending = exploration(status: .pendingGeneration)
        let written = exploration(status: .generated)
        let progress = CourseExplorationProgress()

        XCTAssertEqual(CourseExplorationState.resolve(node: pending, job: job(.queued), progress: progress), .queued)
        XCTAssertEqual(CourseExplorationState.resolve(node: pending, job: job(.writing), progress: progress), .writing)
        XCTAssertEqual(
            CourseExplorationState.resolve(node: pending, job: job(.failed("Offline")), progress: progress),
            .failed("Offline")
        )
        XCTAssertEqual(
            CourseExplorationState.resolve(node: pending, job: job(.ready), progress: progress),
            .written(isNew: true, isFinished: false),
            "A finished job is written even before the outline refreshes."
        )
        XCTAssertEqual(
            CourseExplorationState.resolve(node: written, job: job(.failed("Late")), progress: progress),
            .written(isNew: true, isFinished: false),
            "A page that did get written is not shown as failed."
        )
        XCTAssertEqual(CourseExplorationState.resolve(node: pending, job: nil, progress: progress), .unwritten)
        XCTAssertEqual(
            CourseExplorationState.resolve(node: exploration(status: .generating), job: nil, progress: progress),
            .unwritten,
            "A write that stopped in an earlier launch has no writer left."
        )
        XCTAssertEqual(
            CourseExplorationState.resolve(node: pending, job: nil, progress: progress, isBackgroundGenerating: true),
            .writing
        )

        var visited = CourseExplorationProgress()
        visited.lastVisitedAt["page-explore-1"] = Date()
        XCTAssertEqual(
            CourseExplorationState.resolve(node: written, job: nil, progress: visited),
            .written(isNew: false, isFinished: false)
        )
        visited.finishedPageIDs.insert("page-explore-1")
        XCTAssertEqual(
            CourseExplorationState.resolve(node: written, job: nil, progress: visited),
            .written(isNew: false, isFinished: true)
        )
    }

    func testStatusLabelsNameTheForkWithoutNestedQuotes() {
        func request(question: String? = nil, passage: String? = nil, direction: CourseExplorationDirection = .question) -> CourseExplorationRequest {
            CourseExplorationRequest(
                parentPageID: "p", parentTitle: "Gene expression", direction: direction,
                question: question, quotedPassage: passage
            )
        }
        XCTAssertEqual(request(question: "Explain what chromatin loops are", passage: "enhancers").statusLabel,
                       "Explain what chromatin loops are")
        XCTAssertEqual(request(question: CourseExplorePassageIntent.why.question, passage: "chromatin loops").statusLabel,
                       "chromatin loops")
        XCTAssertEqual(request(passage: "chromatin loops").statusLabel, "chromatin loops")
        XCTAssertEqual(request(direction: .deeper).statusLabel, "Deeper into Gene expression")
        XCTAssertEqual(request(direction: .synthesis).statusLabel, "Tying the threads together")
        for label in [request(passage: "x").statusLabel, request(question: CourseExplorePassageIntent.how.question, passage: "y").statusLabel] {
            XCTAssertFalse(label.contains("“"), label)
        }

        var forked = exploration(status: .pendingGeneration)
        forked.originAnchor = CourseExplorationAnchor(
            blockID: "b", pathIndices: [1], rangeLocation: 0, rangeLength: 15, selectedText: "chromatin loops"
        )
        forked.originQuestion = "Why is this the case? “chromatin loops”"
        XCTAssertEqual(CourseExplorationRequest.statusLabel(for: forked), "chromatin loops")
        forked.originQuestion = "Tell me more about “chromatin loops”"
        XCTAssertEqual(CourseExplorationRequest.statusLabel(for: forked), "chromatin loops")
        forked.originQuestion = "Do loops ever break?"
        XCTAssertEqual(CourseExplorationRequest.statusLabel(for: forked), "Do loops ever break?")
    }

    func testReconstructedRequestKeepsThePassageAndParent() throws {
        var node = exploration(status: .pendingGeneration)
        node.originQuestion = "Do loops ever break?"
        node.originAnchor = CourseExplorationAnchor(
            blockID: "b", pathIndices: [1], rangeLocation: 0, rangeLength: 9, selectedText: "enhancers"
        )
        let parent = CourseLearningNode(
            id: "a", title: "Gene expression", kind: .markdown, status: .generated, role: .lesson, pageID: "page-a"
        )
        let request = try XCTUnwrap(CourseExplorationRequest.reconstructed(node: node, parent: parent))
        XCTAssertEqual(request.parentPageID, "page-a")
        XCTAssertEqual(request.parentTitle, "Gene expression")
        XCTAssertEqual(request.question, "Do loops ever break?")
        XCTAssertEqual(request.quotedPassage, "enhancers")
        XCTAssertNil(CourseExplorationRequest.reconstructed(node: node, parent: nil))
    }

    func testStatusSummaryCountsEveryStateInOneLine() {
        func summary(_ phases: [CourseExplorationJob.Phase]) -> CourseExplorationStatusSummary {
            CourseExplorationStatusSummary(
                jobs: phases.enumerated().map { job($1, id: "j\($0)") }, currentPageID: "page-a"
            )
        }
        XCTAssertTrue(summary([]).isEmpty)
        XCTAssertEqual(summary([.writing]).fullLabel, "Writing 1 exploration")
        XCTAssertEqual(summary([.writing, .queued]).fullLabel, "Writing 2 explorations")
        XCTAssertEqual(summary([.ready]).fullLabel, "1 exploration ready")
        XCTAssertEqual(summary([.ready, .ready]).fullLabel, "2 explorations ready")
        XCTAssertEqual(summary([.failed("x")]).fullLabel, "1 exploration didn’t finish")
        XCTAssertEqual(summary([.ready, .writing]).fullLabel, "1 ready · 1 writing")
        XCTAssertEqual(summary([.ready, .failed("x")]).fullLabel, "1 ready · 1 didn’t finish")
        XCTAssertEqual(summary([.writing, .failed("x")]).fullLabel, "1 writing · 1 didn’t finish")
        XCTAssertEqual(summary([.ready, .writing, .failed("x")]).fullLabel, "1 ready · 1 writing")
        XCTAssertEqual(summary([.ready, .writing, .failed("x")]).totalCount, 3)
        XCTAssertEqual(summary([.ready, .writing, .failed("x")]).accessibilityLabel,
                       "Explorations: 1 ready, 1 writing, 1 didn’t finish")
        XCTAssertEqual(summary([.writing]).systemImage, "pencil.line")
        XCTAssertEqual(summary([.writing, .ready]).systemImage, "arrow.triangle.branch")
        XCTAssertTrue(summary([.failed("x")]).isFailureOnly)

        let jobs = [
            job(.ready, id: "old-here", parentPageID: "page-a"),
            job(.ready, id: "elsewhere", parentPageID: "page-b"),
            job(.ready, id: "new-here", parentPageID: "page-a"),
        ]
        let ordered = CourseExplorationStatusSummary(jobs: jobs, currentPageID: "page-a")
        XCTAssertEqual(ordered.ready.map(\.id), ["new-here", "old-here", "elsewhere"],
                       "This page's explorations come first, newest first.")
        XCTAssertEqual(ordered.origin(of: jobs[0], currentPageID: "page-a"), "From this page")
        XCTAssertEqual(ordered.origin(of: jobs[1], currentPageID: "page-a"), "From “Parent”")
    }

    // MARK: - Overlapping highlights

    func testStackedHighlightsKeepEveryAnnotationReachable() {
        let first = annotation("a", 0, 10, .branch)
        let second = annotation("b", 0, 10, .branchPending)
        let runs = NativeBlockEditorAnnotationComposer.runs(for: [first, second], textLength: 20, isEditable: false)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].annotationIDs, ["a", "b"])
        XCTAssertTrue(runs[0].token.isStacked, "Two threads starting here draw a double line.")
        XCTAssertEqual(runs[0].token.underlinePattern, .solid)

        let partial = NativeBlockEditorAnnotationComposer.runs(
            for: [annotation("long", 0, 12, .branch), annotation("word", 4, 4, .branchNew)],
            textLength: 20, isEditable: false
        )
        XCTAssertEqual(partial.map(\.range), [
            NSRange(location: 0, length: 4), NSRange(location: 4, length: 4), NSRange(location: 8, length: 4),
        ])
        XCTAssertEqual(partial[1].annotationIDs, ["long", "word"])
        XCTAssertEqual(partial[1].primaryID, "word", "The most specific passage is the primary one.")
        XCTAssertFalse(partial[0].token.isStacked)

        let covering = NativeBlockEditorAnnotationComposer.annotations(
            covering: 5, in: [annotation("long", 0, 12, .branch), annotation("word", 4, 4, .branchNew)], textLength: 20
        )
        XCTAssertEqual(covering.map(\.id), ["long", "word"])
        XCTAssertEqual(NativeBlockEditorAnnotationComposer.primary(of: covering)?.id, "word")
        XCTAssertEqual(
            NativeBlockEditorAnnotationComposer.annotations(
                covering: 1, in: [annotation("long", 0, 12, .branch), annotation("word", 4, 4, .branchNew)], textLength: 20
            ).map(\.id),
            ["long"]
        )
    }

    func testHighlightInkFollowsState() {
        func token(_ annotations: [NativeBlockEditorTextAnnotation], editing: Bool = false) -> NativeBlockEditorAnnotationComposer.Token {
            NativeBlockEditorAnnotationComposer.runs(for: annotations, textLength: 20, isEditable: editing)[0].token
        }
        let pending = token([annotation("p", 0, 5, .branchPending)])
        XCTAssertEqual(pending.fill, .none)
        XCTAssertEqual(pending.underlinePattern, .dashed)
        XCTAssertEqual(pending.underlineHue, .branch)

        XCTAssertEqual(token([annotation("n", 0, 5, .branchNew)]).fill, .branchNew)
        XCTAssertTrue(token([annotation("n", 0, 5, .branchNew)]).isUnderlineStrong)
        XCTAssertFalse(token([annotation("v", 0, 5, .branch)]).isUnderlineStrong)

        let newOverDiscussion = token([annotation("d", 0, 5, .discussion), annotation("n", 0, 5, .branchNew)])
        XCTAssertEqual(newOverDiscussion.fill, .branchNew)
        let visitedOverDiscussion = token([annotation("d", 0, 5, .discussion), annotation("v", 0, 5, .branch)])
        XCTAssertEqual(visitedOverDiscussion.fill, .discussion)
        XCTAssertEqual(visitedOverDiscussion.underlineHue, .branch, "An exploration under a discussion stays visible.")
        XCTAssertEqual(visitedOverDiscussion.underlinePattern, .solid)
        let pendingOverDiscussion = token([annotation("d", 0, 5, .discussion), annotation("p", 0, 5, .branchPending)])
        XCTAssertEqual(pendingOverDiscussion.fill, .discussion)
        XCTAssertEqual(pendingOverDiscussion.underlinePattern, .dashed)

        let discussion = token([annotation("d", 0, 5, .discussion)])
        XCTAssertEqual(discussion.underlineHue, .discussion)
        XCTAssertEqual(discussion.fill, .discussion)

        let inert = token([annotation("n", 0, 5, .branchNew), annotation("p", 0, 5, .branchPending)], editing: true)
        XCTAssertTrue(inert.isInert)
        XCTAssertEqual(inert.fill, .none)
        XCTAssertFalse(inert.isStacked)
    }

    func testAdjacentPassagesStayApartAndCluster() {
        let annotations = [annotation("one", 0, 10, .branchPending), annotation("two", 11, 9, .branchPending)]
        let runs = NativeBlockEditorAnnotationComposer.runs(for: annotations, textLength: 20, isEditable: false)
        XCTAssertEqual(runs.map(\.range), [NSRange(location: 0, length: 10), NSRange(location: 11, length: 9)])
        XCTAssertTrue(NativeBlockEditorAnnotationComposer.annotations(
            covering: 10, in: annotations, textLength: 20
        ).isEmpty, "The space between two sentences opens nothing.")
        XCTAssertEqual(NativeBlockEditorAnnotationComposer.clusters(annotations, textLength: 20).map { $0.map(\.id) },
                       [["one"], ["two"]])
        XCTAssertEqual(NativeBlockEditorAnnotationComposer.clusters(
            [annotation("a", 0, 10, .branch), annotation("b", 5, 10, .branch), annotation("c", 16, 2, .branch)],
            textLength: 20
        ).map { $0.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertTrue(NativeBlockEditorAnnotationComposer.runs(
            for: [annotation("out", 15, 10, .branch)], textLength: 20, isEditable: false
        ).isEmpty, "A range past the text is never drawn.")
    }

    // MARK: - Never waiting on explorations

    func testOpeningAnUnwrittenExplorationQueuesItAndNeverNavigates() async throws {
        let fixture = try await explorationStoreFixture()
        let store = fixture.store
        let node = try await store.forkExploration(fixture.request, in: fixture.course)
        let appModel = AppModel()
        let appState = AppState()

        let outcome = try await store.openCourseNode(
            node, in: fixture.course, replacesCurrentPage: false, appModel: appModel, appState: appState
        )
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(store.navigationPath, [])
        await fixture.runtime.waitForSend()
        XCTAssertEqual(store.explorationJob(nodeID: node.id)?.phase, .writing)

        let again = try await store.openCourseNode(
            node, in: fixture.course, replacesCurrentPage: false, appModel: appModel, appState: appState
        )
        XCTAssertEqual(again, .stillWriting)
        try await store.writeExploration(nodeID: node.id, in: fixture.course, appModel: appModel, appState: appState)
        XCTAssertEqual(store.explorationJobs(courseID: fixture.course.id).count, 1, "A live exploration is queued once.")

        try await fixture.writePage(node)
        fixture.runtime.release()
        try await waitUntil { store.explorationJob(nodeID: node.id)?.phase == .ready }
        XCTAssertEqual(store.navigationPath, [], "A finished exploration never opens by itself.")

        store.dismissExplorationNotices(courseID: fixture.course.id)
        XCTAssertTrue(store.explorationJobs(courseID: fixture.course.id).isEmpty)
    }

    func testExplorationsWaitTheirTurnAsQueued() async throws {
        let fixture = try await explorationStoreFixture()
        let store = fixture.store
        let appModel = AppModel()
        let appState = AppState()
        for _ in 0..<(CourseExplorationConcurrency.parallelLimit + 1) {
            try await store.startExploration(
                fixture.request, in: fixture.course, appModel: appModel, appState: appState
            )
        }
        await fixture.runtime.waitForSend()
        try await waitUntil {
            store.explorationJobs(courseID: fixture.course.id).filter { $0.phase == .writing }.count
                == CourseExplorationConcurrency.parallelLimit
        }
        let phases = store.explorationJobs(courseID: fixture.course.id).map(\.phase)
        XCTAssertEqual(phases.filter { $0 == .queued }.count, 1, "The job past the limit waits to start.")
        XCTAssertEqual(
            CourseExplorationStatusSummary(jobs: store.explorationJobs(courseID: fixture.course.id), currentPageID: nil)
                .fullLabel,
            "Writing \(CourseExplorationConcurrency.parallelLimit + 1) explorations"
        )
        fixture.runtime.release(failing: true)
        try await waitUntil {
            store.explorationJobs(courseID: fixture.course.id).allSatisfy { $0.failureReason != nil }
        }
        let failed = try XCTUnwrap(store.explorationJobs(courseID: fixture.course.id).first)
        store.dismissExplorationJob(nodeID: failed.id)
        XCTAssertEqual(store.explorationJobs(courseID: fixture.course.id).count, CourseExplorationConcurrency.parallelLimit)
        store.dismissExplorationNotices(courseID: fixture.course.id)
        XCTAssertTrue(store.explorationJobs(courseID: fixture.course.id).isEmpty)
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

    func testAppleLessonTitleNamesOnlyExplorations() {
        var plan = CourseReadingUITestHarness.approvablePlan(title: "Fork")
        let exploration = PreparedCourseLessonTarget(
            nodeID: "explore-abc123", title: "Deeper into Fork", pageID: "p", revision: 1,
            courseRole: "explainer"
        )
        XCTAssertEqual(
            AppleCourseLessonTitlePolicy.savedTitle(
                "  Why the challenge\nmust be random ", target: exploration, approvedPlan: plan
            ),
            "Why the challenge must be random"
        )
        let tooLong = String(repeating: "a", count: CoursePlanHierarchyPolicy.maximumNodeTitleLength + 1)
        for unusable in ["", "  \n ", tooLong] {
            XCTAssertNil(
                AppleCourseLessonTitlePolicy.savedTitle(unusable, target: exploration, approvedPlan: plan),
                "An empty or overlong title keeps the placeholder."
            )
        }
        XCTAssertNil(
            AppleCourseLessonTitlePolicy.savedTitle("A new name", target: exploration, approvedPlan: nil),
            "Without the approved plan Learnfold cannot prove the page is unplanned."
        )

        let planned = PreparedCourseLessonTarget(
            nodeID: "foundation-practice", title: "Practice the Core Foundation", pageID: "p",
            revision: 1, courseRole: "lesson"
        )
        XCTAssertNil(
            AppleCourseLessonTitlePolicy.savedTitle("A new name", target: planned, approvedPlan: plan),
            "A planned lesson keeps its approved title."
        )

        plan.learningPath?[0].children.append(CourseLearningNode(
            id: "explore-planned", title: "A planned explainer", kind: .markdown,
            status: .pendingGeneration, role: .explainer
        ))
        let plannedExplainer = PreparedCourseLessonTarget(
            nodeID: "explore-planned", title: "A planned explainer", pageID: "p", revision: 1,
            courseRole: "explainer"
        )
        XCTAssertNil(
            AppleCourseLessonTitlePolicy.savedTitle("A new name", target: plannedExplainer, approvedPlan: plan),
            "A page in the approved plan is never renamed, whatever its ID looks like."
        )
    }

    func testAppleLessonContentDecodesAnOptionalTitle() throws {
        let titled = try JSONDecoder().decode(
            AppleCourseGeneratedLessonContent.self,
            from: Data(#"{"title":"Why randomness matters","explanation":"E","example":"X","exercise":"Q"}"#.utf8)
        )
        XCTAssertEqual(titled.title, "Why randomness matters")
        let untitled = try JSONDecoder().decode(
            AppleCourseGeneratedLessonContent.self,
            from: Data(#"{"explanation":"E","example":"X","exercise":"Q","visualization_html":""}"#.utf8)
        )
        XCTAssertEqual(untitled.title, "")
    }

    #if canImport(FoundationModels)
    /// Drives the real Apple lesson tool against an approved course shell, as
    /// a background generation does: the target comes from the persisted
    /// current-lesson file and the write goes through the native editor.
    func testAppleLessonToolSavesExplorationTitlesAndKeepsPlannedTitles() async throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Foundation Models tools require iOS 26 or later.")
        }
        let suite = "CourseExplorationAppleTitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // The Apple tools resolve courses under Documents/Apps/Courses.
        let coursesRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
        let workspaceID = "apple-exploration-title-\(UUID().uuidString.lowercased())"
        let workspaceURL = coursesRoot.appendingPathComponent(workspaceID, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(
                at: AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: workspaceURL)
            )
        }
        let course = LearningCourse(
            id: workspaceID, title: "Fork", subtitle: "", accentHex: "007AFF", progress: 0,
            lessonCount: 1, duration: "", status: .ready, workspaceID: workspaceID,
            agentRuntimeKind: CourseAgentProvider.appleOnDevice
        )
        let store = CourseExperienceStore(defaults: defaults, coursesRootURL: coursesRoot)
        let repository = try await store.documentRepository(for: course)
        let plan = CourseReadingUITestHarness.approvablePlan(title: "Fork")
        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        // Persists the first planned lesson as the current Apple target.
        let plannedTarget = try await store.prepareApprovedCourseShell(brief: plan, workspaceID: workspaceID)

        func generate(_ arguments: [String: Any]) async throws -> String {
            let tools = try AppleCourseToolFactory.tools(
                providerID: CourseAgentProvider.appleOnDevice,
                workspaceID: workspaceID,
                mode: .generatingLesson,
                lessonValidationRetryGate: AppleCourseLessonValidationRetryGate(),
                onCoursePlan: { _ in XCTFail("Lesson generation never presents a plan.") }
            )
            let tool = try XCTUnwrap(tools.first { $0.name == "learnfold_generate_lesson" })
            let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            return try await Self.callAppleTool(tool, argumentsJSON: json)
        }
        let lesson: [String: Any] = [
            "explanation": "A random challenge stops a prover from preparing an answer in advance.",
            "example": "Flip a coin before each round and ask for the matching proof.",
            "exercise": "Explain what a cheating prover gains from a predictable challenge.",
            "visualization_html": "",
        ]

        // A planned lesson keeps its approved title even when the model names it.
        var renamedLesson = lesson
        renamedLesson["title"] = "A title the model made up"
        let plannedResult = try await generate(renamedLesson)
        XCTAssertTrue(AppleCourseLessonToolResultPolicy.isAccepted(plannedResult), plannedResult)
        let plannedPage = try await repository.pageSnapshot(id: plannedTarget.pageID)
        XCTAssertEqual(plannedPage.title, "Practice the Core Foundation")
        XCTAssertTrue(CourseExperienceStore.generatedLessonIsReady(plannedPage))

        // An exploration takes the specific title the model chose.
        let request = CourseExplorationRequest(
            parentPageID: plannedTarget.pageID, parentTitle: plannedPage.title, direction: .deeper
        )
        let named = try await store.forkExploration(request, in: course)
        XCTAssertEqual(named.title, request.placeholderTitle)
        try await store.persistAppleGenerationTarget(for: named, workspaceID: workspaceID)
        var titledLesson = lesson
        titledLesson["title"] = "  Why the challenge must be random "
        let namedResult = try await generate(titledLesson)
        XCTAssertTrue(AppleCourseLessonToolResultPolicy.isAccepted(namedResult), namedResult)
        let namedPage = try await repository.pageSnapshot(id: try XCTUnwrap(named.pageID))
        XCTAssertEqual(namedPage.title, "Why the challenge must be random")
        XCTAssertTrue(CourseExperienceStore.generatedLessonIsReady(namedPage))
        XCTAssertEqual(namedPage.document.root.data["course_node_id"]?.stringValue, named.id)
        XCTAssertEqual(namedPage.document.root.data["course_role"]?.stringValue, "explainer")

        // Rewriting a finished exploration keeps the title it already has.
        try await store.persistAppleGenerationTarget(for: named, workspaceID: workspaceID)
        var retitledLesson = lesson
        retitledLesson["title"] = "A later rename"
        let rewriteResult = try await generate(retitledLesson)
        XCTAssertTrue(AppleCourseLessonToolResultPolicy.isAccepted(rewriteResult), rewriteResult)
        let rewrittenPage = try await repository.pageSnapshot(id: try XCTUnwrap(named.pageID))
        XCTAssertEqual(rewrittenPage.title, "Why the challenge must be random")
        XCTAssertTrue(CourseExperienceStore.generatedLessonIsReady(rewrittenPage))

        // Without a usable title the exploration keeps its placeholder.
        for title in [nil, "   "] as [String?] {
            let unnamed = try await store.forkExploration(request, in: course)
            try await store.persistAppleGenerationTarget(for: unnamed, workspaceID: workspaceID)
            var untitledLesson = lesson
            if let title { untitledLesson["title"] = title }
            let unnamedResult = try await generate(untitledLesson)
            XCTAssertTrue(AppleCourseLessonToolResultPolicy.isAccepted(unnamedResult), unnamedResult)
            let unnamedPage = try await repository.pageSnapshot(id: try XCTUnwrap(unnamed.pageID))
            XCTAssertEqual(unnamedPage.title, request.placeholderTitle)
            XCTAssertTrue(CourseExperienceStore.generatedLessonIsReady(unnamedPage))
        }

        let outline = try await repository.outline()
        XCTAssertEqual(
            CourseExplorationMap.node(withID: named.id, in: outline.learningPages)?.title,
            "Why the challenge must be random"
        )
        XCTAssertEqual(
            CourseExplorationMap.node(withID: plannedTarget.nodeID, in: outline.learningPages)?.title,
            "Practice the Core Foundation"
        )
    }

    @available(iOS 26.0, *)
    nonisolated private static func callAppleTool<T: Tool>(
        _ tool: T,
        argumentsJSON: String
    ) async throws -> String {
        let output = try await tool.call(arguments: try T.Arguments(GeneratedContent(json: argumentsJSON)))
        return try XCTUnwrap(output as? String)
    }
    #endif

    // MARK: - Fixtures

    /// chapter
    /// ├─ a (lesson)
    /// │  ├─ deep (exploration)
    /// │  │  └─ deeper (exploration)
    /// │  └─ side (exploration)
    /// └─ b (lesson)
    private func exploration(status: CourseLearningNode.GenerationStatus) -> CourseLearningNode {
        CourseLearningNode(
            id: "explore-1", title: "Deeper into A", kind: .markdown, status: status,
            role: .explainer, pageID: "page-explore-1", originQuestion: "Go deeper into A"
        )
    }

    private func job(
        _ phase: CourseExplorationJob.Phase,
        id: String = "explore-1",
        parentPageID: String = "page-a"
    ) -> CourseExplorationJob {
        CourseExplorationJob(
            id: id, courseID: "course", parentPageID: parentPageID, pageID: "page-\(id)",
            title: "Title \(id)", label: "Label \(id)", parentTitle: "Parent", phase: phase
        )
    }

    private func annotation(
        _ id: String, _ location: Int, _ length: Int, _ style: NativeBlockEditorTextAnnotation.Style
    ) -> NativeBlockEditorTextAnnotation {
        NativeBlockEditorTextAnnotation(
            id: id, blockID: "block", path: BlockPath([0]),
            range: NSRange(location: location, length: length), style: style
        )
    }

    private struct ExplorationStoreFixture {
        let store: CourseExperienceStore
        let runtime: GatedExplorationRuntime
        let course: LearningCourse
        let request: CourseExplorationRequest
        let repository: CourseDocumentRepository

        /// Saves the page the way an agent does, so the job can finish.
        func writePage(_ node: CourseLearningNode) async throws {
            let page = try await repository.pageSnapshot(id: try XCTUnwrap(node.pageID))
            let arguments: [String: Any] = [
                "page_id": page.id,
                "expected_revision": page.revision,
                "command": "replace_content",
                "new_str": "## Loops\n\nChromatin loops bring enhancers near promoters.",
                "properties": ["title": "How chromatin loops work", "generation_status": "generated"],
            ]
            let result = await repository.callTool(
                named: NativeEditorMCPToolCatalog.updatePage,
                argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            )
            XCTAssertFalse(result.isError, "\(result.value)")
        }
    }

    private func explorationStoreFixture() async throws -> ExplorationStoreFixture {
        let suite = "CourseExplorationWorkers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let workspaceID = "workers-\(UUID().uuidString.lowercased())"
        let course = LearningCourse(
            id: workspaceID, title: "Workers", subtitle: "", accentHex: "007AFF", progress: 0,
            lessonCount: 1, duration: "", status: .ready, workspaceID: workspaceID,
            agentRuntimeKind: CourseAgentProvider.hosted
        )
        let runtime = GatedExplorationRuntime()
        let store = CourseExperienceStore(defaults: defaults, hostedRuntime: runtime, coursesRootURL: root)
        let repository = try await store.documentRepository(for: course)
        let plan = CourseReadingUITestHarness.approvablePlan(title: "Workers")
        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        let lessonPageID = try await repository.rootPageSnapshot().id
        return ExplorationStoreFixture(
            store: store,
            runtime: runtime,
            course: course,
            request: CourseExplorationRequest(
                parentPageID: lessonPageID, parentTitle: "Workers", direction: .question,
                question: "Explain what chromatin loops are", quotedPassage: "chromatin loops"
            ),
            repository: repository
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

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

/// A Hosted runtime whose exploration writes stay open until the test lets
/// them finish, so a test can look at a job while it is being written.
@MainActor
private final class GatedExplorationRuntime: HostedCourseAgentRuntime {
    private var gates: [CheckedContinuation<Bool, Never>] = []
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var released: Bool?
    private(set) var sendCount = 0

    func availability() -> HostedCourseAgentAvailability {
        .init(available: true, reason: "Test exploration runtime")
    }

    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] { [] }

    func send(
        sessionID: UUID,
        workspaceID: String,
        courseDirectory: URL,
        prompt: String,
        messageID: UUID?,
        role: CourseAgentThreadRole,
        onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
        onPartialResponse: @escaping @MainActor (String) -> Void,
        onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void
    ) async throws {
        sendCount += 1
        sendWaiter?.resume()
        sendWaiter = nil
        let fails: Bool
        if let released {
            fails = released
        } else {
            fails = await withCheckedContinuation { gates.append($0) }
        }
        if fails {
            throw NSError(domain: "GatedExplorationRuntime", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Simulated exploration failure",
            ])
        }
    }

    func cancel(sessionID: UUID) {}

    func waitForSend() async {
        if sendCount == 0 { await withCheckedContinuation { sendWaiter = $0 } }
    }

    /// Finishes every write in flight and every later one.
    func release(failing: Bool = false) {
        released = failing
        let waiting = gates
        gates = []
        waiting.forEach { $0.resume(returning: failing) }
    }
}
