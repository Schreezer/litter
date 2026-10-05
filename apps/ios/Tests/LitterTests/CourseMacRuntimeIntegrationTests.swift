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
}
