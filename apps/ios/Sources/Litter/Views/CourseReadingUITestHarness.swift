#if DEBUG
import SwiftUI
import NativeBlockEditorCore
import NativeEditorMCP

/// Isolated local fixture exercising the production reader and generation dispatcher.
struct CourseReadingUITestHarness: View {
    static let argument = "--ui-test-course-reading"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @Environment(AppModel.self) private var appModel
    @State private var store: CourseExperienceStore?
    @State private var error: String?
    @State private var appState = AppState()

    var body: some View {
        Group {
            if let store {
                ReadingFixtureNavigation(store: store)
                    .environment(appState)
            } else if let error {
                Text(error).accessibilityIdentifier("reading-fixture-error")
            } else {
                ProgressView("Preparing reading fixture")
            }
        }
        .preferredColorScheme(ThemeManager.shared.appearanceMode.preferredColorScheme ?? .light)
        .task { if store == nil { await prepare() } }
    }

    @MainActor
    private func prepare() async {
        let appearance = LitterAppearanceMode(
            rawValue: ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_APPEARANCE"] ?? "light"
        ) ?? .light
        ThemeManager.shared.setAppearanceMode(appearance)
        do {
            let rawToken = ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_TOKEN"] ?? ""
            guard let token = UUID(uuidString: rawToken)?.uuidString else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadingFixture-\(token)")
            let workspaceID = "reading-\(token.lowercased())"
            let courseRoot = root.appendingPathComponent(workspaceID)
            let database = courseRoot.appendingPathComponent(".course/course-library.sqlite")
            let includesAssessments = ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_ASSESSMENTS"] == "1"
            let isFilmCourse = CourseReadingFilmFixture.isEnabled
            var course = LearningCourse(
                id: workspaceID,
                title: includesAssessments ? "Cellular energetics" : "Zero-Knowledge SNARKs",
                subtitle: includesAssessments ? "Energy for living cells" : "From Intuition to Circuits",
                accentHex: "007AFF", progress: 0, lessonCount: 3, duration: "", status: .ready,
                workspaceID: workspaceID, agentRuntimeKind: CourseAgentProvider.hosted,
                hostedSessionID: UUID()
            )
            if isFilmCourse {
                course.title = CourseReadingFilmFixture.courseTitle
                course.subtitle = CourseReadingFilmFixture.courseSubtitle
                course.accentHex = CourseReadingFilmFixture.accentHex
                course.lessonCount = CourseReadingFilmFixture.lessonCount
            }
            let defaults = UserDefaults(suiteName: "ReadingFixture.\(token)")!
            if !FileManager.default.fileExists(atPath: database.path) {
                var workspace = PageWorkspace(rootTitle: course.title)
                func document(_ text: String, role: String, status: String = "generated") throws -> BlockDocument {
                    var document = try AppFlowyMarkdownCodec().decode(text)
                    document.root.data["course_role"] = .string(role)
                    document.root.data["course_generation_status"] = .string(status)
                    return document
                }
                if isFilmCourse {
                    // The launch film's course: verbatim pages, no visualization.
                    for page in CourseReadingFilmFixture.pages {
                        _ = try workspace.createPage(
                            title: page.title,
                            parentID: page.parentID ?? workspace.rootPageID,
                            document: document(page.markdown, role: page.role, status: page.status),
                            id: page.id
                        )
                    }
                } else {
                    let chapter = try workspace.createPage(
                        title: includesAssessments ? "Energy inside cells" : "The Zero-Knowledge Mindset",
                        parentID: workspace.rootPageID,
                        document: document("", role: "chapter"), id: "chapter")
                    let section = try workspace.createPage(
                        title: includesAssessments ? "Oxygen and ion pumps" : "Proofs without secrets",
                        parentID: chapter.id,
                        document: document("", role: "subchapter"), id: "section")
                    let article = includesAssessments ? Self.assessmentArticle : (1...18).map { index in
                        "## Idea \(index)\n\nA proof can show that a statement is true while keeping its underlying secret private. Follow the verifier's questions and the prover's responses to see what information each step reveals."
                    }.joined(separator: "\n\n")
                    let visualizationHTML = """
                    <style>
                    .proof-simulation { padding: 12px; border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 12px; }
                    .proof-round { display: grid; grid-template-columns: 1fr auto 1fr; gap: 8px; align-items: center; min-height: 82px; }
                    .proof-party { text-align: center; padding: 10px 4px; background: color-mix(in srgb, #007aff 14%, transparent); border-radius: 8px; }
                    .proof-arrow { font-size: 22px; color: #007aff; }
                    .proof-controls { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
                    .proof-controls button { min-height: 44px; border: 0; border-radius: 9px; padding: 0 14px; background: #007aff; color: white; font: inherit; font-weight: 600; }
                    .proof-controls output { flex: 1; }
                    </style>
                    <section class="proof-simulation" aria-label="Zero-knowledge proof challenge simulation">
                      <div class="proof-round" aria-hidden="true">
                        <div class="proof-party">Prover<br><strong id="proof-secret">commits</strong></div>
                        <div class="proof-arrow" id="proof-arrow">→</div>
                        <div class="proof-party">Verifier<br><strong id="proof-action">waits</strong></div>
                      </div>
                      <div class="proof-controls">
                        <button id="advance-proof" type="button">Advance simulation</button>
                        <output id="proof-state" aria-live="polite">Round 1: prover sends a commitment.</output>
                      </div>
                    </section>
                    <script>
                    (function () {
                      var step = 0;
                      var states = [
                        ['commits', 'waits', '→', 'Round 1: prover sends a commitment.'],
                        ['holds secret', 'challenges', '←', 'Round 2: verifier sends a random challenge.'],
                        ['responds', 'checks proof', '→', 'Round 3: verifier checks the response without learning the secret.']
                      ];
                      document.getElementById('advance-proof').addEventListener('click', function () {
                        step = (step + 1) % states.length;
                        document.getElementById('proof-secret').textContent = states[step][0];
                        document.getElementById('proof-action').textContent = states[step][1];
                        document.getElementById('proof-arrow').textContent = states[step][2];
                        document.getElementById('proof-state').textContent = states[step][3];
                      });
                    })();
                    </script>
                    """
                    var articleDocument = try document(article, role: "lesson")
                    if !includesAssessments {
                        articleDocument.root.children.insert(
                            .html(
                                visualizationHTML,
                                allowNetwork: false,
                                allowJavaScript: true
                            ),
                            at: 0
                        )
                    }
                    _ = try workspace.createPage(
                        title: includesAssessments ? "Molecular machinery and cellular energetics" : "What a proof reveals",
                        parentID: section.id,
                        document: articleDocument, id: "article-one")
                    _ = try workspace.createPage(
                        title: includesAssessments ? "Oxygen, gradients, and ATP" : "A verifier's challenge",
                        parentID: section.id,
                        document: document(
                            includesAssessments ? Self.secondAssessmentArticle
                                : "## A challenge\n\nTry describing a verification step without sharing the secret.\n\n## Keep asking\n\n- Why is the challenge random?\n- What could a cheating prover do?",
                            role: "lesson"
                        ), id: "article-two")
                    let second = try workspace.createPage(title: "Finite Fields", parentID: workspace.rootPageID,
                        document: document("", role: "chapter"), id: "chapter-two")
                    _ = try workspace.createPage(title: "The math playground", parentID: second.id,
                        document: document("", role: "lesson", status: "pending_generation"), id: "article-three")
                }
                try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try await NativeEditorMCPService.open(databaseURL: database, seedWorkspace: workspace)
                var brief = CourseBrief()
                brief.title = course.title
                try JSONEncoder().encode(brief).write(to: courseRoot.appendingPathComponent("course.json"))
                defaults.set(try JSONEncoder().encode([course]), forKey: "snappy.course.savedCourses")
                if Self.allowsExploration {
                    // Forking writes pages through the native editor tools,
                    // which only an approved course may use.
                    let plan = Self.approvablePlan(title: course.title)
                    let repository = try await CourseDocumentRegistry.shared.repository(
                        workspaceID: workspaceID, databaseURL: database, rootTitle: course.title
                    )
                    try await repository.presentPlan(plan)
                    try await repository.approvePlan(plan)
                }
            }
            let generationScenario = ProcessInfo.processInfo.environment["LEARNFOLD_READING_GENERATION_SCENARIO"] ?? "connection-failure"
            let runtime = ReadingFixtureRuntime(
                transcriptsRoot: root.appendingPathComponent("chat-transcripts"),
                generationScenario: generationScenario,
                appStore: appModel.store
            )
            let fixtureStore = CourseExperienceStore(defaults: defaults, hostedRuntime: runtime, coursesRootURL: root)
            guard await fixtureStore.connectLocalAgent(
                appModel: appModel,
                agentID: CourseAgentProvider.hosted
            ) else {
                throw NSError(domain: "ReadingFixture", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "The local Hosted chat fixture could not be selected."
                ])
            }
            if let courseSessionID = fixtureStore.courses.first?.hostedSessionID {
                try runtime.seedCourseConversation(sessionID: courseSessionID)
            }
            if generationScenario != "connection-failure", fixtureStore.readingBookmark(for: course) == nil {
                fixtureStore.saveReadingBookmark(
                    CourseReadingBookmark(pageID: "article-two", offset: 0, isAtEnd: false),
                    for: course
                )
            }
            fixtureStore.navigationPath = []
            store = fixtureStore
        } catch { self.error = error.localizedDescription }
    }

    /// A complete plan: approval is only honored for a plan that decodes.
    static func approvablePlan(title: String) -> CourseBrief {
        let chapter = CourseChapter(
            id: "foundation-skills", title: "Foundation Skills",
            objective: "Build a reliable conceptual foundation through practice.",
            deliverables: ["Practice the core foundation"]
        )
        var plan = CourseBrief()
        plan.planID = "exploration-fixture"
        plan.revision = 1
        plan.title = title
        plan.summary = "Build a practical foundation through guided practice."
        plan.outcome = "Apply the core ideas in a practical exercise."
        plan.startingPoint = "Basic familiarity with the topic."
        plan.focusGap = "Structured practice with the essential concepts."
        plan.estimatedDuration = "One focused hour"
        plan.structureVersion = CoursePlanHierarchyPolicy.currentStructureVersion
        plan.chapters = [chapter]
        plan.learningPath = [CourseLearningNode(
            id: chapter.id, title: chapter.title, kind: .folder, status: .pendingGeneration,
            role: .chapter,
            children: [CourseLearningNode(
                id: "foundation-practice", title: "Practice the Core Foundation",
                kind: .markdown, status: .pendingGeneration, role: .lesson
            )]
        )]
        return plan
    }

    static var allowsExploration: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_EXPLORATION"] == "1"
    }

    private static let assessmentArticle = """
    ## Explanation

    Oxygen accepts electrons at the end of the electron-transport chain. The chain pumps protons, and proton flow through ATP synthase drives ATP production. Ion pumps use ATP to maintain concentration gradients.

    ## Scenario

    When oxygen delivery stops, electron transport stalls and ATP production falls. Ion pumps then lose the energy they need to keep working. DNA storage and inherited information do not provide this energy.

    ## Exercise

    ```learnfold-assessment
    {"version":1,"id":"oxygen-check","kind":"multiple_choice","title":"Check oxygen loss","prompt":"Which process fails when oxygen loss reduces ATP production?","options":[{"id":"a","text":"DNA storage"},{"id":"b","text":"ATP-dependent ion pumping"},{"id":"c","text":"Inherited genetic information"}],"answer":{"option_id":"b","explanation":"ATP supplies energy for ion pumps; when oxygen loss lowers ATP, pumping fails."}}
    ```

    ```learnfold-assessment
    {"version":1,"id":"energy-explain","kind":"free_text","title":"Explain the energy link","prompt":"Explain why ion pumps fail when ATP production falls.","rubric":["ATP supplies the energy that ion pumps need.","Reduced ATP production leaves pumps without enough energy to maintain gradients."]}
    ```

    ```learnfold-assessment
    {"version":1,"id":"energy-discussion","kind":"discussion","title":"Think through oxygen loss","prompt":"Discuss how oxygen loss affects a cell's energy supply.","opening_prompt":"What happens to ATP when oxygen delivery stops?","rubric":["Connect oxygen loss to stalled electron transport.","Connect reduced ATP production to ion-pump failure."]}
    ```
    """

    private static let secondAssessmentArticle = """
    ## Explanation

    A proton gradient stores energy. Proton flow through ATP synthase drives ATP production. This page has its own check, independent of the previous lesson.

    ## Exercise

    ```learnfold-assessment
    {"version":99,"id":"broken-check","kind":"multiple_choice","prompt":"This malformed check must not expose its key.","options":[{"id":"a","text":"Hidden choice"},{"id":"b","text":"Another hidden choice"}],"answer":{"option_id":"a","explanation":"MALFORMED-ANSWER-KEY-DO-NOT-SHOW"}}
    ```

    ```learnfold-assessment
    {"version":1,"id":"gradient-check","kind":"multiple_choice","title":"Check proton flow","prompt":"What powers ATP synthase?","options":[{"id":"a","text":"DNA storage"},{"id":"b","text":"Ribosomes"},{"id":"c","text":"Proton flow"}],"answer":{"option_id":"c","explanation":"Proton flow through ATP synthase drives ATP production."}}
    ```
    """
}

