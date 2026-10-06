import FoundationModels
import NativeBlockEditorCore
import XCTest
@testable import Litter

@MainActor
final class CourseMacRuntimeIntegrationTests: XCTestCase {
    func testUnavailableEmptyCodexThreadCanRestoreItsSavedCourseContext() {
        XCTAssertTrue(CourseExperienceStore.isLostCodexThreadError(
            ClientError.ThreadHistoryUnavailable
        ))
        XCTAssertFalse(CourseExperienceStore.isLostCodexThreadError(
            ClientError.Transport("The connection was interrupted")
        ))
        XCTAssertFalse(CourseExperienceStore.isLostCodexThreadError(
            ClientError.AuthenticationRequired
        ))
        XCTAssertFalse(CourseExperienceStore.isLostCodexThreadError(
            ClientError.Rpc("server error -32000: no rollout found for thread id requested-thread")
        ))
        XCTAssertFalse(CourseExperienceStore.isLostCodexThreadError(
            ClientError.Rpc("server error -32600: no rollout found for thread id another-thread")
        ))
    }

    func testEmptyDiscussionRecoveryRequiresTheBoundUnsubmittedCodexDiscussion() {
        let key = ThreadKey(serverId: "local-mac", threadId: "empty-thread")
        var discussion = CourseSelectionDiscussion(
            courseID: "course-a", pageID: "lesson-a", pageTitle: "First lesson"
        )
        discussion.agentRuntimeKind = .codex
        discussion.serverID = key.serverId
        discussion.threadID = key.threadId
        XCTAssertTrue(CourseExperienceStore.emptyCodexDiscussionCanBeRecreated(discussion, for: key))

        discussion.hasSubmittedQuestion = true
        XCTAssertFalse(CourseExperienceStore.emptyCodexDiscussionCanBeRecreated(discussion, for: key))
        discussion.hasSubmittedQuestion = false
        discussion.serverID = "another-server"
        XCTAssertFalse(CourseExperienceStore.emptyCodexDiscussionCanBeRecreated(discussion, for: key))
        discussion.serverID = key.serverId
        discussion.threadID = "another-thread"
        XCTAssertFalse(CourseExperienceStore.emptyCodexDiscussionCanBeRecreated(discussion, for: key))
        discussion.threadID = key.threadId
        discussion.status = .resolved
        XCTAssertFalse(CourseExperienceStore.emptyCodexDiscussionCanBeRecreated(discussion, for: key))
    }

    func testNativeWorkspaceUsesRepositoryDirectoryWithSpaces() {
        let workspace = URL(fileURLWithPath: "/Users/learner/Course Library/course-a", isDirectory: true)
        XCTAssertEqual(
            CourseRuntimePaths.workspacePath(
                workspaceID: "course-a", workspaceURL: workspace, fileSystem: .nativeMac
            ),
            workspace.path
        )
        XCTAssertEqual(
            CourseRuntimePaths.originalSourcePath(
                filename: "Chapter 1.pdf", workspaceID: "course-a",
                workspaceURL: workspace, fileSystem: .nativeMac
            ),
            workspace.path + "/sources/originals/Chapter 1.pdf"
        )
        XCTAssertEqual(
            CourseRuntimePaths.workspacePath(
                workspaceID: "course-a", workspaceURL: workspace, fileSystem: .embeddedIOS
            ),
            "/mnt/apps/Courses/course-a"
        )
    }

    func testMacRestoresLegacySourcePathsWithoutAcceptingOtherWorkspaces() {
        let workspace = URL(fileURLWithPath: "/Users/learner/Courses/course-a", isDirectory: true)
        XCTAssertEqual(
            CourseRuntimePaths.originalSourceFilename(
                runtimePath: "/mnt/apps/Courses/course-a/sources/originals/book.pdf",
                workspaceID: "course-a", workspaceURL: workspace, fileSystem: .nativeMac
            ),
            "book.pdf"
        )
        for rejectedPath in [
            "/mnt/apps/Courses/course-b/sources/originals/book.pdf",
            workspace.path + "/sources/originals/../secret.pdf",
            workspace.path + "/sources/originals/subfolder/book.pdf",
            workspace.path + "/sources/originals/..",
            workspace.path + "/sources/originals/",
            "/Users/learner/Other/book.pdf",
        ] {
            XCTAssertNil(CourseRuntimePaths.originalSourceFilename(
                runtimePath: rejectedPath, workspaceID: "course-a",
                workspaceURL: workspace, fileSystem: .nativeMac
            ), rejectedPath)
        }
    }

