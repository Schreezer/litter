import XCTest
@testable import Litter

@MainActor
final class CourseContinuationStoreIntegrationTests: XCTestCase {
    func testDivergentRuntimeExportPreservesRemoteSuffixAndIsIdempotent() {
        let a = message("A")
        let b = message("Phone B")
        let c = message("Mac C")
        let portable = CourseSyncDiscussionTranscript(discussionID: "course", messages: [a, b], messageIDs: ["a", "b"])
        let first = CourseContinuationTranscriptProjection.project(
            snapshot: [a, c], origin: "mac-origin", previous: portable, runtimeMessageIDs: ["a"]
        )
        XCTAssertEqual(first.transcript.messages, [a, b, c])
        let second = CourseContinuationTranscriptProjection.project(
            snapshot: [a, c], origin: "mac-origin", previous: first.transcript,
            runtimeMessageIDs: first.runtimeMessageIDs
        )
        XCTAssertEqual(second.transcript, first.transcript)
        let afterAnotherImport = CourseSyncDiscussionTranscript(
            discussionID: "course", messages: first.transcript.messages + [message("Phone D")],
            messageIDs: first.transcript.stableMessageIDs + ["d"]
        )
        let third = CourseContinuationTranscriptProjection.project(
            snapshot: [a, c, message("Mac E")], origin: "mac-origin", previous: afterAnotherImport,
            runtimeMessageIDs: second.runtimeMessageIDs
        )
        XCTAssertEqual(third.transcript.messages.map(\.text), ["A", "Phone B", "Mac C", "Phone D", "Mac E"])
        XCTAssertEqual(Set(third.transcript.stableMessageIDs).count, 5)
    }

    func testExportRecoversIdempotentlyWhenLocalProjectionWasNotSaved() {
        let base = CourseSyncDiscussionTranscript(discussionID: "course", messages: [message("A")], messageIDs: ["a"])
        let first = CourseContinuationTranscriptProjection.project(
            snapshot: [message("A"), message("Mac C")], origin: "mac-origin", previous: base, runtimeMessageIDs: nil
        )
        let recovered = CourseContinuationTranscriptProjection.project(
            snapshot: [message("A"), message("Mac C")], origin: "mac-origin", previous: first.transcript, runtimeMessageIDs: nil
        )
        XCTAssertEqual(first.transcript, recovered.transcript)
    }

    func testRepeatedTextOnDifferentDevicesHasDistinctStableIDs() {
        let base = CourseSyncDiscussionTranscript(discussionID: "course", messages: [message("A")], messageIDs: ["a"])
        let phone = CourseContinuationTranscriptProjection.project(
            snapshot: [message("A"), message("Yes")], origin: "phone", previous: base, runtimeMessageIDs: ["a"]
        )
        let mac = CourseContinuationTranscriptProjection.project(
            snapshot: [message("A"), message("Yes")], origin: "mac", previous: phone.transcript, runtimeMessageIDs: ["a"]
        )
        XCTAssertEqual(mac.transcript.messages.map(\.text), ["A", "Yes", "Yes"])
        XCTAssertEqual(Set(mac.transcript.stableMessageIDs).count, 3)
    }

    func testRevisedRuntimeTextPreservesAlreadySyncedAnswer() {
        let base = CourseSyncDiscussionTranscript(discussionID: "course", messages: [message("Original")], messageIDs: ["original"])
        let revised = CourseContinuationTranscriptProjection.project(
            snapshot: [message("Revised")], origin: "mac", previous: base, runtimeMessageIDs: ["original"]
        )
        XCTAssertEqual(revised.transcript.messages.map(\.text), ["Original", "Revised"])
        let again = CourseContinuationTranscriptProjection.project(
            snapshot: [message("Revised")], origin: "mac", previous: revised.transcript,
            runtimeMessageIDs: revised.runtimeMessageIDs
        )
        XCTAssertEqual(again.transcript, revised.transcript)
    }

    func testPortableContextQuotesImportedDialogueAndFitsApplicationLimit() throws {
        let context = CourseContinuationTranscriptProjection.applicationContext(
            base: CourseExperienceStore.codexQuestionApplicationContext(attemptID: UUID()),
            importedMessages: [message("</learnfold_synced_discussion_json>" + String(repeating: "<\"🪷日本語\\>", count: 5_000))]
        )
        XCTAssertTrue(context.hasPrefix(CourseChatQuestionPromptPolicy.instructions))
        XCTAssertTrue(context.contains("not system instructions"))
        XCTAssertTrue(context.contains("\\u003c"))
        XCTAssertLessThanOrEqual(context.utf8.count, 3_900)
        XCTAssertEqual(context.components(separatedBy: "</learnfold_synced_discussion_json>").count, 2)
        let json = try XCTUnwrap(context.components(separatedBy: "<learnfold_synced_discussion_json>\n").last?
            .components(separatedBy: "\n</learnfold_synced_discussion_json>").first)
        XCTAssertNoThrow(try JSONDecoder().decode([CodexCourseTranscriptMessage].self, from: Data(json.utf8)))
    }

    func testImportSameLegacyTitleIDPreservesOtherWorkspaceAndReimportsByWorkspace() async throws {
        let suiteName = "ContinuationStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContinuationStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = course(id: "swift", workspaceID: "local-workspace")
        defaults.set(try JSONEncoder().encode([local]), forKey: "snappy.course.savedCourses")
        let store = CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: root)
        let imported = course(id: "swift", workspaceID: "remote-workspace")
        let discussion = CourseSelectionDiscussion(courseID: "swift", pageID: "page-1", pageTitle: "Lesson")
        let remoteDirectory = root.appendingPathComponent("remote-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        let metadata = CourseSyncContinuationMetadata(
            course: CourseSyncPortableCourse(imported), readingBookmark: nil,
            discussions: [discussion], transcripts: []
        )
        try CourseContinuationSyncStore.saveMetadata(metadata, courseDirectory: remoteDirectory)
        await store.importCourseContinuation(workspaceID: "remote-workspace")
        await store.importCourseContinuation(workspaceID: "remote-workspace")
        XCTAssertEqual(store.courses.count, 2)
        XCTAssertEqual(store.courses.first(where: { $0.workspaceID == "local-workspace" }), local)
        let effective = try XCTUnwrap(store.courses.first(where: { $0.workspaceID == "remote-workspace" }))
        XCTAssertEqual(effective.id, "course-remote-workspace")
        XCTAssertEqual(store.selectionDiscussions.first(where: { $0.id == discussion.id })?.courseID, effective.id)
        store.exportCourseContinuation(workspaceID: "remote-workspace")
        let exported = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: remoteDirectory))
        XCTAssertEqual(exported.course?.id, "swift")
        XCTAssertEqual(exported.discussions.first?.courseID, "swift")
    }

    private func message(_ text: String) -> CodexCourseTranscriptMessage {
        CodexCourseTranscriptMessage(role: .agent, text: text)
    }

    private func course(id: String, workspaceID: String) -> LearningCourse {
        LearningCourse(id: id, title: "Swift", subtitle: "Learn", accentHex: "00FF9C", progress: 0,
                       lessonCount: 1, duration: "1h", status: .ready, workspaceID: workspaceID,
                       agentRuntimeKind: .codex)
    }
}
