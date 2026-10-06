import Foundation
import Observation

/// An app-owned learner response. Question validation and grading remain in Rust.
struct CourseAssessmentAttempt: Codable, Equatable, Identifiable, Sendable {
    enum Phase: String, Codable, Sendable {
        case draft
        case reviewing
        case reviewed
        case failed
    }

    struct Option: Codable, Equatable, Sendable {
        let id: String
        let text: String
    }

    struct Review: Codable, Equatable, Sendable {
        let submissionID: String
        let assessmentID: String
        private let understood: Bool
        let feedback: String
        let needsDiscussion: Bool
        let openingQuestion: String?

        var outcome: CourseAssessmentReviewOutcome {
            understood ? .understood : .needsReview
        }

        init(_ review: CourseAssessmentReview) {
            submissionID = review.submissionId
            assessmentID = review.assessmentId
            understood = review.outcome == .understood
            feedback = review.feedback
            needsDiscussion = review.needsDiscussion
            openingQuestion = review.openingQuestion
        }
    }

    let id: UUID
    let courseID: String
    let pageID: String
    let assessmentID: String
    let fingerprint: String
    let questionTitle: String
    let questionPrompt: String
    let options: [Option]
    let createdAt: Date
    var updatedAt: Date
    /// Empty for a draft. Assigned and persisted before the first review dispatch.
    var submissionID: String
    var selectedOptionID: String?
    var answerText: String
    var phase: Phase
    var review: Review?
    var reviewError: String?
    var discussionOpened: Bool
    var discussionStarted: Bool = false
    var discussionInstruction: String? = nil
}

extension CourseAssessmentAttempt {
    private enum CodingKeys: String, CodingKey {
        case id, courseID, pageID, assessmentID, fingerprint, questionTitle, questionPrompt
        case options, createdAt, updatedAt, submissionID, selectedOptionID, answerText
        case phase, review, reviewError, discussionOpened, discussionStarted, discussionInstruction
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        courseID = try values.decode(String.self, forKey: .courseID)
        pageID = try values.decode(String.self, forKey: .pageID)
        assessmentID = try values.decode(String.self, forKey: .assessmentID)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        questionTitle = try values.decode(String.self, forKey: .questionTitle)
        questionPrompt = try values.decode(String.self, forKey: .questionPrompt)
        options = try values.decode([Option].self, forKey: .options)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        submissionID = try values.decode(String.self, forKey: .submissionID)
        selectedOptionID = try values.decodeIfPresent(String.self, forKey: .selectedOptionID)
        answerText = try values.decode(String.self, forKey: .answerText)
        phase = try values.decode(Phase.self, forKey: .phase)
        review = try values.decodeIfPresent(Review.self, forKey: .review)
        reviewError = try values.decodeIfPresent(String.self, forKey: .reviewError)
        discussionOpened = try values.decode(Bool.self, forKey: .discussionOpened)
        discussionStarted = try values.decodeIfPresent(Bool.self, forKey: .discussionStarted) ?? false
        discussionInstruction = try values.decodeIfPresent(String.self, forKey: .discussionInstruction)
    }
}

@MainActor
@Observable
final class CourseAssessmentAttemptStore {
    enum StoreError: LocalizedError {
        case unreadableStore(String)
        case unsupportedVersion(Int)
        case invalidStoredIdentity
        case notStarted
        case noAnswer
        case reviewInProgress
        case alreadyReviewed
        case staleSubmission
        case mismatchedReview
        case invalidated

