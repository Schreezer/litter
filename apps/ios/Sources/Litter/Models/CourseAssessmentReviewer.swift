import Foundation

enum CourseAssessmentReviewRuntimeError: LocalizedError {
    case unavailable(String)
    case timedOut
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .timedOut: "Exercise review took too long. Your answer is saved; try again."
        case .emptyResponse: "The agent returned no exercise review. Try again."
        }
    }
}

/// Platform dispatch only. Rust validates the returned review before it can
/// change an attempt or suggest a page discussion.
@MainActor
enum CourseAssessmentReviewer {
    static func review(
        prompt: String,
        outputSchema: String,
        target: CourseAgentExecutionTarget,
        workspaceID: String,
        appModel: AppModel,
        appleRuntime: any AppleCourseAgentRuntime,
        hostedRuntime: any HostedCourseAgentRuntime,
        hostedIdentityBinding: HostedCourseIdentityBinding? = nil
    ) async throws -> String {
        let sessionID = UUID()
        let constrainedPrompt = """
        \(prompt)

        Return only one JSON object matching this output schema:
        \(outputSchema)
        """
        let response: String
        if target.runtimeID == CourseAgentProvider.hosted {
            try hostedRuntime.configureSession(sessionID: sessionID, binding: hostedIdentityBinding)
            defer { hostedRuntime.cancel(sessionID: sessionID) }
            response = try await CourseAssessmentReviewDeadline.run(
                onCancel: { hostedRuntime.cancel(sessionID: sessionID) }
            ) {
                try await hostedRuntime.review(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    prompt: constrainedPrompt
                )
            }
        } else if CourseAgentProvider.isApple(target.runtimeID) {
            defer { appleRuntime.remove(sessionID: sessionID, workspaceID: workspaceID) }
            response = try await CourseAssessmentReviewDeadline.run(
                onCancel: { appleRuntime.cancel(sessionID: sessionID) }
            ) {
                try await appleRuntime.review(
                    sessionID: sessionID,
                    providerID: target.runtimeID,
                    workspaceID: workspaceID,
                    prompt: constrainedPrompt
                )
            }
        } else {
            guard let serverID = target.serverID, !serverID.isEmpty else {
                throw CourseAssessmentReviewRuntimeError.unavailable(
                    "Reconnect the selected agent to review this exercise."
                )
            }
            response = try await CourseAssessmentReviewDeadline.run(onCancel: {}) {
                let result = await appModel.client.structuredResponseForTarget(
                    serverId: serverID,
                    runtimeId: target.runtimeID,
                    prompt: prompt,
                    outputSchemaJson: outputSchema,
                    modelId: target.modelID,
                    reasoningEffort: ReasoningEffort(wireValue: target.reasoningEffortID)
                )
                try Task.checkCancellation()
                switch result {
                case .success(_, let responseJson): return responseJson
                case .error(let message):
                    throw CourseAssessmentReviewRuntimeError.unavailable(message)
                }
            }
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CourseAssessmentReviewRuntimeError.emptyResponse }
        return trimmed
    }
}

/// An unstructured race lets the UI finish on timeout even when a native
/// provider doesn't immediately honour task cancellation. Late results cannot
/// resume the continuation twice or mutate assessment state.
@MainActor
private final class CourseAssessmentReviewDeadline {
    private var continuation: CheckedContinuation<String, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let onCancel: @MainActor () -> Void
    private var finished = false

    private init(onCancel: @escaping @MainActor () -> Void) {
        self.onCancel = onCancel
    }

    static func run(
        onCancel: @escaping @MainActor () -> Void,
        operation: @escaping @MainActor () async throws -> String
    ) async throws -> String {
        let deadline = CourseAssessmentReviewDeadline(onCancel: onCancel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !deadline.finished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                deadline.continuation = continuation
                if Task.isCancelled {
                    deadline.cancel(with: CancellationError())
                    return
                }
                deadline.operationTask = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        deadline.finish(.success(try await operation()))
                    }
                    catch { deadline.finish(.failure(error)) }
                }
                deadline.timeoutTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                    deadline.cancel(with: CourseAssessmentReviewRuntimeError.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor in deadline.cancel(with: CancellationError()) }
        }
    }

    private func cancel(with error: Error) {
        guard !finished else { return }
        onCancel()
        finish(.failure(error))
    }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        timeoutTask?.cancel()
        operationTask?.cancel()
        timeoutTask = nil
        operationTask = nil
        continuation?.resume(with: result)
    }
}
