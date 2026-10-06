import XCTest
@testable import Litter

@MainActor
final class CourseAssessmentInitiationTests: XCTestCase {
    private let pendingKey = "learnfold.course.pendingSelectionSubmissions"
    private let receiptKey = "learnfold.course.assistantInitiationReceipts.v1"

    func testControlInstructionIsDurableButNeverVisibleDraftText() {
        let instruction = controlInstruction()
        XCTAssertEqual(CourseExperienceStore.durableSubmissionText(instruction), instruction)
        XCTAssertNil(CourseAgentInternalPromptPolicy.visibleLearnerText(instruction))
        XCTAssertEqual(CourseExperienceStore.durableSubmissionText("My question"), "My question")
        XCTAssertNil(CourseExperienceStore.durableSubmissionText(
            CourseAgentInternalPromptPolicy.wrap("Generate this lesson.", purpose: "generate_course_node")
        ))
    }

    func testUnknownControlSubmissionSurvivesRelaunchWithoutBecomingComposerDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let instruction = controlInstruction()
        var record = pendingRecord(fixture: fixture, instruction: instruction, state: .acceptanceUnknown)
        record["draftText"] = instruction
        fixture.defaults.set(
            try JSONSerialization.data(withJSONObject: [record]), forKey: pendingKey
        )

        let store = fixture.makeStore()
        XCTAssertEqual(store.submissionRecoveryState(for: fixture.discussion.id), .acceptanceUnknown)
        XCTAssertNil(store.takeDraft(for: fixture.discussion.id))
        XCTAssertFalse(store.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
        let preserved = try XCTUnwrap(try pendingRecords(in: fixture.defaults).first)
        XCTAssertEqual(preserved["text"] as? String, instruction)
        XCTAssertEqual(preserved["promptText"] as? String, instruction)
        XCTAssertEqual(preserved["runtimeID"] as? String, CourseAgentProvider.hosted)
        XCTAssertEqual(preserved["attemptID"] as? String, record["attemptID"] as? String)
        XCTAssertNil(preserved["draftText"])
    }

    func testAcceptedRecoveryRestoresScopedHashReceiptAndKeepsHumanDraft() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let instruction = controlInstruction()
        var record = pendingRecord(
            fixture: fixture, instruction: instruction, state: .acceptedReplyIncomplete
        )
        record["draftText"] = "My unsent follow-up"
        fixture.defaults.set(
            try JSONSerialization.data(withJSONObject: [record]), forKey: pendingKey
        )

