import XCTest
@testable import Litter

@MainActor
final class CourseAssessmentStoreIntegrationTests: XCTestCase {
    func testReopeningPageKeepsItsActiveReviewAndAuthoritativeStore() throws {
        try withFixture { store, course in
            let definition = try question()
            let first = try store.assessmentAttemptStore(for: course, pageID: "lesson-one")
            first.prepare(definition)
            _ = try first.start(definition)
            try first.updateDraft(definition, selectedOptionID: nil, answerText: "ATP powers pumps")
            let submission = try first.beginReview(definition)

            let reopened = try store.assessmentAttemptStore(for: course, pageID: "lesson-one")
            XCTAssertTrue(first === reopened)
            XCTAssertEqual(reopened.latestAttempt(for: definition)?.phase, .reviewing)
            XCTAssertEqual(reopened.latestAttempt(for: definition)?.submissionID, submission.submissionID)
            XCTAssertNil(reopened.latestAttempt(for: definition)?.reviewError)
        }
    }

    func testSameQuestionIDOnAnotherPageHasIndependentAnswers() throws {
        try withFixture { store, course in
            let definition = try question()
            let first = try store.assessmentAttemptStore(for: course, pageID: "lesson-one")
            let second = try store.assessmentAttemptStore(for: course, pageID: "lesson-two")
            first.prepare(definition)
            second.prepare(definition)
            _ = try first.start(definition)
            try first.updateDraft(definition, selectedOptionID: nil, answerText: "ATP powers pumps")
            XCTAssertFalse(first === second)
            XCTAssertNil(second.latestAttempt(for: definition))
        }
    }

    func testDiscardingUnbuiltWorkspaceInvalidatesCachedAssessmentStore() throws {
        try withFixture { store, course in
            let definition = try question()
            let attempts = try store.assessmentAttemptStore(for: course, pageID: "lesson-one")
            attempts.prepare(definition)
            _ = try attempts.start(definition)
            let fileURL = try store.assessmentAttemptsURL(for: course, pageID: "lesson-one")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            store.beginNewCourse()
            XCTAssertTrue(attempts.isInvalidated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertThrowsError(try attempts.updateDraft(definition, selectedOptionID: nil, answerText: "Late answer"))
        }
    }

    private func question() throws -> CourseAssessmentDefinition {
        try XCTUnwrap(parseCourseAssessmentBlock(body: """
        {"version":1,"id":"energy-explain","kind":"free_text","prompt":"Why do pumps need ATP?","rubric":["ATP supplies energy"]}
        """).assessment)
    }

    private func withFixture(_ body: (CourseExperienceStore, LearningCourse) throws -> Void) throws {
        let suite = "AssessmentIntegration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: root)
        let course = LearningCourse(
            id: "practice-course", title: "Practice", subtitle: "", accentHex: "0088FF",
            progress: 0, lessonCount: 2, duration: "5 min", status: .inProgress,
            workspaceID: store.nativeCourseDirectory().lastPathComponent
        )
        try body(store, course)
    }
}
