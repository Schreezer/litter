import SwiftUI

/// Opens only the requested page after its durable generated status is confirmed.
struct CourseLessonActionButton: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    let node: CourseLearningNode
    @Bindable var store: CourseExperienceStore
    let title: String
    var replacesCurrentPage = false
    /// Floats the button as Liquid Glass over scrolling content (iOS 26+).
    var usesGlass = false

    @State private var requestID: UUID?
    @State private var isGenerating = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("course-reading-error")
            } else if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("course-reading-notice")
            }
            actionButton
        }
        .task(id: requestID) {
            guard let requestID else { return }
            await openLesson(request: requestID)
        }
        .onDisappear { requestID = nil }
    }

    @ViewBuilder
    private var actionButton: some View {
        #if targetEnvironment(macCatalyst)
        Button {
            error = nil
            notice = nil
            requestID = UUID()
        } label: {
            HStack(spacing: 8) {
                if requestID != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(requestID != nil ? (isGenerating ? "Generating lesson…" : "Opening lesson…") : (error == nil ? title : "Try again"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(requestID != nil)
        .help(node.title)
        .accessibilityLabel("\(title), \(node.title)")
        .accessibilityIdentifier(replacesCurrentPage ? "course-next-lesson" : "course-continue")
        #else
        let button = Button {
            error = nil
            notice = nil
            requestID = UUID()
        } label: {
            HStack(spacing: usesGlass ? 10 : 12) {
                if requestID != nil {
                    ProgressView()
                } else {
                    Image(systemName: usesGlass ? "play.fill" : "arrow.right")
                        .font(usesGlass ? .body.weight(.semibold) : nil)
                }
                VStack(alignment: .leading, spacing: usesGlass ? 1 : 3) {
                    Text(requestID != nil ? (isGenerating ? "Generating next lesson…" : "Opening lesson…") : (error == nil ? title : "Try again"))
                        .font(.headline)
                    Text(node.title)
                        .font(usesGlass ? .subheadline : .caption)
                        .opacity(usesGlass ? 0.85 : 1)
                        .lineLimit(usesGlass ? 1 : 2)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 480)
        }
        .controlSize(usesGlass ? .regular : .large)
        .disabled(requestID != nil)
        .accessibilityIdentifier(replacesCurrentPage ? "course-next-lesson" : "course-continue")

        if usesGlass, #available(iOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
        #endif
    }

    @MainActor
    private func openLesson(request: UUID) async {
        defer {
            if requestID == request { requestID = nil; isGenerating = false }
        }
        do {
            let outcome = try await store.openCourseNode(
                node,
                in: course,
                replacesCurrentPage: replacesCurrentPage,
                appModel: appModel,
                appState: appState,
                onGenerating: { isGenerating = true },
                shouldOpen: { requestID == request }
            )
            if outcome == .stillWriting || outcome == .queued, requestID == request {
                notice = "“\(node.title)” is being written. Open it again when it’s ready."
            }
        } catch is CancellationError {
            // Leaving the reader cancels navigation, not the existing generation run.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

/// What opening a page on the course map did.
enum CourseNodeOpenOutcome: Equatable {
    case opened
    /// The learner moved on before it was ready, so it was not opened.
    case skipped
    /// An exploration that is being written. Nothing opens when it finishes.
    case stillWriting
    /// An unwritten exploration, now queued for writing. Nothing opens when it finishes.
    case queued
}

extension CourseExperienceStore {
    /// Opens any page on the course map, planned lesson or exploration, after
    /// its durable generated status is confirmed. A planned lesson is generated
    /// first if needed. An exploration is never waited on: one that is not
    /// written yet is queued, and the learner opens it once it is ready.
    @MainActor
    @discardableResult
    func openCourseNode(
        _ node: CourseLearningNode,
        in course: LearningCourse,
        replacesCurrentPage: Bool,
        appModel: AppModel,
        appState: AppState,
        onGenerating: @MainActor () -> Void = {},
        shouldOpen: @MainActor () -> Bool = { true }
    ) async throws -> CourseNodeOpenOutcome {
        let repository = try await documentRepository(for: course)
        var target = try await currentReadableTarget(node, in: repository)
        try Task.checkCancellation()
        if CourseExplorationMap.isExploration(target), target.status != .generated {
            if explorationJob(nodeID: target.id)?.isActive == true
                || (backgroundGeneratingCourseID == course.id && backgroundGeneratingNodeID == target.id) {
                return .stillWriting
            }
            try await writeExploration(nodeID: target.id, in: course, appModel: appModel, appState: appState)
            return .queued
        }
        if target.status != .generated {
            onGenerating()
            let alreadyGenerating = backgroundGeneratingCourseID == course.id
                && backgroundGeneratingNodeID == target.id
            if !alreadyGenerating {
                // A terminal interrupted attempt can leave a generating or partial
                // page. The existing dispatcher still enforces runtime/busy guards.
                target.status = .pendingGeneration
                generateCourseNodeInBackground(
                    for: course, node: target, appModel: appModel, appState: appState
                )
            }
            guard backgroundGeneratingCourseID == course.id,
                  backgroundGeneratingNodeID == target.id else {
                throw CourseReadingNavigationError.unavailable(
                    backgroundGenerationError ?? "The course agent is busy. Try again when it finishes."
                )
            }
            while backgroundGeneratingCourseID == course.id,
                  backgroundGeneratingNodeID == target.id {
                try await Task.sleep(for: .milliseconds(300))
            }
            try Task.checkCancellation()
            target = try await currentReadableTarget(node, in: repository)
            guard target.status == .generated else {
                throw CourseReadingNavigationError.unavailable(
                    backgroundGenerationErrorCourseID == course.id
                        ? backgroundGenerationError ?? "This page is not ready yet. Try again."
                        : "This page is not ready yet. Try again."
                )
            }
        }
        try Task.checkCancellation()
        guard let pageID = target.pageID else {
            throw CourseReadingNavigationError.unavailable("This lesson has no page yet. Open the course agent to repair it.")
        }
        guard shouldOpen() else { return .skipped }
        openReadingPage(
            courseID: course.id, pageID: pageID, replacingCurrentPage: replacesCurrentPage
        )
        return .opened
    }

    private func currentReadableTarget(
        _ node: CourseLearningNode,
        in repository: CourseDocumentRepository
    ) async throws -> CourseLearningNode {
        let outline = try await repository.outline()
        guard let target = CourseReadingOrder.readablePages(in: outline.learningPages)
            .first(where: { $0.id == node.id }) else {
            throw CourseReadingNavigationError.unavailable("This lesson is no longer in the course. Reopen the course to choose a lesson.")
        }
        guard target.pageID == node.pageID else {
            throw CourseReadingNavigationError.unavailable("The requested lesson changed while the agent was working. Reopen the course to choose a lesson.")
        }
        var checkedTarget = target
        if target.status == .generated, let pageID = target.pageID {
            let page = try await repository.pageSnapshot(id: pageID)
            if !CourseExperienceStore.generatedLessonIsReady(page) {
                checkedTarget.status = .partiallyGenerated
            }
        }
        return checkedTarget
    }
}

enum CourseReadingNavigationError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}