    func testMacThreadKeepsNativeEditorAndPlanApprovalWithNativeShellInstructions() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:54321/mcp"))
        let launch = try CourseExperienceStore.courseThreadLaunchConfig(
            runtimeID: .codex,
            workspaceID: "course-a",
            modelID: nil,
            usesNativeMacShell: true,
            courseMCPURL: endpoint
        )
        XCTAssertEqual(launch.sandbox, .readOnly)
        XCTAssertEqual(
            CourseExperienceStore.courseTurnSandboxPolicy(runtimeID: .codex, usesNativeMacShell: true),
            .readOnly(access: .fullAccess, networkAccess: false)
        )
        XCTAssertEqual(launch.configJSON, try CourseExperienceStore.courseMCPConfigJSON(endpoint: endpoint))
        let instructions = try XCTUnwrap(launch.developerInstructions)
        XCTAssertTrue(instructions.contains("Codex's built-in shell"))
        XCTAssertTrue(instructions.contains("Never edit the native course database through the shell"))
        XCTAssertTrue(instructions.contains("Do not build until the learner explicitly approves a plan ID and revision"))
        XCTAssertTrue(instructions.contains("`workspace_id`: `course-a`"))
        XCTAssertFalse(instructions.contains("The shell cannot use network sockets"))
        let resumed = launch.threadResumeRequest(
            threadId: "saved-thread", cwdOverride: "/Users/learner/Courses/course-a"
        )
        XCTAssertEqual(resumed.cwd, "/Users/learner/Courses/course-a")
        XCTAssertEqual(resumed.sandbox, .readOnly)
        XCTAssertEqual(resumed.configJson, launch.configJSON)
    }

    func testMacMCPToolCatalogOmitsIPhoneShellAndKeepsRevisionSafeEditor() throws {
        let tools = try CourseAgentTools.mcpToolDefinitions(
            includePresentPlan: false, includeCourseBash: false
        )
        XCTAssertFalse(tools.contains(where: { $0.name == CourseAgentTools.courseBash }))
        XCTAssertFalse(tools.contains(where: { $0.name == CourseAgentTools.presentPlan }))
        let edit = try XCTUnwrap(tools.first(where: { $0.name == "native-editor-update-page" }))
        XCTAssertFalse(edit.readOnly)
        XCTAssertTrue((edit.inputSchema["required"] as? [String])?.contains("workspace_id") == true)
        XCTAssertTrue(tools.contains(where: { $0.name == "native-editor-fetch" && $0.readOnly }))
        XCTAssertTrue(try CourseAgentTools.mcpToolDefinitions().contains(where: {
            $0.name == CourseAgentTools.courseBash
        }))
    }

    func testMacIngestionReceiptsPointToNativeShellAndRelativeManifest() {
        let prompt = CourseExperienceStore.appendingIngestionReceipts(
            to: "Use this source",
            receipts: [CourseSourceIngestionReceipt(
                id: "source-1", sourceName: "Book", manifestRelativePath: ".course/ingestion/source-1.json",
                expectedExtractedRelativePath: "sources/extracted/source-1.txt"
            )],
            usesNativeMacShell: true
        )
        XCTAssertTrue(prompt.contains("learner's Mac"))
        XCTAssertTrue(prompt.contains("Codex's built-in shell"))
        XCTAssertTrue(prompt.contains("manifest=.course/ingestion/source-1.json"))
        XCTAssertFalse(prompt.contains("phone-executed course_bash"))
    }

#if targetEnvironment(macCatalyst)
    func testImportedDocumentUsesNativeAttachmentPathAndSurvivesRelaunch() async throws {
        let suiteName = "CourseMacRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Course Mac Paths \(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Learner source.txt")
        try Data("Learner evidence".utf8).write(to: source)
        let courses = root.appendingPathComponent("Courses", isDirectory: true)
        let store = CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: courses)
        store.beginNewCourse()
        try await store.importDocumentSources([source])
        let imported = try XCTUnwrap(store.sources.first)
        XCTAssertTrue(imported.runtimePath?.hasPrefix(store.nativeCourseDirectory().path) == true)
        let attachments = CourseExperienceStore.courseFileAttachments(
            sources: [imported], runtimeID: .codex, appServerIsLocal: true
        )
        XCTAssertEqual(attachments.first?.path, imported.runtimePath)
        let relaunched = CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: courses)
        XCTAssertEqual(relaunched.sources.first?.runtimePath, imported.runtimePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.runtimePath)))
    }

    func testMacProtocolDoesNotAdvertiseUnsupportedIPhoneShell() async throws {
        let response = await CourseMCPProtocol.handleJSONRPC(
            body: try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": .object([:]),
            ])),
            authorizedWorkspaceID: "tool-list-test"
        )
        let decoded = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(response.body))
        let tools = try XCTUnwrap(decoded.objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0.objectValue?["name"]?.stringValue })
        XCTAssertFalse(names.contains(CourseAgentTools.courseBash))
        XCTAssertTrue(names.contains("native-editor-fetch"))
    }
