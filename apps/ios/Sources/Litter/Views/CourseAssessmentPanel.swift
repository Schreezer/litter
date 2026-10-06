import SwiftUI

/// Native presentation for validated authored checks. The surrounding reader owns navigation.
struct CourseAssessmentPanel: View {
    let assessments: [CourseAssessmentDefinition]
    let invalidCheckCount: Int
    let attempts: CourseAssessmentAttemptStore
    let review: (CourseAssessmentDefinition, CourseAssessmentAttempt) async throws -> CourseAssessmentReview
    let discuss: (CourseAssessmentDefinition, CourseAssessmentAttempt?, String?) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionToggle
            if isExpanded {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = attempts.lastPersistenceError {
                        persistenceNotice(message)
                    }
                    ForEach(assessments, id: \.id) { assessment in
                        CourseAssessmentCard(
                            assessment: assessment,
                            attempts: attempts,
                            review: review,
                            discuss: discuss
                        )
                    }
                    if invalidCheckCount > 0 {
                        Label {
                            Text("An exercise on this page is unavailable. You can continue learning or discuss the page with your tutor.")
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("course-assessment-unavailable")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("course-assessment-section-content")
            }
        }
        // Preparation is independent of expansion, as are store-owned review tasks.
        .task(id: assessments.map(\.fingerprint)) {
            attempts.prepare(assessments)
        }
    }

    private var sectionToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test your understanding")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(sectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if attempts.lastPersistenceError != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                } else if assessments.contains(where: { attempts.latestAttempt(for: $0)?.phase == .reviewing }) {
                    ProgressView()
                        .accessibilityHidden(true)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Exercise. Test your understanding. \(sectionSummary)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides optional page exercises.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("course-assessment-section-toggle")
    }

    private var sectionSummary: String {
        var parts: [String] = []
        if !assessments.isEmpty {
            parts.append("\(assessments.count) optional \(assessments.count == 1 ? "check" : "checks")")
        }
        if invalidCheckCount > 0 {
            parts.append("\(invalidCheckCount) unavailable")
        }
        let reviewedCount = assessments.filter { attempts.latestAttempt(for: $0)?.review != nil }.count
        if reviewedCount > 0 {
            parts.append("\(reviewedCount) reviewed")
        }
        if attempts.lastPersistenceError != nil {
            parts.append("Saving needs attention")
        }
        return parts.joined(separator: " · ")
    }

    private func persistenceNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
            Button(attempts.loadFailure == nil ? "Retry saving" : "Retry loading saved practice") {
                if attempts.loadFailure != nil {
                    attempts.retryLoading()
                } else {
                    do {
                        try attempts.retrySaving()
                    } catch {
                        // The store retains the response and displays the storage error.
                    }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("course-assessment-retry-storage")
        }
        .foregroundStyle(.primary)
        .padding(16)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("course-assessment-storage-error")
    }
}

private struct CourseAssessmentCard: View {
    let assessment: CourseAssessmentDefinition
    let attempts: CourseAssessmentAttemptStore
    let review: (CourseAssessmentDefinition, CourseAssessmentAttempt) async throws -> CourseAssessmentReview
    let discuss: (CourseAssessmentDefinition, CourseAssessmentAttempt?, String?) -> Void

    @State private var actionError: String?
    @FocusState private var answerFocused: Bool

    private var attempt: CourseAssessmentAttempt? {
        attempts.latestAttempt(for: assessment)
    }

    private var isReviewing: Bool { attempt?.phase == .reviewing }
    private var hasReview: Bool { attempt?.review != nil }
    private var isDiscussion: Bool { assessment.kind == .discussion }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if isDiscussion {
                discussionCheck
            } else if let attempt {
                activeCheck(attempt)
            } else {
                Button("Start check") {
                    perform { _ = try attempts.start(assessment) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-assessment-start-\(assessment.id)")
            }
            if let actionError {
                Text(actionError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("course-assessment-error-\(assessment.id)")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.blue.opacity(0.14), lineWidth: 1)
        }
        .disabled(attempts.loadFailure != nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-assessment-\(assessment.id)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                formatLabel,
                systemImage: isDiscussion ? "bubble.left.and.bubble.right" : "checkmark.circle"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if showsAuthoredTitle {
                Text(assessment.title)
                    .font(.headline)
            }
        }
    }

    private var formatLabel: String {
        switch assessment.kind {
        case .multipleChoice: return "Multiple choice"
        case .freeText: return "Written answer"
        case .discussion: return "Guided discussion"
        }
    }

    private var showsAuthoredTitle: Bool {
        let normalized = assessment.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && ![
            "check your understanding", "test your understanding", "discuss your understanding",
        ].contains(normalized)
    }

    private var discussionCheck: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(assessment.prompt)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Button(attempt?.discussionOpened == true ? "Continue discussion" : "Start discussion") {
                openDiscussion()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("course-assessment-discuss-\(assessment.id)")
        }
    }

