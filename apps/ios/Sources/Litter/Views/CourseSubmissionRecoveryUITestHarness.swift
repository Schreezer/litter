#if DEBUG
import Foundation
import SwiftUI

/// The production new-course chat against a local Hosted server whose
/// transcript survives relaunches. A UI test sends a message, kills the app
/// while the reply is pending, relaunches, and checks the message's status.
struct CourseSubmissionRecoveryUITestHarness: View {
    static let argument = "--ui-test-course-submission-recovery"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @Environment(AppModel.self) private var appModel
    @State private var store: CourseExperienceStore?
    @State private var appState = AppState()

    var body: some View {
        Group {
            if let store {
                NavigationStack {
                    CourseChatView(store: store)
                }
                .environment(appState)
            } else {
                ProgressView("Preparing submission recovery fixture")
            }
        }
        .task { if store == nil { prepare() } }
    }

    @MainActor
    private func prepare() {
        let environment = ProcessInfo.processInfo.environment
        guard let token = UUID(uuidString: environment["LEARNFOLD_SUBMISSION_RECOVERY_TOKEN"] ?? "")?
            .uuidString else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubmissionRecoveryFixture-\(token)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "SubmissionRecoveryFixture.\(token)")!
        let server = SubmissionRecoveryFixtureServer(
            transcriptURL: root.appendingPathComponent("server-transcript.json"),
            delivery: SubmissionRecoveryFixtureServer.Delivery(
                rawValue: environment["LEARNFOLD_SUBMISSION_RECOVERY_DELIVERY"] ?? ""
            ) ?? .lost,
            holdsSends: environment["LEARNFOLD_SUBMISSION_RECOVERY_PHASE"] == "interrupt",
            appStore: appModel.store
        )
        let fixtureStore = CourseExperienceStore(
            defaults: defaults,
            environment: [:],
            hostedRuntime: server,
            coursesRootURL: root.appendingPathComponent("Courses", isDirectory: true)
        )
        fixtureStore.selectedAgentID = CourseAgentProvider.hosted
        if !defaults.bool(forKey: "fixture.started") {
            server.seedConversation()
            fixtureStore.beginNewCourse()
            defaults.set(true, forKey: "fixture.started")
        }
        store = fixtureStore
    }
}

/// A Hosted server stand-in. Like Think, it keeps the transcript keyed by the
/// learner message id the phone sends, and mirrors its rows into the shared
/// chat timeline the way the Rust `HostedAdapter` does.
@MainActor
final class SubmissionRecoveryFixtureServer: HostedCourseAgentRuntime {
    enum Delivery: String {
        /// The message reached the server before the app died.
        case received
        /// The app died before the message left the phone.
        case lost
    }

    private struct StoredMessage: Codable {
        let id: String
        let role: String
        let text: String
    }

    static let reply = "Good start. Telomere shortening is one hallmark of aging; we will build from there."

    private let transcriptURL: URL
    private let delivery: Delivery
    private let holdsSends: Bool
    private let appStore: AppStore

    init(transcriptURL: URL, delivery: Delivery, holdsSends: Bool, appStore: AppStore) {
        self.transcriptURL = transcriptURL
        self.delivery = delivery
        self.holdsSends = holdsSends
        self.appStore = appStore
    }

    func seedConversation() {
        save([
            StoredMessage(
                id: "seed-learner",
                role: "user",
                text: "Comfortable with cells, DNA, proteins, and basic physiology"
            ),
            StoredMessage(
                id: "seed-agent",
                role: "assistant",
                text: "To calibrate the course beyond terminology, explain in your own words why you think humans age and eventually die."
            ),
        ])
    }

    func availability() -> HostedCourseAgentAvailability {
        .init(available: true, reason: "Local submission recovery fixture")
    }

    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] {
        let stored = load()
        var turnID: String?
        appStore.ingestSourceEvents(
            key: CourseExperienceStore.hostedChatKey(sessionID: sessionID),
            source: .hosted,
            events: [.replaceTranscript(messages: stored.map { message in
                if message.role == "user" { turnID = message.id }
                return ExternalTranscriptMessage(
                    id: message.id,
                    role: message.role == "user" ? .user : .assistant,
                    text: message.text,
                    turnId: turnID
                )
            })]
        )
        return stored.map {
            HostedCourseAgentStoredMessage(
                id: $0.id,
                role: $0.role == "user" ? .learner : .agent,
                text: $0.text
            )
        }
    }

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
        let key = CourseExperienceStore.hostedChatKey(sessionID: sessionID)
        let learnerID = (messageID ?? UUID()).uuidString.lowercased()
        appStore.ingestSourceEvents(key: key, source: .hosted, events: [
            .userMessage(clientMsgId: learnerID, text: prompt),
            .turnAccepted(clientMsgId: learnerID, turnId: learnerID),
            .turnStarted(turnId: learnerID),
        ])
        if holdsSends {
            // The server keeps working after the phone dies, so a received
            // message also gets its reply.
            if delivery == .received {
                save(load() + [
                    StoredMessage(id: learnerID, role: "user", text: prompt),
                    StoredMessage(id: "reply-\(learnerID)", role: "assistant", text: Self.reply),
                ])
            }
            // Stay "waiting on the model" until the test kills the app.
            try await Task.sleep(for: .seconds(3_600))
            return
        }
        save(load() + [
            StoredMessage(id: learnerID, role: "user", text: prompt),
            StoredMessage(id: "reply-\(learnerID)", role: "assistant", text: Self.reply),
        ])
        appStore.ingestSourceEvents(key: key, source: .hosted, events: [
            .textSnapshot(itemId: "reply-\(learnerID)", channel: .answer, text: Self.reply),
            .turnSettled(outcome: .completed),
        ])
        onPartialResponse(Self.reply)
    }

    func cancel(sessionID: UUID) {}

    private func load() -> [StoredMessage] {
        (try? Data(contentsOf: transcriptURL))
            .flatMap { try? JSONDecoder().decode([StoredMessage].self, from: $0) } ?? []
    }

    private func save(_ messages: [StoredMessage]) {
        try? JSONEncoder().encode(messages).write(to: transcriptURL, options: .atomic)
    }
}
#endif
