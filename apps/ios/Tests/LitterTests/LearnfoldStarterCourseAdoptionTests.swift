import NativeBlockEditorCore
import SQLite3
import XCTest
@testable import Litter

@MainActor
final class LearnfoldStarterCourseAdoptionTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let root: URL
        let suiteName: String
        @MainActor func store() -> CourseExperienceStore {
            CourseExperienceStore(defaults: defaults, environment: [:], coursesRootURL: root)
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() throws -> Fixture {
        let suiteName = "LearnfoldStarterCourseAdoptionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: "snappy.course.agentSetupComplete")
        defaults.set("codex", forKey: "snappy.course.selectedAgent")
        defaults.set("original-model", forKey: "snappy.course.selectedModel")
        return Fixture(defaults: defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName), suiteName: suiteName)
    }

    @discardableResult
    private func seed(_ store: CourseExperienceStore, workspace: PageWorkspace? = nil) async throws -> SQLiteLibraryStore {
        let library = try SQLiteLibraryStore(url: store.courseDatabaseURL(workspaceID: LearnfoldStarterCourse.workspaceID))
        let workspace = try workspace ?? LearnfoldStarterCourse.makeWorkspace()
        try await library.save(workspace, lastOpenPageID: workspace.rootPageID, recordHistory: false)
        return library
    }

    func testAdoptsExactLegacyCloudImportWithoutChangingDocumentsAndIsIdempotent() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let library = try await seed(store)
        let beforeLoad = try await library.load()
        let before = try XCTUnwrap(beforeLoad)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let savedPages = try encoder.encode(before.workspace.pages)

        await store.installStarterCourseIfNeeded()
        XCTAssertNil(store.starterCourseInstallationError)
        let course = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        XCTAssertEqual(course.agentModelID, "original-model")
        XCTAssertTrue(AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: try XCTUnwrap(store.courseDirectory(for: course))))
        let afterLoad = try await library.load()
        let after = try XCTUnwrap(afterLoad)
        XCTAssertEqual(try encoder.encode(after.workspace.pages), savedPages)
        XCTAssertEqual(after.workspaceGeneration, before.workspaceGeneration)
        for id in after.workspace.pages.keys {
            let revision = try await library.revision(for: id)
            let history = try await library.history(for: id)
            XCTAssertEqual(revision, 1)
            XCTAssertTrue(history.isEmpty)
        }
        await store.installStarterCourseIfNeeded()
        XCTAssertEqual(store.courses, [course])
    }

    func testBundleComparisonRejectsDocumentMetadataAndHierarchyChanges() throws {
        let expected = try LearnfoldStarterCourse.makeWorkspace()
        XCTAssertTrue(LearnfoldStarterCourseAdoption.matchesBundledWorkspace(try LearnfoldStarterCourse.makeWorkspace(), expected))
        var changed = expected
        var document = try XCTUnwrap(changed.page(id: LearnfoldStarterCourse.lessons[0].id)).document
        document.root.data["learner_note"] = .string("Keep this edit")
        try changed.saveDocument(document, for: LearnfoldStarterCourse.lessons[0].id)
        XCTAssertFalse(LearnfoldStarterCourseAdoption.matchesBundledWorkspace(changed, expected))
        changed = expected
        try changed.toggleFavorite(expected.rootPageID)
        XCTAssertFalse(LearnfoldStarterCourseAdoption.matchesBundledWorkspace(changed, expected))
        changed = expected
        _ = try changed.createPage(title: "My explainer", parentID: expected.rootPageID)
        XCTAssertFalse(LearnfoldStarterCourseAdoption.matchesBundledWorkspace(changed, expected))
    }

    func testChangedPageIsPreservedAndNeverApproved() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        var workspace = try LearnfoldStarterCourse.makeWorkspace()
        let pageID = LearnfoldStarterCourse.lessons[0].id
        var document = try XCTUnwrap(workspace.page(id: pageID)).document
        document.root.children.append(.paragraph("My own note."))
        try workspace.saveDocument(document, for: pageID)
        let library = try await seed(store, workspace: workspace)
        let before = try await library.load()
        let savedNote = before?.workspace.page(id: pageID)?.document.root.children.last?.data
        await store.installStarterCourseIfNeeded()
        XCTAssertNotNil(store.starterCourseInstallationError)
        XCTAssertTrue(store.courses.isEmpty)
        let persisted = try await library.load()
        let loaded = try XCTUnwrap(persisted)
        XCTAssertEqual(loaded.workspace.page(id: pageID)?.document.root.children.last?.data, savedNote)
        XCTAssertFalse(AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: fixture.root.appendingPathComponent(LearnfoldStarterCourse.workspaceID)))
    }

    func testUnchangedTextWithPriorRevisionOrHistoryIsRejected() async throws {
        for sql in [
            "UPDATE page_documents SET revision = 2 WHERE page_id = 'learnfold-getting-started-root'",
            "INSERT INTO page_history (id, page_id, document_json, created_at, label) SELECT 'prior-edit', page_id, document_json, 0, 'prior edit' FROM page_documents LIMIT 1",
        ] {
            let fixture = try fixture()
            defer { fixture.cleanup() }
            let store = fixture.store()
            _ = try await seed(store)
            try execute(sql, at: store.courseDatabaseURL(workspaceID: LearnfoldStarterCourse.workspaceID))
            await store.installStarterCourseIfNeeded()
            XCTAssertNotNil(store.starterCourseInstallationError)
            XCTAssertTrue(store.courses.isEmpty)
        }
    }

    func testExtraArtifactAndUnrecordedProtectedPlanAreRejected() async throws {
        for protected in [false, true] {
            let fixture = try fixture()
            defer { fixture.cleanup() }
            let store = fixture.store()
            _ = try await seed(store)
            let workspaceURL = fixture.root.appendingPathComponent(LearnfoldStarterCourse.workspaceID)
            let directory = protected ? AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: workspaceURL) : workspaceURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("keep me".utf8).write(to: directory.appendingPathComponent(protected ? "presented-plan.json" : "my-source.txt"))
            await store.installStarterCourseIfNeeded()
            XCTAssertNotNil(store.starterCourseInstallationError)
            XCTAssertTrue(store.courses.isEmpty)
        }
    }

    func testInterruptedAdoptionResumesRecordedProviderWithoutReplacingPages() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        _ = try await seed(store)
        await store.installStarterCourseIfNeeded()
        let original = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
        let control = store.courseControlDirectory(workspaceID: LearnfoldStarterCourse.workspaceID)
        try FileManager.default.removeItem(at: control.appendingPathComponent("starter-course-install.json"))
        try FileManager.default.removeItem(at: control.appendingPathComponent("starter-course-installed.v1"))
        try removePostReceiptArtifacts(control)
        fixture.defaults.removeObject(forKey: CourseExperienceStore.starterCourseInstalledKey)
        fixture.defaults.set(try JSONEncoder().encode([LearningCourse]()), forKey: "snappy.course.savedCourses")
        fixture.defaults.set("different-model", forKey: "snappy.course.selectedModel")
        let resumed = fixture.store()
        await resumed.installStarterCourseIfNeeded()
        XCTAssertNil(resumed.starterCourseInstallationError)
        XCTAssertEqual(resumed.courses, [original])
    }

    func testCompletePendingIntentAndPlanWritesRecoverAcrossPreRenameKillBoundaries() async throws {
        for pendingIntent in [true, false] {
            let fixture = try fixture()
            defer { fixture.cleanup() }
            let store = fixture.store()
            let library = try await seed(store)
            await store.installStarterCourseIfNeeded()
            let original = try XCTUnwrap(store.course(withID: LearnfoldStarterCourse.workspaceID))
            let brief = try XCTUnwrap(store.courseBrief(for: original))
            let control = store.courseControlDirectory(workspaceID: LearnfoldStarterCourse.workspaceID)
            let workspaceURL = try XCTUnwrap(store.courseDirectory(for: original))
            for filename in ["starter-course-install.json", "starter-course-installed.v1"] {
                try FileManager.default.removeItem(at: control.appendingPathComponent(filename))
            }
            try removePostReceiptArtifacts(control)
            let pendingDirectory: URL
            let pendingData: Data
            if pendingIntent {
                // Kill after fully writing the first intent's temporary file,
                // before its rename and before any approval files are created.
                try FileManager.default.removeItem(at: control.appendingPathComponent("starter-course-adoption.v1.json"))
                try FileManager.default.removeItem(at: AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: workspaceURL))
                for path in ["course.json", ".course/presented-plan.json", ".course/approved-plan.json", "sources"] {
                    try FileManager.default.removeItem(at: workspaceURL.appendingPathComponent(path))
                }
                pendingDirectory = control
                pendingData = try JSONEncoder().encode(original)
            } else {
                // The durable intent exists, but a shell-mirror plan write was
                // interrupted after fsync and before its final-name rename.
                try FileManager.default.removeItem(at: workspaceURL.appendingPathComponent(".course/approved-plan.json"))
                pendingDirectory = workspaceURL.appendingPathComponent(".course")
                pendingData = try JSONEncoder().encode(brief)
            }
            let pendingURL = pendingDirectory.appendingPathComponent(".learnfold-write-\(UUID().uuidString.lowercased())")
            try pendingData.write(to: pendingURL)
            fixture.defaults.removeObject(forKey: CourseExperienceStore.starterCourseInstalledKey)
            fixture.defaults.set(try JSONEncoder().encode([LearningCourse]()), forKey: "snappy.course.savedCourses")
            let before = try await library.load()
            let resumed = fixture.store()
            await resumed.installStarterCourseIfNeeded()
            XCTAssertNil(resumed.starterCourseInstallationError)
            XCTAssertEqual(resumed.courses, [original])
            XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path))
            let after = try await library.load()
            XCTAssertEqual(after?.workspaceGeneration, before?.workspaceGeneration)
            XCTAssertTrue(AppleCourseApprovalPolicy.isLatestPlanApproved(courseDirectory: workspaceURL))
        }
    }

    func testUnknownPendingWritePayloadIsPreservedAndRejectsAdoption() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        _ = try await seed(store)
        let control = store.courseControlDirectory(workspaceID: LearnfoldStarterCourse.workspaceID)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let pendingURL = control.appendingPathComponent(".learnfold-write-\(UUID().uuidString.lowercased())")
        let unrelated = Data("{\"learnerNote\":\"Keep this\"}".utf8)
        try unrelated.write(to: pendingURL)
        await store.installStarterCourseIfNeeded()
        XCTAssertNotNil(store.starterCourseInstallationError)
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertEqual(try Data(contentsOf: pendingURL), unrelated)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private func removePostReceiptArtifacts(_ control: URL) throws {
        // persistCourses creates these only after the adoption receipt commits.
        // A pre-receipt process kill cannot already have these later artifacts.
        for filename in ["continuation.json", "transcript-projections.json"] {
            let url = control.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