    @ViewBuilder
    private func activeCheck(_ attempt: CourseAssessmentAttempt) -> some View {
        Text(assessment.prompt)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
        if assessment.kind == .multipleChoice {
            options(attempt)
        } else {
            freeTextAnswer(attempt)
        }
        if isReviewing {
            HStack(spacing: 10) {
                ProgressView()
                Text("Reviewing your answer…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("course-assessment-reviewing-\(assessment.id)")
        } else if let result = attempt.review {
            feedback(result)
            HStack(spacing: 12) {
                Button("Try again") {
                    perform { _ = try attempts.retry(assessment) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("course-assessment-retry-\(assessment.id)")
                Button("Discuss this") { openDiscussion() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("course-assessment-discuss-\(assessment.id)")
            }
        } else {
            if let message = attempt.reviewError {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-assessment-review-error-\(assessment.id)")
            }
            Button(attempt.phase == .failed ? "Retry review" : "Review my answer") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit(attempt))
            .accessibilityIdentifier("course-assessment-submit-\(assessment.id)")
        }
    }

    private func options(_ attempt: CourseAssessmentAttempt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(assessment.options, id: \.id) { option in
                let selected = attempt.selectedOptionID == option.id
                Button {
                    perform {
                        try attempts.updateDraft(
                            assessment,
                            selectedOptionID: option.id,
                            answerText: attempt.answerText
                        )
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Color.blue : Color.secondary)
                            .padding(.top, 2)
                        Text(option.text)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selected ? Color.blue.opacity(0.09) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? Color.blue.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReviewing || hasReview)
                .accessibilityLabel(option.text)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("course-assessment-option-\(assessment.id)-\(option.id)")
            }
        }
    }

    private func freeTextAnswer(_ attempt: CourseAssessmentAttempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your explanation")
                .font(.subheadline.weight(.medium))
            TextField(
                "Explain it in your own words",
                text: Binding(
                    get: { self.attempt?.answerText ?? "" },
                    set: { value in
                        perform {
                            try attempts.updateDraft(
                                assessment,
                                selectedOptionID: nil,
                                answerText: value
                            )
                        }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(4...10)
            .focused($answerFocused)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if answerFocused {
                        Spacer()
                        Button("Done") { answerFocused = false }
                            .accessibilityIdentifier("course-assessment-answer-done-\(assessment.id)")
                    }
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .disabled(isReviewing || hasReview)
            .accessibilityIdentifier("course-assessment-answer-\(assessment.id)")
            Text("\(attempt.answerText.count)/\(CourseAssessmentAttemptStore.maximumAnswerLength)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("\(attempt.answerText.count) of \(CourseAssessmentAttemptStore.maximumAnswerLength) characters")
        }
    }

    private func feedback(_ review: CourseAssessmentAttempt.Review) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                review.outcome == .understood ? "Well understood" : "Worth another look",
                systemImage: review.outcome == .understood ? "checkmark.circle.fill" : "arrow.trianglehead.clockwise"
            )
            .font(.subheadline.weight(.semibold))
            Text(review.feedback)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("course-assessment-feedback-\(assessment.id)")
    }

    private func canSubmit(_ attempt: CourseAssessmentAttempt) -> Bool {
        if assessment.kind == .multipleChoice { return attempt.selectedOptionID != nil }
        return !attempt.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        answerFocused = false
        perform {
            try attempts.submitForReview(assessment, review: review) { definition, attempt, question in
                discuss(definition, attempt, question)
            }
        }
    }

    private func openDiscussion() {
        answerFocused = false
        perform {
            let current = try attempts.start(assessment)
            try attempts.markDiscussionOpened(for: current)
            discuss(
                assessment,
                current,
                current.review?.openingQuestion ?? assessment.openingPrompt
            )
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}