private struct ReadingFixtureNavigation: View {
    @Bindable var store: CourseExperienceStore

    /// Film footage hides the fixture banner; every other run keeps it.
    private static var hidesBanner: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_READING_TEST_HIDE_BANNER"] == "1"
    }

    var body: some View {
        if Self.hidesBanner {
            navigation
        } else {
            navigation
                .safeAreaInset(edge: .top) {
                    Text("LOCAL READING FIXTURE · SIMULATED GENERATION")
                        .font(.caption2)
                        .accessibilityIdentifier("reading-fixture")
                        .accessibilityValue(ThemeManager.shared.appearanceMode.rawValue)
                }
        }
    }

    private var navigation: some View {
        NavigationStack(path: $store.navigationPath) {
            if let course = store.courses.first {
                CourseRouteDestinationView(route: .course(course.id), store: store)
                    .navigationDestination(for: CourseRoute.self) { route in
                        CourseRouteDestinationView(route: route, store: store)
                    }
            }
        }
    }
}

@MainActor
final class ReadingFixtureRuntime: HostedCourseAgentRuntime {
    private struct PersistedMessage: Codable {
        enum Role: String, Codable {
            case learner
            case agent
        }

        let id: String?
        let role: Role
        let text: String

        var storedMessage: HostedCourseAgentStoredMessage {
            .init(id: id, role: role == .learner ? .learner : .agent, text: text)
        }
    }