        var errorDescription: String? {
            switch self {
            case .unreadableStore(let detail):
                return "Saved practice could not be read. Your saved file has been kept. \(detail)"
            case .unsupportedVersion:
                return "This version of Learnfold cannot read the saved practice file. Your saved file has been kept."
            case .invalidStoredIdentity:
                return "The saved practice file contains conflicting attempts. Your saved file has been kept."
            case .notStarted:
                return "Start this check before entering an answer."
            case .noAnswer:
                return "Choose an answer or write a response before submitting."
            case .reviewInProgress:
                return "Your answer is already being reviewed."
            case .alreadyReviewed:
                return "This answer has already been reviewed. Choose Try again for a new attempt."
            case .staleSubmission:
                return "This review does not match the saved attempt."
            case .mismatchedReview:
                return "The review did not identify this question and answer. Your response is still saved."
            case .invalidated:
                return "This course is no longer available. Its practice cannot be updated."
            }
        }
    }

    private struct Archive: Codable {
        let version: Int
        var attempts: [CourseAssessmentAttempt]
    }

    static let maximumAnswerLength = 4_000
    private static let maximumHistoryPerQuestion = 12
    private static let maximumAttempts = 200

    let courseID: String
    let pageID: String
    private(set) var lastPersistenceError: String?
    private(set) var loadFailure: String?
    private(set) var isInvalidated = false
    private var savedAttempts: [CourseAssessmentAttempt] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let onMutation: @MainActor () -> Void
    @ObservationIgnored private var activeFingerprints: [String: String] = [:]
    @ObservationIgnored private var reviewTasks: [UUID: Task<Void, Never>] = [:]

    init(fileURL: URL, courseID: String, pageID: String, onMutation: @escaping @MainActor () -> Void = {}) {
        self.fileURL = fileURL
        self.onMutation = onMutation
        self.courseID = courseID
        self.pageID = pageID
        retryLoading()
    }

    func prepare(_ definition: CourseAssessmentDefinition) {
        guard !isInvalidated else { return }
        activeFingerprints[definition.id] = definition.fingerprint
    }

    func prepare(_ definitions: [CourseAssessmentDefinition]) {
        guard !isInvalidated else { return }
        activeFingerprints = [:]
        for definition in definitions {
            activeFingerprints[definition.id] = definition.fingerprint
        }
    }

    func latestAttempt(for definition: CourseAssessmentDefinition) -> CourseAssessmentAttempt? {
        savedAttempts.last {
            belongsToPage($0)
                && $0.assessmentID == definition.id
                && $0.fingerprint == definition.fingerprint
        }
    }

    /// Includes earlier revisions of the same authored question.
    func history(for definition: CourseAssessmentDefinition) -> [CourseAssessmentAttempt] {
        savedAttempts.filter { belongsToPage($0) && $0.assessmentID == definition.id }
    }