#endif

    // MARK: - Live Apple On-Device

    /// Runs the real on-device model through a whole course: plan, approval,
    /// the first lesson, then every kind of exploration the learner can fork.
    /// Set TEST_RUNNER_LEARNFOLD_RUN_APPLE_LIVE=1 and select only this test.
    func testAppleOnDeviceLiveCourseAndExplorations() async throws {
        guard ProcessInfo.processInfo.environment["LEARNFOLD_RUN_APPLE_LIVE"] == "1" else {
            throw XCTSkip("Set LEARNFOLD_RUN_APPLE_LIVE=1 to run the live Apple On-Device course test.")
        }
        guard #available(iOS 26.4, macCatalyst 26.4, *) else {
            throw XCTSkip("Exact Foundation Models context APIs require OS 26.4 or later.")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple On-Device is unavailable: \(SystemLanguageModel.default.availability)")
        }
        let topic = ProcessInfo.processInfo.environment["LEARNFOLD_APPLE_LIVE_TOPIC"]
            ?? "how vaccines train the immune system"
        let provider = CourseAgentProvider.appleOnDevice
        let runtime = SystemAppleCourseAgentRuntime()
        var sessionID = UUID()
        let workspaceID = "apple-live-mac-\(sessionID.uuidString.lowercased())"
        let suite = "CourseMacRuntimeIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CourseExperienceStore(
            defaults: defaults,
            environment: ["SNAPPY_SKIP_AGENT_SETUP": "1"],
            appleRuntime: runtime
        )
        let courseDirectory = store.courseDatabaseURL(workspaceID: workspaceID)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer {
            runtime.remove(sessionID: sessionID, workspaceID: workspaceID)
            if ProcessInfo.processInfo.environment["LEARNFOLD_APPLE_LIVE_KEEP"] != "1" {
                try? FileManager.default.removeItem(at: courseDirectory)
            }
        }
        var issues: [String] = []
        func report(_ line: String) { print("APPLE-LIVE| \(line)") }

        @discardableResult
        func send(_ step: String, _ prompt: String) async -> (reply: String, plans: [CourseBrief], error: String?) {
            var reply = ""
            var plans: [CourseBrief] = []
            let started = Date()
            do {
                try await runtime.send(
                    sessionID: sessionID,
                    providerID: provider,
                    workspaceID: workspaceID,
                    prompt: prompt,
                    onAccepted: {},
                    onPartialResponse: { reply = $0 },
                    onCoursePlan: { plans.append($0) }
                )
                report("\(step) ok in \(Int(Date().timeIntervalSince(started)))s reply=\(reply.prefix(300).debugDescription)")
                return (reply, plans, nil)
            } catch {
                report("\(step) THREW after \(Int(Date().timeIntervalSince(started)))s: \(error.localizedDescription)")
                return (reply, plans, error.localizedDescription)
            }
        }

        // 1. Plan.
        // The learner retries in a new turn after a rejected plan, so count how often that happens.
        var planning = await send("plan#1", "I want to learn \(topic). I'm a curious beginner. Make a short one-chapter course plan and present it for my approval.")
        var planAttempts = 1
        while planning.plans.isEmpty, planAttempts < 4 {
            issues.append("plan attempt \(planAttempts) failed: \(planning.error ?? planning.reply)")
            runtime.remove(sessionID: sessionID, workspaceID: workspaceID)
            sessionID = UUID()
            planAttempts += 1
            planning = await send("plan#\(planAttempts)", "I want to learn \(topic). I'm a curious beginner. Make a short one-chapter course plan and present it for my approval.")
        }
        let plan = try XCTUnwrap(planning.plans.last, "No plan was presented after \(planAttempts) attempts: \(planning.error ?? planning.reply)")
        report("plan title=\(plan.title.debugDescription) chapters=\(plan.chapters.map(\.title))")
        if let issue = AppleCoursePlanValidator.issue(in: plan, requiresTypedHierarchy: true) {
            issues.append("plan invalid: \(issue)")
        }

        // 2. Approve, as the app does.
        let repository = try await CourseDocumentRegistry.shared.repository(
            workspaceID: workspaceID,
            databaseURL: store.courseDatabaseURL(workspaceID: workspaceID),
            rootTitle: plan.title
        )
        try await repository.presentPlan(plan)
        try await repository.approvePlan(plan)
        let target = try await store.prepareApprovedCourseShell(brief: plan, workspaceID: workspaceID)
        await send("first-lesson", CourseExperienceStore.approvedCourseGenerationPrompt(
            brief: plan, runtimeID: provider, target: target
        ))

        func check(_ label: String, nodeID: String, pageID: String, placeholder: String?) async throws -> CourseLearningNode? {
            let outline = try await repository.outline()
            guard let node = CourseExplorationMap.node(withID: nodeID, in: outline.learningPages),
                  node.pageID == pageID else {
                issues.append("\(label): node vanished from the outline")
                return nil
            }
            let page = try await repository.pageSnapshot(id: pageID)
            let markdown = AppFlowyMarkdownCodec().encode(page.document)
            let ready = node.status == .generated && CourseExperienceStore.generatedLessonIsReady(page)
            report("\(label) status=\(node.status) ready=\(ready) title=\(page.title.debugDescription) words=\(markdown.split(whereSeparator: \.isWhitespace).count)")
            report("\(label) markdown<<<\n\(markdown)\n>>>")
            if !ready { issues.append("\(label): not ready (status \(node.status))") }
            let fences = markdown.components(separatedBy: "```learnfold-assessment").dropFirst()
            let checks = fences.compactMap { fence in
                fence.components(separatedBy: "```").first.flatMap {
                    parseCourseAssessmentBlock(body: $0).assessment
                }
            }
            report("\(label) checks=\(checks.map(\.prompt))")
            // A check the model can't make valid is dropped, not shown broken.
            if checks.isEmpty { report("\(label) NOTE: no understanding check") }
            if markdown.contains("&quot;") || markdown.contains("{…}") || markdown.contains("stable_slug_id") {
                issues.append("\(label): raw data leaked into the page")
            }
            if let placeholder, page.title == placeholder {
                issues.append("\(label): kept placeholder title \(placeholder.debugDescription)")
            }
            return node
        }
        let lessonNode = try await check("first-lesson", nodeID: target.nodeID, pageID: target.pageID, placeholder: nil)
        let lessonPageID = try XCTUnwrap(lessonNode?.pageID)
        let lessonTitle = try await repository.pageSnapshot(id: lessonPageID).title
        let lessonMarkdown = AppFlowyMarkdownCodec().encode(try await repository.pageSnapshot(id: lessonPageID).document)
        let passage = lessonMarkdown
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.split(separator: " ").count >= 8 && !$0.hasPrefix("#") && !$0.hasPrefix("`") }
            .map { String($0.prefix(140)) }

        // 3. Explorations, written the way the app writes them on the course agent.
        var explored: [String] = []
        func explore(_ label: String, _ request: CourseExplorationRequest) async throws -> CourseLearningNode? {
            var request = request
            request.exploredTitles = explored
            let node = try await store.forkExploration(request, in: LearningCourse(
                id: workspaceID, title: plan.title, subtitle: "", accentHex: "007AFF", progress: 0,
                lessonCount: 1, duration: "", status: .ready, workspaceID: workspaceID,
                agentRuntimeKind: provider
            ))
            try await store.persistAppleGenerationTarget(for: node, workspaceID: workspaceID)
            await send(label, CourseExperienceStore.explorationGenerationPrompt(for: node, request: request))
            let checked = try await check(label, nodeID: node.id, pageID: try XCTUnwrap(node.pageID), placeholder: request.placeholderTitle)
            if let pageID = checked?.pageID {
                explored.append(try await repository.pageSnapshot(id: pageID).title)
            }
            return checked
        }
        let deeper = try await explore("deeper", CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .deeper
        ))
        _ = try await explore("sideways", CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .sideways
        ))
        _ = try await explore("wider", CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .wider
        ))
        _ = try await explore("question", CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .question,
            question: "Why do some vaccines need boosters but others last for life?"
        ))
        if let passage {
            _ = try await explore("passage", CourseExplorationRequest(
                parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .question,
                question: CourseExplorePassageIntent.allCases.first?.question, quotedPassage: passage
            ))
        }
        if let deeperPageID = deeper?.pageID {
            let deeperTitle = try await repository.pageSnapshot(id: deeperPageID).title
            _ = try await explore("nested", CourseExplorationRequest(
                parentPageID: deeperPageID, parentTitle: deeperTitle, direction: .deeper
            ))
        }
        _ = try await explore("synthesis", CourseExplorationRequest(
            parentPageID: lessonPageID, parentTitle: lessonTitle, direction: .synthesis
        ))

        // 4. A planned lesson keeps its approved title after all of that.
        let finalOutline = try await repository.outline()
        let plannedTitle = CourseExplorationMap.node(withID: target.nodeID, in: finalOutline.learningPages)?.title
        if plannedTitle != target.title { issues.append("planned title changed to \(plannedTitle ?? "nil")") }
        report("explorations=\(CourseExplorationMap.explorations(in: finalOutline.learningPages).map(\.title))")
        report("course dir=\(courseDirectory.path)")
        report("ISSUES=\(issues)")
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }
}