    private var attempts = 0
    /// Exploration forks seen this launch; indexes the per-fork delay list
    /// and gives each written exploration its own title.
    private var explorationForks = 0
    private let transcriptsRoot: URL
    private let generationScenario: String
    private let appStore: AppStore?
    private var courseSessionID: UUID?

    init(
        transcriptsRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingFixtureTranscripts-\(UUID().uuidString)"),
        generationScenario: String = "connection-failure",
        appStore: AppStore? = nil
    ) {
        self.transcriptsRoot = transcriptsRoot
        self.generationScenario = generationScenario
        self.appStore = appStore
    }

    func seedCourseConversation(sessionID: UUID) throws {
        courseSessionID = sessionID
        guard !FileManager.default.fileExists(atPath: transcriptURL(sessionID: sessionID).path) else { return }
        try persist([
            .init(id: UUID().uuidString, role: .learner, text: "Plan this whole course."),
            .init(id: UUID().uuidString, role: .agent,
                  text: CourseReadingFilmFixture.isEnabled
                    ? CourseReadingFilmFixture.seededConversationReply
                    : "Course-only discussion: the complete SNARKs learning plan.")
        ], sessionID: sessionID)
    }

    func availability() -> HostedCourseAgentAvailability { .init(available: true, reason: "Local fixture") }
    func restoredMessages(sessionID: UUID) async throws -> [HostedCourseAgentStoredMessage] {
        let messages = try transcript(sessionID: sessionID)
        var turnID: String?
        appStore?.ingestSourceEvents(
            key: CourseExperienceStore.hostedChatKey(sessionID: sessionID),
            source: .hosted,
            events: [.replaceTranscript(messages: messages.enumerated().map { index, message in
                let id = message.id ?? "fixture-message-\(index)"
                if message.role == .learner { turnID = id }
                return ExternalTranscriptMessage(
                    id: id,
                    role: message.role == .learner ? .user : .assistant,
                    text: message.text,
                    turnId: turnID
                )
            })]
        )
        return messages.map(\.storedMessage)
    }