    /// Permanently retires this cached store before its course directory is removed.
    /// A provider may ignore cancellation; the active guard also fences its late result.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        reviewTasks.values.forEach { $0.cancel() }
        reviewTasks.removeAll()
        activeFingerprints.removeAll()
    }

    @discardableResult
    func start(_ definition: CourseAssessmentDefinition) throws -> CourseAssessmentAttempt {
        try requireActive()
        prepare(definition)
        if let existing = latestAttempt(for: definition) { return existing }
        return try makeDraft(definition)
    }

    @discardableResult
    func retry(_ definition: CourseAssessmentDefinition) throws -> CourseAssessmentAttempt {
        try requireActive()
        guard latestAttempt(for: definition)?.phase != .reviewing else {
            throw StoreError.reviewInProgress
        }
        prepare(definition)
        return try makeDraft(definition)
    }

    func updateDraft(
        _ definition: CourseAssessmentDefinition,
        selectedOptionID: String?,
        answerText: String
    ) throws {
        try requireActive()
        guard let attempt = latestAttempt(for: definition) else { throw StoreError.notStarted }
        guard attempt.phase != .reviewing else { throw StoreError.reviewInProgress }
        guard attempt.phase != .reviewed else { throw StoreError.alreadyReviewed }
        let boundedAnswer = String(answerText.prefix(Self.maximumAnswerLength))
        guard selectedOptionID != attempt.selectedOptionID || boundedAnswer != attempt.answerText else {
            return
        }
        var updated = attempt
        updated.selectedOptionID = selectedOptionID
        updated.answerText = boundedAnswer
        // An edited answer is a new submission, rather than a retry of an earlier request.
        updated.submissionID = ""
        updated.phase = .draft
        updated.reviewError = nil
        updated.updatedAt = Date()
        // Retain typed text in memory even if disk storage becomes unavailable.
        try replace(updated, keepInMemoryOnFailure: true)
    }

    @discardableResult
    func beginReview(_ definition: CourseAssessmentDefinition) throws -> CourseAssessmentAttempt {
        try requireActive()
        guard var attempt = latestAttempt(for: definition) else { throw StoreError.notStarted }
        guard attempt.phase != .reviewing else { throw StoreError.reviewInProgress }
        guard attempt.phase != .reviewed else { throw StoreError.alreadyReviewed }
        let hasAnswer: Bool
        switch definition.kind {
        case .multipleChoice:
            hasAnswer = definition.options.contains { $0.id == attempt.selectedOptionID }
        case .freeText:
            hasAnswer = !attempt.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .discussion:
            hasAnswer = false
        }
        guard hasAnswer else { throw StoreError.noAnswer }
        if attempt.submissionID.isEmpty { attempt.submissionID = UUID().uuidString.lowercased() }
        attempt.phase = .reviewing
        attempt.reviewError = nil
        attempt.updatedAt = Date()
        // Dispatch is allowed only after the reviewing identity reaches disk.
        try replace(attempt)
        return attempt
    }

    func completeReview(
        _ review: CourseAssessmentReview,
        for submitted: CourseAssessmentAttempt
    ) throws {
        try requireActive()
        guard review.submissionId == submitted.submissionID,
              review.assessmentId == submitted.assessmentID else {
            throw StoreError.mismatchedReview
        }
        guard var attempt = savedAttempts.first(where: { $0.id == submitted.id }),
              belongsToPage(attempt),
              attempt.submissionID == submitted.submissionID,
              attempt.fingerprint == submitted.fingerprint else {
            throw StoreError.staleSubmission
        }
        let storedReview = CourseAssessmentAttempt.Review(review)
        if attempt.phase == .reviewed, attempt.review == storedReview { return }
        guard attempt.phase == .reviewing else { throw StoreError.staleSubmission }
        attempt.phase = .reviewed
        attempt.review = storedReview
        attempt.reviewError = nil
        attempt.updatedAt = Date()
        // An arrived response remains visible if persisting it fails; Retry saving can commit it.
        try replace(attempt, keepInMemoryOnFailure: true)
    }

    func failReview(_ message: String, for submitted: CourseAssessmentAttempt) throws {
        try requireActive()
        guard var attempt = savedAttempts.first(where: { $0.id == submitted.id }),
              belongsToPage(attempt),
              attempt.submissionID == submitted.submissionID,
              attempt.phase == .reviewing else { throw StoreError.staleSubmission }
        attempt.phase = .failed
        attempt.reviewError = message
        attempt.updatedAt = Date()
        try replace(attempt, keepInMemoryOnFailure: true)
    }

    func markDiscussionOpened(for original: CourseAssessmentAttempt) throws {
        try requireActive()
        guard var attempt = savedAttempts.first(where: { $0.id == original.id }),
              belongsToPage(attempt) else { throw StoreError.staleSubmission }
        if attempt.discussionOpened { return }
        attempt.discussionOpened = true
        attempt.updatedAt = Date()
        try replace(attempt)
    }

    func markDiscussionStarted(for original: CourseAssessmentAttempt) throws {
        try requireActive()
        guard var attempt = savedAttempts.first(where: { $0.id == original.id }),
              belongsToPage(attempt) else { throw StoreError.staleSubmission }
        if attempt.discussionStarted { return }
        attempt.discussionStarted = true
        attempt.updatedAt = Date()
        try replace(attempt)
    }

    /// The first opening instruction is immutable for this exact learner attempt.
    /// Subsequent page or context edits cannot turn reopening into a second opening request.
    func discussionInstruction(
        for original: CourseAssessmentAttempt,
        creating instruction: String
    ) throws -> String {
        try requireActive()
        guard var attempt = savedAttempts.first(where: { $0.id == original.id }),
              belongsToPage(attempt),
              original.courseID == attempt.courseID,
              original.pageID == attempt.pageID,
              original.assessmentID == attempt.assessmentID,
              original.fingerprint == attempt.fingerprint,
              activeFingerprints[attempt.assessmentID] == attempt.fingerprint,
              savedAttempts.last(where: {
                  belongsToPage($0) && $0.assessmentID == attempt.assessmentID
                      && $0.fingerprint == attempt.fingerprint
              })?.id == attempt.id else {
            throw StoreError.staleSubmission
        }
        if let existing = attempt.discussionInstruction { return existing }
        attempt.discussionInstruction = instruction
        attempt.updatedAt = Date()
        try replace(attempt)
        return instruction
    }

    /// The store, rather than a view lifecycle task, owns an in-flight review.
    func submitForReview(
        _ definition: CourseAssessmentDefinition,
        review: @escaping (CourseAssessmentDefinition, CourseAssessmentAttempt) async throws -> CourseAssessmentReview,
        didRequestDiscussion: @escaping (CourseAssessmentDefinition, CourseAssessmentAttempt, String?) -> Void
    ) throws {
        let submitted = try beginReview(definition)
        reviewTasks[submitted.id] = Task { @MainActor [self] in
            defer { reviewTasks[submitted.id] = nil }
            guard !isInvalidated, !Task.isCancelled else { return }
            let result: CourseAssessmentReview
            do {
                result = try await review(definition, submitted)
            } catch {
                guard !isInvalidated, !Task.isCancelled else { return }
                do {
                    try failReview(error.localizedDescription, for: submitted)
                } catch {
                    // Persistence errors are already exposed by replace(_:).
                }
                return
            }
            guard !isInvalidated, !Task.isCancelled else { return }
            do {
                try completeReview(result, for: submitted)
            } catch {
                if savedAttempts.first(where: { $0.id == submitted.id })?.phase == .reviewing {
                    do {
                        try failReview(error.localizedDescription, for: submitted)
                    } catch {
                        // Keep the answer and expose the persistence failure.
                    }
                }
                return
            }
            guard result.needsDiscussion,
                  activeFingerprints[definition.id] == definition.fingerprint,
                  let latest = latestAttempt(for: definition),
                  latest.id == submitted.id,
                  !latest.discussionOpened else { return }
            do {
                try markDiscussionOpened(for: latest)
                didRequestDiscussion(definition, latest, result.openingQuestion)
            } catch {
                // Leave the discussion button available when the handoff cannot be saved.
            }
        }
    }

    func retrySaving() throws {
        try commit(savedAttempts)
    }

    /// An unreadable file is never overwritten by an empty store.
    func retryLoading() {
        guard !isInvalidated, reviewTasks.isEmpty else { return }
        lastPersistenceError = nil
        do {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                savedAttempts = []
                loadFailure = nil
                lastPersistenceError = nil
                return
            }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else { throw StoreError.unsupportedVersion(archive.version) }
            guard Set(archive.attempts.map(\.id)).count == archive.attempts.count else {
                throw StoreError.invalidStoredIdentity
            }
            let submissionIDs = archive.attempts.map(\.submissionID).filter { !$0.isEmpty }
            guard Set(submissionIDs).count == submissionIDs.count,
                  archive.attempts.allSatisfy({ !$0.courseID.isEmpty && !$0.pageID.isEmpty
                      && !$0.assessmentID.isEmpty && !$0.fingerprint.isEmpty }) else {
                throw StoreError.invalidStoredIdentity
            }
            savedAttempts = archive.attempts
            loadFailure = nil
            lastPersistenceError = nil
            var recovered = savedAttempts
            var didRecover = false
            for index in recovered.indices where recovered[index].phase == .reviewing {
                recovered[index].phase = .failed
                recovered[index].reviewError = "The review was interrupted. Your answer is saved; try reviewing it again."
                recovered[index].updatedAt = Date()
                didRecover = true
            }
            if didRecover {
                try commit(recovered, keepInMemoryOnFailure: true)
            }
        } catch {
            if lastPersistenceError == nil {
                let message = (error as? StoreError)?.localizedDescription
                    ?? StoreError.unreadableStore(error.localizedDescription).localizedDescription
                loadFailure = message
                lastPersistenceError = message
            }
        }
    }

    private func makeDraft(_ definition: CourseAssessmentDefinition) throws -> CourseAssessmentAttempt {
        let now = Date()
        let attempt = CourseAssessmentAttempt(
            id: UUID(),
            courseID: courseID,
            pageID: pageID,
            assessmentID: definition.id,
            fingerprint: definition.fingerprint,
            questionTitle: definition.title,
            questionPrompt: definition.prompt,
            options: definition.options.map { .init(id: $0.id, text: $0.text) },
            createdAt: now,
            updatedAt: now,
            submissionID: "",
            selectedOptionID: nil,
            answerText: "",
            phase: .draft,
            review: nil,
            reviewError: nil,
            discussionOpened: false
        )
        try commit(savedAttempts + [attempt])
        return attempt
    }

    private func belongsToPage(_ attempt: CourseAssessmentAttempt) -> Bool {
        attempt.courseID == courseID && attempt.pageID == pageID
    }

    private func requireActive() throws {
        guard !isInvalidated else { throw StoreError.invalidated }
    }

    private func replace(
        _ attempt: CourseAssessmentAttempt,
        keepInMemoryOnFailure: Bool = false
    ) throws {
        guard let index = savedAttempts.firstIndex(where: { $0.id == attempt.id }) else {
            throw StoreError.staleSubmission
        }
        var updated = savedAttempts
        updated[index] = attempt
        try commit(updated, keepInMemoryOnFailure: keepInMemoryOnFailure)
    }

    private func commit(
        _ candidate: [CourseAssessmentAttempt],
        keepInMemoryOnFailure: Bool = false
    ) throws {
        try requireActive()
        guard loadFailure == nil else { throw StoreError.unreadableStore(loadFailure ?? "") }
        let bounded = boundedHistory(candidate)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Archive(version: 1, attempts: bounded))
            try CourseContinuationSyncStore.writeAppOwnedData(data, to: fileURL)
            savedAttempts = bounded
            lastPersistenceError = nil
            onMutation()
        } catch {
            if keepInMemoryOnFailure { savedAttempts = bounded }
            lastPersistenceError = "Practice could not be saved. Your current response is still on this screen. \(error.localizedDescription)"
            throw error
        }
    }

    private func boundedHistory(_ attempts: [CourseAssessmentAttempt]) -> [CourseAssessmentAttempt] {
        struct QuestionKey: Hashable {
            let courseID: String
            let pageID: String
            let assessmentID: String
        }
        var counts: [QuestionKey: Int] = [:]
        var retained: [CourseAssessmentAttempt] = []
        for attempt in attempts.reversed() {
            let key = QuestionKey(
                courseID: attempt.courseID,
                pageID: attempt.pageID,
                assessmentID: attempt.assessmentID
            )
            let count = counts[key, default: 0]
            let isInFlight = attempt.phase == .reviewing || reviewTasks[attempt.id] != nil
            guard isInFlight || (count < Self.maximumHistoryPerQuestion
                && retained.count < Self.maximumAttempts) else { continue }
            retained.append(attempt)
            counts[key] = count + 1
        }
        return retained.reversed()
    }
}