        let store = fixture.makeStore()
        XCTAssertEqual(store.takeDraft(for: fixture.discussion.id), "My unsent follow-up")
        XCTAssertTrue(store.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
        XCTAssertFalse(store.assistantInitiationWasAccepted(
            controlInstruction(attemptID: "another-attempt"), selectionDiscussionID: fixture.discussion.id
        ))
        XCTAssertFalse(store.assistantInitiationWasAccepted(instruction, selectionDiscussionID: UUID()))
        let receipts = try XCTUnwrap(fixture.defaults.stringArray(forKey: receiptKey))
        XCTAssertEqual(receipts.count, 1)
        XCTAssertFalse(receipts[0].contains("private-answer-key"))
        XCTAssertFalse(receipts[0].contains("learnfold_assessment_discussion"))
        XCTAssertEqual(receipts[0].split(separator: ":").last?.count, 64)

        let relaunched = fixture.makeStore()
        XCTAssertTrue(relaunched.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
    }

    func testQueueingDoesNotMarkInitiationAcceptedUntilProviderResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = AssessmentInitiationHostedRuntime()
        let store = fixture.makeStore(runtime: runtime)
        let instruction = controlInstruction()
        store.saveDraft("My unsent follow-up", for: fixture.discussion.id)
        XCTAssertTrue(store.sendMessage(
            instruction, selectionDiscussionID: fixture.discussion.id, visibility: .assistantInitiated,
            appModel: AppModel(), appState: AppState()
        ))
        await runtime.waitForSend()
        XCTAssertFalse(store.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
        XCTAssertEqual(store.assistantInitiationVersion, 0)

        runtime.acceptAndComplete()
        try await waitUntilSettled(store, discussionID: fixture.discussion.id)
        XCTAssertTrue(store.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
        XCTAssertEqual(store.assistantInitiationVersion, 1)
        XCTAssertEqual(store.takeDraft(for: fixture.discussion.id), "My unsent follow-up")
        XCTAssertEqual(store.localMessages(for: fixture.discussion.id).map(\.text), ["Let's discuss your answer."])
        XCTAssertTrue(fixture.makeStore().assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
    }

    func testKnownPreacceptanceFailureKeepsHumanDraftAndAllowsNoAcceptedReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = AssessmentInitiationHostedRuntime()
        let store = fixture.makeStore(runtime: runtime)
        runtime.available = false
        let instruction = controlInstruction()
        store.saveDraft("Keep this human draft", for: fixture.discussion.id)
        XCTAssertTrue(store.sendMessage(
            instruction, selectionDiscussionID: fixture.discussion.id, visibility: .assistantInitiated,
            appModel: AppModel(), appState: AppState()
        ))
        try await waitUntilSettled(store, discussionID: fixture.discussion.id)

        XCTAssertEqual(store.submissionRecoveryState(for: fixture.discussion.id), .knownNotAccepted)
        XCTAssertEqual(store.takeDraft(for: fixture.discussion.id), "Keep this human draft")
        XCTAssertFalse(store.assistantInitiationWasAccepted(
            instruction, selectionDiscussionID: fixture.discussion.id
        ))
        XCTAssertEqual(store.assistantInitiationVersion, 0)
        XCTAssertTrue(store.localMessages(for: fixture.discussion.id).isEmpty)
        let preserved = try XCTUnwrap(try pendingRecords(in: fixture.defaults).first)
        XCTAssertEqual(preserved["text"] as? String, instruction)
        XCTAssertEqual(preserved["draftText"] as? String, "Keep this human draft")
    }

    private func controlInstruction(attemptID: String = "assessment-attempt") -> String {
        """
        <learnfold_assessment_discussion version="1">
        attempt_id: \(attemptID)
        answer_key: private-answer-key
        Discuss the learner's answer without sending another user bubble.
        </learnfold_assessment_discussion>
        """
    }

    private func pendingRecord(
        fixture: Fixture,
        instruction: String,
        state: CourseAgentSubmissionRecoveryState
    ) -> [String: Any] {
        [
            "discussionID": fixture.discussion.id.uuidString,
            "workspaceID": fixture.workspaceID,
            "text": instruction,
            "promptText": instruction,
            "recoveryState": state.rawValue,
            "attemptID": UUID().uuidString,
            "optimisticMessageID": UUID().uuidString,
            "runtimeID": CourseAgentProvider.hosted,
        ]
    }

    private func pendingRecords(in defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: pendingKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func waitUntilSettled(_ store: CourseExperienceStore, discussionID: UUID) async throws {
        for _ in 0..<200 where store.isAgentRequestPending(for: discussionID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isAgentRequestPending(for: discussionID))
    }

    @MainActor
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let root: URL
        let workspaceID: String
        let discussion: CourseSelectionDiscussion

        init() throws {
            suiteName = "CourseAssessmentInitiation-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
            workspaceID = UUID().uuidString.lowercased()
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(workspaceID, isDirectory: true),
                withIntermediateDirectories: true
            )
            let course = LearningCourse(
                id: "biology", title: "Biology", subtitle: "Cells", accentHex: "007AFF",
                progress: 0, lessonCount: 1, duration: "One week", status: .ready,
                workspaceID: workspaceID, agentRuntimeKind: CourseAgentProvider.hosted
            )
            discussion = CourseSelectionDiscussion(
                courseID: course.id, pageID: "assessment-page", pageTitle: "Cells",
                target: CourseAgentExecutionTarget(
                    runtimeID: CourseAgentProvider.hosted, serverID: nil,
                    modelID: SystemHostedCourseAgentRuntime.modelID
                )
            )
            defaults.set(try JSONEncoder().encode([course]), forKey: "snappy.course.savedCourses")
            defaults.set(try JSONEncoder().encode([discussion]), forKey: "snappy.course.selectionDiscussions")
            defaults.set(CourseAgentProvider.hosted, forKey: "snappy.course.selectedAgent")
        }

        func makeStore(runtime: AssessmentInitiationHostedRuntime? = nil) -> CourseExperienceStore {
            CourseExperienceStore(
                defaults: defaults, environment: [:],
                hostedRuntime: runtime ?? AssessmentInitiationHostedRuntime(), coursesRootURL: root
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class AssessmentInitiationHostedRuntime: HostedCourseAgentRuntime {
    var available = true
    private var sendStarted = false
    private var sendWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var partialResponse: (@MainActor (String) -> Void)?

    func availability() -> HostedCourseAgentAvailability {
        .init(available: available, reason: "Assessment initiation test runtime")
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
        partialResponse = onPartialResponse
        sendStarted = true
        sendWaiter?.resume()
        sendWaiter = nil
        await withCheckedContinuation { completion = $0 }
    }

    func waitForSend() async {
        if !sendStarted { await withCheckedContinuation { sendWaiter = $0 } }
    }

    func acceptAndComplete() {
        partialResponse?("Let's discuss your answer.")
        completion?.resume()
        completion = nil
    }

    func cancel(sessionID: UUID) {
        completion?.resume()
        completion = nil
    }
}