    func review(sessionID: UUID, workspaceID: String, prompt: String) async throws -> String {
        let data = try assessmentLearningData(in: prompt)
        guard sessionID != courseSessionID,
              !workspaceID.isEmpty,
              let submissionID = data["submission_id"] as? String,
              let assessmentID = data["assessment_id"] as? String,
              let answer = data["learner_answer"] as? String else {
            throw assessmentFixtureError("The review request did not identify an isolated exercise submission.")
        }
        let reviewDelay = Double(ProcessInfo.processInfo.environment[
            "LEARNFOLD_READING_TEST_REVIEW_DELAY_SECONDS"
        ] ?? "0") ?? 0
        if reviewDelay > 0 {
            try await Task.sleep(for: .seconds(min(reviewDelay, 30)))
        }
        let understood = answer == "ATP powers pumps"
        let outcome = data["authoritative_outcome"] as? String
            ?? (understood ? "understood" : "needs_review")
        let needsDiscussion = data["authoritative_outcome"] == nil && !understood
        let feedback: String
        if let authoredAnswer = data["authored_answer"] as? [String: Any],
           let explanation = authoredAnswer["explanation"] as? String {
            feedback = explanation
        } else if understood {
            feedback = "You connected ATP to the energy that ion pumps need."
        } else {
            feedback = "DNA stores information; ion pumps need ATP to keep working."
        }
        let response: [String: Any] = [
            "version": 1,
            "submission_id": submissionID,
            "assessment_id": assessmentID,
            "outcome": outcome,
            "feedback": feedback,
            "needs_discussion": needsDiscussion,
            "opening_question": needsDiscussion
                ? ("What do ion pumps need to keep working?" as Any) : NSNull(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
    }

    func cancel(sessionID: UUID) {}
    func send(sessionID: UUID, workspaceID: String, courseDirectory: URL, prompt: String, messageID: UUID?,
              role: CourseAgentThreadRole,
              onRecoveringChanged: @escaping @MainActor (Bool) -> Void,
              onPartialResponse: @escaping @MainActor (String) -> Void,
              onCoursePlan: @escaping @MainActor (CourseBrief) async throws -> Void) async throws {
        if prompt.hasPrefix("<learnfold_assessment_discussion version=\"1\">") {
            let data = try assessmentLearningData(in: prompt)
            guard let question = data["opening_question"] as? String,
                  data["assessment_id"] as? String != nil else {
                throw assessmentFixtureError("The guided discussion did not supply an opening question.")
            }
            try recordReply(sessionID: sessionID, prompt: prompt, messageID: messageID, reply: question)
            onPartialResponse(question)
            return
        }
        if prompt.contains("Ion pumps need ATP.") {
            let reply = "Yes. ATP provides the energy that keeps ion pumps working."
            try recordReply(sessionID: sessionID, prompt: prompt, messageID: messageID, reply: reply)
            onPartialResponse(reply)
            return
        }
        if prompt.contains("My question: What can this proof reveal?") {
            guard prompt.contains("<current_course_page page_id=\"article-one\""),
                  prompt.contains("A proof can show that a statement is true while keeping its underlying secret private.") else {
                throw NSError(domain: "ReadingFixture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The first lesson context did not reach the dispatcher."
                ])
            }
            let reply = "Page-one discussion: a proof reveals validity without exposing the secret."
            try recordReply(sessionID: sessionID, prompt: prompt, messageID: messageID, reply: reply)
            onPartialResponse(reply)
            return
        }
        if prompt.contains("My question: Why is the challenge random?") {
            guard prompt.contains("<current_course_page page_id=\"article-two\""),
                  prompt.contains("Try describing a verification step without sharing the secret.") else {
                throw NSError(domain: "ReadingFixture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The current page context did not reach the dispatcher."
                ])
            }
            let reply = "The local chat fixture received your question and the current lesson content."
            try recordReply(sessionID: sessionID, prompt: prompt, messageID: messageID, reply: reply)
            onPartialResponse(reply)
            return
        }
        if let pageID = Self.explorationPageID(in: prompt) {
            try await writeExploration(
                pageID: pageID, prompt: prompt, workspaceID: workspaceID, courseDirectory: courseDirectory
            )
            onPartialResponse("The exploration is ready.")
            return
        }
        attempts += 1
        try await Task.sleep(for: .seconds(3))
        if attempts == 1, generationScenario == "connection-failure" {
            throw NSError(domain: "ReadingFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated connection failure"])
        }
        if attempts == 1, generationScenario == "reply-without-save" {
            onPartialResponse("The lesson is ready.")
            return
        }
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID, databaseURL: courseDirectory.appendingPathComponent(".course/course-library.sqlite"), rootTitle: "Reading fixture"
        )
        let page = try await repository.pageSnapshot(id: "article-three")
        let writesEmptyLesson = attempts == 1 && generationScenario == "empty-generated"
        let lessonMarkdown = CourseReadingFilmFixture.isEnabled
            ? CourseReadingFilmFixture.articleThreeGeneratedMarkdown
            : "## Working in a finite field\n\nArithmetic wraps around a fixed set of values. This is the final lesson in this local fixture."
        var document = try AppFlowyMarkdownCodec().decode(writesEmptyLesson ? "" : lessonMarkdown)
        document.root.data = page.document.root.data
        document.root.data["course_generation_status"] = .string(
            attempts == 1 && generationScenario == "content-without-completion" ? "pending_generation" : "generated"
        )
        try await repository.stageUserEdit(pageID: page.id, document: document)
        _ = try await repository.flushPendingUserEdits()
        onPartialResponse("The lesson is ready.")
    }

    private static func explorationPageID(in prompt: String) -> String? {
        guard prompt.contains("Generate only the existing exploration page"),
              let start = prompt.range(of: "Its native editor page ID is ") else { return nil }
        let tail = prompt[start.upperBound...]
        let id = tail.prefix { !$0.isWhitespace }
        return id.hasSuffix(".") ? String(id.dropLast()) : String(id)
    }

    /// Writes the exploration the way a real agent does: one revision-checked
    /// update that saves the content, the generated status, and a real title.
    /// Tests can slow the write down, or make the first one fail. The film
    /// course picks the exploration the fork asked for; per-fork delays and
    /// the optional release gate come from `ReadingFixtureExplorationPacing`.
    private func writeExploration(
        pageID: String, prompt: String, workspaceID: String, courseDirectory: URL
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        let forkIndex = explorationForks
        explorationForks += 1
        let write = explorationForks
        let film = CourseReadingFilmFixture.isEnabled
            ? CourseReadingFilmFixture.exploration(forPrompt: prompt) : nil
        let delay = environment["LEARNFOLD_READING_EXPLORATION_DELAY_SECONDS"].flatMap(Double.init)
            ?? ReadingFixtureExplorationPacing.delaySeconds(forFork: forkIndex)
        try await Task.sleep(for: .seconds(delay))
        try await ReadingFixtureExplorationPacing.waitForRelease(trigger: film?.trigger ?? "fork-\(forkIndex + 1)")
        if write == 1, environment["LEARNFOLD_READING_EXPLORATION_SCENARIO"] == "fail-first" {
            throw NSError(domain: "ReadingFixture", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Simulated exploration failure",
            ])
        }
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: courseDirectory.appendingPathComponent(".course/course-library.sqlite"),
            rootTitle: "Reading fixture"
        )
        let page = try await repository.pageSnapshot(id: pageID)
        let arguments: [String: Any] = [
            "page_id": pageID,
            "expected_revision": page.revision,
            "command": "replace_content",
            "new_str": film?.markdown ?? "## Why randomness matters\n\nIf the prover could predict the challenge, it could prepare an answer without knowing the secret. A random challenge removes that shortcut.\n\n## Keep going\n\nEach round halves a cheating prover's odds.",
            "properties": [
                "title": film?.title
                    ?? (write == 1 ? "Why the challenge must be random" : "Why the challenge must be random, part \(write)"),
                "generation_status": "generated",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let result = await repository.callTool(
            named: NativeEditorMCPToolCatalog.updatePage,
            argumentsJSON: String(decoding: data, as: UTF8.self)
        )
        if result.isError {
            throw NSError(domain: "ReadingFixture", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The fixture could not write the exploration page."
            ])
        }
    }

    /// Decode only the fixture's bounded JSON object after Rust's LEARNING_DATA
    /// marker. Review prompts append a schema, while discussion prompts append
    /// their closing control marker, so neither suffix is part of the object.
    private func assessmentLearningData(in prompt: String) throws -> [String: Any] {
        guard let marker = prompt.range(of: "\n\nLEARNING_DATA:\n") else {
            throw assessmentFixtureError("The assessment request has no learning data.")
        }
        let suffix = prompt[marker.upperBound...]
        guard let start = suffix.firstIndex(of: "{") else {
            throw assessmentFixtureError("The assessment request has no JSON object.")
        }
        var depth = 0
        var isQuoted = false
        var isEscaped = false
        for index in suffix[start...].indices.prefix(32_768) {
            let character = suffix[index]
            if isQuoted {
                if isEscaped { isEscaped = false }
                else if character == "\\" { isEscaped = true }
                else if character == "\"" { isQuoted = false }
            } else if character == "\"" {
                isQuoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let json = Data(suffix[start...index].utf8)
                    guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                        throw assessmentFixtureError("The learning data is not a JSON object.")
                    }
                    return object
                }
            }
        }
        throw assessmentFixtureError("The assessment learning data is incomplete or too large.")
    }

    private func assessmentFixtureError(_ message: String) -> NSError {
        NSError(domain: "ReadingFixture", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func recordReply(sessionID: UUID, prompt: String, messageID: UUID?, reply: String) throws {
        guard sessionID != courseSessionID else {
            throw NSError(domain: "ReadingFixture", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "A page question was sent to the course discussion session."
            ])
        }
        var messages = try transcript(sessionID: sessionID)
        let learnerID = (messageID ?? UUID()).uuidString.lowercased()
        let replyID = "reply-\(learnerID)"
        messages.append(.init(id: learnerID, role: .learner, text: prompt))
        messages.append(.init(id: replyID, role: .agent, text: reply))
        try persist(messages, sessionID: sessionID)
        let key = CourseExperienceStore.hostedChatKey(sessionID: sessionID)
        appStore?.ingestSourceEvents(key: key, source: .hosted, events: [
            .userMessage(clientMsgId: learnerID, text: prompt),
            .turnAccepted(clientMsgId: learnerID, turnId: learnerID),
            .turnStarted(turnId: learnerID),
        ])
        appStore?.ingestSourceEvents(key: key, source: .hosted, events: [
            .textSnapshot(itemId: replyID, channel: .answer, text: reply),
            .turnSettled(outcome: .completed),
        ])
    }

    private func transcriptURL(sessionID: UUID) -> URL {
        transcriptsRoot.appendingPathComponent("\(sessionID.uuidString).json")
    }

    private func transcript(sessionID: UUID) throws -> [PersistedMessage] {
        let url = transcriptURL(sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PersistedMessage].self, from: Data(contentsOf: url))
    }

    private func persist(_ messages: [PersistedMessage], sessionID: UUID) throws {
        try FileManager.default.createDirectory(at: transcriptsRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(messages).write(to: transcriptURL(sessionID: sessionID), options: .atomic)
    }
}
#endif
