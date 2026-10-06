import XCTest
@testable import Litter

private actor AssessmentReviewBarrier {
    private var continuation: CheckedContinuation<CourseAssessmentReview, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> CourseAssessmentReview {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(_ review: CourseAssessmentReview) {
        continuation?.resume(returning: review)
        continuation = nil
    }

    func releaseFailure(_ error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
final class CourseAssessmentAttemptStoreTests: XCTestCase {
    func testDraftAndSelectedOptionResumeAfterRelaunch() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let first = store(fileURL)
        _ = try first.start(definition)
        try first.updateDraft(definition, selectedOptionID: "gradient", answerText: "My note")

        let restored = store(fileURL)
        let attempt = try XCTUnwrap(restored.latestAttempt(for: definition))
        XCTAssertEqual(attempt.selectedOptionID, "gradient")
        XCTAssertEqual(attempt.answerText, "My note")
        XCTAssertEqual(attempt.phase, .draft)
        XCTAssertTrue(attempt.submissionID.isEmpty)
        XCTAssertNil(restored.lastPersistenceError)
    }

    func testFreeTextDraftIsBoundedAndResumeKeepsExactText() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .freeText)
        let first = store(fileURL)
        _ = try first.start(definition)
        try first.updateDraft(
            definition,
            selectedOptionID: nil,
            answerText: String(repeating: "a", count: 4_500)
        )

        let restored = store(fileURL)
        XCTAssertEqual(restored.latestAttempt(for: definition)?.answerText.count, 4_000)
    }

    func testChangedFingerprintStartsFreshAndRetainsEarlierQuestion() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let old = question(fingerprint: "old-question")
        let revised = question(fingerprint: "revised-question", prompt: "A revised question")
        let attempts = store(fileURL)
        let original = try attempts.start(old)
        try attempts.updateDraft(old, selectedOptionID: "gradient", answerText: "")

        XCTAssertNil(attempts.latestAttempt(for: revised))
        let replacement = try attempts.start(revised)
        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertNil(replacement.selectedOptionID)
        XCTAssertEqual(replacement.questionPrompt, "A revised question")
        XCTAssertEqual(attempts.history(for: revised).count, 2)
        XCTAssertEqual(attempts.history(for: revised).first?.fingerprint, "old-question")

        let restored = store(fileURL)
        XCTAssertEqual(restored.latestAttempt(for: old)?.selectedOptionID, "gradient")
        XCTAssertEqual(restored.latestAttempt(for: revised)?.id, replacement.id)
    }

    func testCourseAndPageIdentitiesDoNotShareAnswers() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let pageOne = store(fileURL, courseID: "course-one", pageID: "page-one")
        _ = try pageOne.start(definition)
        try pageOne.updateDraft(definition, selectedOptionID: "gradient", answerText: "")

        let pageTwo = store(fileURL, courseID: "course-one", pageID: "page-two")
        XCTAssertNil(pageTwo.latestAttempt(for: definition))
        _ = try pageTwo.start(definition)
        try pageTwo.updateDraft(definition, selectedOptionID: "dna", answerText: "")

        let otherCourse = store(fileURL, courseID: "course-two", pageID: "page-one")
        XCTAssertNil(otherCourse.latestAttempt(for: definition))
        _ = try otherCourse.start(definition)
        XCTAssertEqual(store(fileURL, courseID: "course-one", pageID: "page-one")
            .latestAttempt(for: definition)?.selectedOptionID, "gradient")
        XCTAssertEqual(store(fileURL, courseID: "course-one", pageID: "page-two")
            .latestAttempt(for: definition)?.selectedOptionID, "dna")
    }

    func testSubmissionIdentityIsSavedBeforeDispatchAndInterruptedReviewCanRetry() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let submitted = try attempts.beginReview(definition)
        XCTAssertNotNil(UUID(uuidString: submitted.submissionID))

        let restored = store(fileURL)
        let interrupted = try XCTUnwrap(restored.latestAttempt(for: definition))
        XCTAssertEqual(interrupted.phase, .failed)
        XCTAssertEqual(interrupted.submissionID, submitted.submissionID)
        XCTAssertEqual(interrupted.selectedOptionID, "gradient")
        XCTAssertNotNil(interrupted.reviewError)
        XCTAssertEqual(try restored.beginReview(definition).submissionID, submitted.submissionID)
    }

    func testDuplicateSubmissionsAreRejectedAndMatchingCompletionIsIdempotent() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let submitted = try attempts.beginReview(definition)
        XCTAssertThrowsError(try attempts.beginReview(definition))
        XCTAssertThrowsError(try attempts.updateDraft(definition, selectedOptionID: "dna", answerText: ""))

        let result = review(for: submitted)
        try attempts.completeReview(result, for: submitted)
        try attempts.completeReview(result, for: submitted)
        XCTAssertEqual(attempts.history(for: definition).count, 1)
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.review?.feedback, result.feedback)
        XCTAssertThrowsError(try attempts.beginReview(definition))
    }

    func testWrongSubmissionReviewCannotChangeTheSavedAnswer() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let submitted = try attempts.beginReview(definition)
        let wrong = CourseAssessmentReview(
            submissionId: UUID().uuidString,
            assessmentId: definition.id,
            outcome: .understood,
            feedback: "This response must not be attached.",
            needsDiscussion: false,
            openingQuestion: nil
        )
        XCTAssertThrowsError(try attempts.completeReview(wrong, for: submitted))
        XCTAssertNil(attempts.latestAttempt(for: definition)?.review)
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.phase, .reviewing)
    }

    func testEditingFailedAnswerCreatesNewSubmissionButUnchangedRetryDoesNot() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "dna", answerText: "")
        let original = try attempts.beginReview(definition)
        try attempts.failReview("Offline", for: original)
        let retried = try attempts.beginReview(definition)
        XCTAssertEqual(retried.submissionID, original.submissionID)
        try attempts.failReview("Still offline", for: retried)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let edited = try attempts.beginReview(definition)
        XCTAssertNotEqual(edited.submissionID, original.submissionID)
    }

    func testTryAgainKeepsFeedbackInHistoryWithoutRevealingItInNewAttempt() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let submitted = try attempts.beginReview(definition)
        try attempts.completeReview(review(for: submitted), for: submitted)
        let next = try attempts.retry(definition)
        XCTAssertNil(next.review)
        XCTAssertNil(next.selectedOptionID)
        XCTAssertEqual(next.phase, .draft)
        XCTAssertEqual(attempts.history(for: definition).first?.review?.outcome, .understood)
        XCTAssertEqual(attempts.history(for: definition).count, 2)
    }

    func testUnreadableArchiveIsVisibleAndNeverReplacedWithEmptyPractice() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let corrupt = Data("keep this unreadable saved file".utf8)
        try corrupt.write(to: fileURL)
        let attempts = store(fileURL)
        XCTAssertNotNil(attempts.loadFailure)
        XCTAssertNotNil(attempts.lastPersistenceError)
        XCTAssertThrowsError(try attempts.start(question()))
        XCTAssertThrowsError(try attempts.retrySaving())
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    func testPersistenceFailureBlocksDispatchAndRetainsTypedDraftForRetrySaving() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .freeText)
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try blockWrites(fileURL)
        XCTAssertThrowsError(try attempts.updateDraft(
            definition,
            selectedOptionID: nil,
            answerText: "Oxygen accepts electrons at the end of the chain."
        ))
        XCTAssertTrue(attempts.latestAttempt(for: definition)?.answerText.contains("Oxygen") == true)
        XCTAssertNotNil(attempts.lastPersistenceError)
        XCTAssertThrowsError(try attempts.beginReview(definition))
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.phase, .draft)
        try unblockWrites(fileURL)
        try attempts.retrySaving()
        XCTAssertNil(attempts.lastPersistenceError)
        XCTAssertEqual(store(fileURL).latestAttempt(for: definition)?.answerText,
            attempts.latestAttempt(for: definition)?.answerText)
    }

    func testArrivedReviewRemainsInMemoryWhenSavingFails() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        let submitted = try attempts.beginReview(definition)
        try blockWrites(fileURL)
        XCTAssertThrowsError(try attempts.completeReview(review(for: submitted), for: submitted))
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.phase, .reviewed)
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.review?.feedback, "You connected the gradient to ATP production.")
        try unblockWrites(fileURL)
        try attempts.retrySaving()
        XCTAssertEqual(store(fileURL).latestAttempt(for: definition)?.phase, .reviewed)
    }

    func testDiscussionStartsWithoutFabricatingAnAnswerOrClaimingUnderstanding() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let opened = try attempts.start(definition)
        try attempts.markDiscussionOpened(for: opened)
        XCTAssertThrowsError(try attempts.beginReview(definition))
        let restored = try XCTUnwrap(store(fileURL).latestAttempt(for: definition))
        XCTAssertTrue(restored.discussionOpened)
        XCTAssertTrue(restored.submissionID.isEmpty)
        XCTAssertTrue(restored.answerText.isEmpty)
        XCTAssertNil(restored.review)
    }

    func testDiscussionPresentationAndAcceptedOpeningArePersistedIndependently() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let opened = try attempts.start(definition)
        try attempts.markDiscussionOpened(for: opened)
        let presented = try XCTUnwrap(store(fileURL).latestAttempt(for: definition))
        XCTAssertTrue(presented.discussionOpened)
        XCTAssertFalse(presented.discussionStarted)
        try attempts.markDiscussionStarted(for: opened)
        let accepted = try XCTUnwrap(store(fileURL).latestAttempt(for: definition))
        XCTAssertTrue(accepted.discussionOpened)
        XCTAssertTrue(accepted.discussionStarted)

        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var rows = try XCTUnwrap(archive["attempts"] as? [[String: Any]])
        rows[0].removeValue(forKey: "discussionStarted")
        archive["attempts"] = rows
        try JSONSerialization.data(withJSONObject: archive).write(to: fileURL, options: .atomic)
        let legacy = store(fileURL)
        XCTAssertFalse(try XCTUnwrap(legacy.latestAttempt(for: definition)).discussionStarted)
        XCTAssertNil(legacy.loadFailure)
    }

    func testBoundedHistoryKeepsTheMostRecentAttempts() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        for _ in 0..<30 { _ = try attempts.retry(definition) }
        XCTAssertEqual(attempts.history(for: definition).count, 12)
        XCTAssertEqual(store(fileURL).history(for: definition).count, 12)
    }

    func testStoreOwnsReviewUntilCompletionAfterTheViewReleasesIt() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let barrier = AssessmentReviewBarrier()
        var retainedStore: CourseAssessmentAttemptStore? = store(fileURL)
        weak var weakStore = retainedStore
        _ = try retainedStore?.start(definition)
        try retainedStore?.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        try retainedStore?.submitForReview(definition, review: { _, _ in
            try await barrier.wait()
        }, didRequestDiscussion: { _, _, _ in XCTFail("This review does not request a discussion") })
        await barrier.waitUntilStarted()
        let submitted = try XCTUnwrap(retainedStore?.latestAttempt(for: definition))
        retainedStore = nil
        XCTAssertNotNil(weakStore)
        await barrier.release(review(for: submitted))
        await waitUntil { weakStore == nil }
        XCTAssertEqual(store(fileURL).latestAttempt(for: definition)?.phase, .reviewed)
    }

    func testAutomaticDiscussionIsPersistedAndNotRepeatedOnRelaunch() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .freeText)
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: nil, answerText: "I think oxygen makes ATP directly.")
        var openingQuestions: [String?] = []
        try attempts.submitForReview(definition, review: { _, submitted in
            self.review(for: submitted, needsDiscussion: true)
        }, didRequestDiscussion: { _, _, question in openingQuestions.append(question) })
        await waitUntil { attempts.latestAttempt(for: definition)?.phase == .reviewed }
        XCTAssertEqual(openingQuestions.count, 1)
        XCTAssertEqual(openingQuestions.compactMap { $0 }, ["What does the proton gradient allow ATP synthase to do?"])
        XCTAssertTrue(attempts.latestAttempt(for: definition)?.discussionOpened == true)
        let restored = store(fileURL)
        restored.prepare(definition)
        XCTAssertTrue(restored.latestAttempt(for: definition)?.discussionOpened == true)
        XCTAssertEqual(openingQuestions.count, 1)
    }

    func testOldRevisionReviewIsSavedWithoutAutomaticallyOpeningNewQuestionDiscussion() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let old = question(fingerprint: "old")
        let revised = question(fingerprint: "new")
        let attempts = store(fileURL)
        let barrier = AssessmentReviewBarrier()
        _ = try attempts.start(old)
        try attempts.updateDraft(old, selectedOptionID: "gradient", answerText: "")
        var discussionCount = 0
        try attempts.submitForReview(old, review: { _, _ in try await barrier.wait() },
            didRequestDiscussion: { _, _, _ in discussionCount += 1 })
        await barrier.waitUntilStarted()
        let submitted = try XCTUnwrap(attempts.latestAttempt(for: old))
        _ = try attempts.start(revised)
        await barrier.release(review(for: submitted, needsDiscussion: true))
        await waitUntil { attempts.latestAttempt(for: old)?.phase == .reviewed }
        XCTAssertEqual(discussionCount, 0)
        XCTAssertEqual(attempts.latestAttempt(for: revised)?.phase, .draft)
        XCTAssertNil(attempts.latestAttempt(for: revised)?.review)
        XCTAssertNotNil(store(fileURL).latestAttempt(for: old)?.review)
    }

    func testProviderFailureKeepsFreeTextAnswerRetryableWithoutInventingAGrade() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .freeText)
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        try attempts.updateDraft(definition, selectedOptionID: nil, answerText: "ATP synthase uses proton flow.")
        try attempts.submitForReview(definition, review: { _, _ in
            throw NSError(domain: "OfflineAssessmentFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The tutor is offline."])
        }, didRequestDiscussion: { _, _, _ in XCTFail("An offline review must not open a discussion") })
        await waitUntil { attempts.latestAttempt(for: definition)?.phase == .failed }
        let failed = try XCTUnwrap(attempts.latestAttempt(for: definition))
        XCTAssertEqual(failed.answerText, "ATP synthase uses proton flow.")
        XCTAssertEqual(failed.reviewError, "The tutor is offline.")
        XCTAssertNil(failed.review)
        XCTAssertNotNil(UUID(uuidString: failed.submissionID))
        XCTAssertEqual(store(fileURL).latestAttempt(for: definition)?.phase, .failed)
    }

    func testInvalidationBeforeDispatchStopsProviderAndRejectsFurtherWrites() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        var retainedStore: CourseAssessmentAttemptStore? = store(fileURL)
        weak var weakStore = retainedStore
        _ = try retainedStore?.start(definition)
        try retainedStore?.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        var providerCalls = 0
        try retainedStore?.submitForReview(definition, review: { _, submitted in
            providerCalls += 1
            return self.review(for: submitted)
        }, didRequestDiscussion: { _, _, _ in XCTFail("A deleted course cannot open a discussion") })
        let submitted = try XCTUnwrap(retainedStore?.latestAttempt(for: definition))
        retainedStore?.invalidate()
        XCTAssertTrue(retainedStore?.isInvalidated == true)
        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        XCTAssertThrowsError(try retainedStore?.start(definition))
        XCTAssertThrowsError(try retainedStore?.retry(definition))
        XCTAssertThrowsError(try retainedStore?.beginReview(definition))
        XCTAssertThrowsError(try retainedStore?.updateDraft(definition, selectedOptionID: "dna", answerText: ""))
        XCTAssertThrowsError(try retainedStore?.completeReview(review(for: submitted), for: submitted))
        XCTAssertThrowsError(try retainedStore?.failReview("Late failure", for: submitted))
        XCTAssertThrowsError(try retainedStore?.markDiscussionStarted(for: submitted))
        XCTAssertThrowsError(try retainedStore?.markDiscussionOpened(for: submitted))
        XCTAssertThrowsError(try retainedStore?.discussionInstruction(for: submitted, creating: "Late opening"))
        XCTAssertThrowsError(try retainedStore?.retrySaving())
        retainedStore?.retryLoading()
        XCTAssertTrue(retainedStore?.isInvalidated == true)
        retainedStore = nil
        await waitUntil { weakStore == nil }
        XCTAssertEqual(providerCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func testCancellationIgnoringReviewCannotRecreateDeletedCourseDirectory() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let barrier = AssessmentReviewBarrier()
        var retainedStore: CourseAssessmentAttemptStore? = store(fileURL)
        weak var weakStore = retainedStore
        _ = try retainedStore?.start(definition)
        try retainedStore?.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        var observedCancellation = false
        var discussionCount = 0
        try retainedStore?.submitForReview(definition, review: { _, _ in
            let result = try await barrier.wait()
            observedCancellation = Task.isCancelled
            return result
        }, didRequestDiscussion: { _, _, _ in discussionCount += 1 })
        await barrier.waitUntilStarted()
        let submitted = try XCTUnwrap(retainedStore?.latestAttempt(for: definition))
        retainedStore?.invalidate()
        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        retainedStore = nil
        XCTAssertNotNil(weakStore)
        // This fixture returns a result even though its task has been canceled.
        await barrier.release(review(for: submitted, needsDiscussion: true))
        await waitUntil { weakStore == nil }
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(discussionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func testLateProviderFailureAfterInvalidationCannotRecreateDeletedDirectory() async throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question()
        let barrier = AssessmentReviewBarrier()
        var retainedStore: CourseAssessmentAttemptStore? = store(fileURL)
        weak var weakStore = retainedStore
        _ = try retainedStore?.start(definition)
        try retainedStore?.updateDraft(definition, selectedOptionID: "gradient", answerText: "")
        try retainedStore?.submitForReview(definition, review: { _, _ in
            try await barrier.wait()
        }, didRequestDiscussion: { _, _, _ in XCTFail("A deleted course cannot open a discussion") })
        await barrier.waitUntilStarted()
        retainedStore?.invalidate()
        try FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        retainedStore = nil
        await barrier.releaseFailure(NSError(domain: "DeletedCourseReviewFixture", code: 1))
        await waitUntil { weakStore == nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
    }

    func testDiscussionInstructionIsFrozenAcrossContextEditsAndRelaunch() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let original = try attempts.start(definition)
        XCTAssertEqual(try attempts.discussionInstruction(for: original, creating: "The original opening and page context."),
            "The original opening and page context.")
        XCTAssertEqual(try attempts.discussionInstruction(for: original, creating: "A changed page context must not replace it."),
            "The original opening and page context.")

        let restored = store(fileURL)
        restored.prepare(definition)
        let saved = try XCTUnwrap(restored.latestAttempt(for: definition))
        XCTAssertEqual(saved.discussionInstruction, "The original opening and page context.")
        XCTAssertEqual(try restored.discussionInstruction(for: saved, creating: "Another context after restart."),
            "The original opening and page context.")
    }

    func testNewRetryGetsItsOwnInstructionAndOldAttemptCannotReplaceIt() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let original = try attempts.start(definition)
        _ = try attempts.discussionInstruction(for: original, creating: "First attempt opening.")
        let retried = try attempts.retry(definition)
        XCTAssertNotEqual(retried.id, original.id)
        XCTAssertThrowsError(try attempts.discussionInstruction(for: original, creating: "Stale opening."))
        XCTAssertEqual(try attempts.discussionInstruction(for: retried, creating: "New attempt opening."),
            "New attempt opening.")
        XCTAssertEqual(attempts.history(for: definition).first?.discussionInstruction, "First attempt opening.")
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.discussionInstruction, "New attempt opening.")
    }

    func testFrozenInstructionRejectsOtherPageCourseAndChangedQuestionFingerprint() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let original = try attempts.start(definition)
        _ = try attempts.discussionInstruction(for: original, creating: "Page-one opening.")
        let otherPage = store(fileURL, pageID: "page-two")
        otherPage.prepare(definition)
        XCTAssertThrowsError(try otherPage.discussionInstruction(for: original, creating: "Wrong page."))
        let otherCourse = store(fileURL, courseID: "course-two")
        otherCourse.prepare(definition)
        XCTAssertThrowsError(try otherCourse.discussionInstruction(for: original, creating: "Wrong course."))

        let revised = question(kind: .discussion, fingerprint: "revised-question")
        attempts.prepare(revised)
        XCTAssertThrowsError(try attempts.discussionInstruction(for: original, creating: "Outdated question."))
        XCTAssertEqual(attempts.latestAttempt(for: definition)?.discussionInstruction, "Page-one opening.")
    }

    func testLegacyMissingDiscussionInstructionDecodesAsNil() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        _ = try attempts.start(definition)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        var rows = try XCTUnwrap(archive["attempts"] as? [[String: Any]])
        rows[0].removeValue(forKey: "discussionInstruction")
        archive["attempts"] = rows
        try JSONSerialization.data(withJSONObject: archive).write(to: fileURL, options: .atomic)
        let restored = store(fileURL)
        XCTAssertNil(restored.loadFailure)
        XCTAssertNil(try XCTUnwrap(restored.latestAttempt(for: definition)).discussionInstruction)
    }

    func testInstructionPersistenceFailureDoesNotPretendTheOpeningWasFrozen() throws {
        let fileURL = try temporaryFileURL()
        defer { removeFixture(fileURL) }
        let definition = question(kind: .discussion)
        let attempts = store(fileURL)
        let original = try attempts.start(definition)
        try blockWrites(fileURL)
        XCTAssertThrowsError(try attempts.discussionInstruction(for: original, creating: "Unsaved opening."))
        XCTAssertNil(attempts.latestAttempt(for: definition)?.discussionInstruction)
        try unblockWrites(fileURL)
        XCTAssertEqual(try attempts.discussionInstruction(for: original, creating: "Saved opening."), "Saved opening.")
        XCTAssertEqual(store(fileURL).latestAttempt(for: definition)?.discussionInstruction, "Saved opening.")
    }

    private func question(
        kind: CourseAssessmentKind = .multipleChoice,
        fingerprint: String = "question-v1",
        prompt: String = "What links electron transport to ATP production?"
    ) -> CourseAssessmentDefinition {
        CourseAssessmentDefinition(
            version: 1,
            id: "energy-link",
            title: "Follow the energy",
            kind: kind,
            prompt: prompt,
            options: kind == .multipleChoice ? [
                CourseAssessmentOption(id: "gradient", text: "The proton gradient"),
                CourseAssessmentOption(id: "dna", text: "DNA storage"),
            ] : [],
            answer: kind == .multipleChoice ? CourseAssessmentAnswer(
                optionId: "gradient",
                explanation: "ATP synthase uses proton flow down the gradient."
            ) : nil,
            rubric: kind == .multipleChoice ? [] : ["Connect proton flow to ATP synthase."],
            openingPrompt: kind == .discussion ? "What happens if the gradient collapses?" : nil,
            fingerprint: fingerprint
        )
    }

    private func review(
        for attempt: CourseAssessmentAttempt,
        needsDiscussion: Bool = false
    ) -> CourseAssessmentReview {
        CourseAssessmentReview(
            submissionId: attempt.submissionID,
            assessmentId: attempt.assessmentID,
            outcome: needsDiscussion ? .needsReview : .understood,
            feedback: "You connected the gradient to ATP production.",
            needsDiscussion: needsDiscussion,
            openingQuestion: needsDiscussion ? "What does the proton gradient allow ATP synthase to do?" : nil
        )
    }

    private func store(
        _ fileURL: URL,
        courseID: String = "course-one",
        pageID: String = "page-one"
    ) -> CourseAssessmentAttemptStore {
        CourseAssessmentAttemptStore(fileURL: fileURL, courseID: courseID, pageID: pageID)
    }

    private func temporaryFileURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learnfold-assessment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("attempts.json")
    }

    private func removeFixture(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func blockWrites(_ fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try Data("storage unavailable".utf8).write(to: directory)
    }

    private func unblockWrites(_ fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the assessment review")
    }
}
