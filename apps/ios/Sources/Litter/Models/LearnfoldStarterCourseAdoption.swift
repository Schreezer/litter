import Foundation
import NativeBlockEditorCore
import SQLite3

/// Recovers only the unchanged bundled practice pages imported by older CloudKit
/// clients. A learner workspace never gains approval merely from its name.
enum LearnfoldStarterCourseAdoption {
    private static let intentFilename = "starter-course-adoption.v1.json"
    private static let receiptFilename = "starter-course-install.json"
    private static let databasePath = ".course/course-library.sqlite"

    static func adopt(
        workspaceURL: URL,
        controlDirectory: URL,
        course: LearningCourse,
        brief: CourseBrief
    ) throws -> LearningCourse {
        let approvalDirectory = AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: workspaceURL)
        let intentURL = controlDirectory.appendingPathComponent(intentFilename)
        let intentWasPersisted = FileManager.default.fileExists(atPath: intentURL.path)
        var recorded: LearningCourse?
        if intentWasPersisted {
            let data = try CourseWorkspaceFileSystem(rootURL: controlDirectory).read(intentFilename, maximumBytes: 64 * 1_024)
            let candidate = try JSONDecoder().decode(LearningCourse.self, from: data)
            guard isBundledCourse(candidate) else { throw CocoaError(.fileWriteFileExists) }
            recorded = candidate
        } else {
            recorded = nil
        }
        let initialCourseData = try JSONEncoder().encode(recorded ?? course)
        let controlPending = try pendingWrites(root: controlDirectory, directories: [""], expectedData: initialCourseData)
        if recorded == nil, !controlPending.isEmpty {
            // A fully written, unrenamed first intent is itself recoverable.
            // Its exact payload must match this installation's selected provider.
            recorded = course
        }
        let planData = try JSONEncoder().encode(brief)
        let workspacePending = recorded == nil ? [] : try pendingWrites(
            root: workspaceURL, directories: ["", ".course"], expectedData: planData
        )
        let approvalPending = recorded == nil ? [] : try pendingWrites(
            root: approvalDirectory, directories: [""], expectedData: planData
        )

        let planFilenames = [AppleCourseApprovalPolicy.presentedPlanFilename, AppleCourseApprovalPolicy.approvedPlanFilename]
        let planPaths = Set(["course.json"] + planFilenames.map { ".course/\($0)" })
        let directoryPaths: Set<String> = recorded == nil ? [".course"] : [".course", "sources", "sources/originals"]
        try validateTree(
            workspaceURL,
            directories: directoryPaths,
            files: Set([databasePath, databasePath + "-wal", databasePath + "-shm"])
                .union(recorded == nil ? [] : planPaths)
                .union(workspacePending)
        )
        let approvalInsideControl = approvalDirectory.standardizedFileURL.deletingLastPathComponent()
            == controlDirectory.standardizedFileURL
        try validateTree(
            controlDirectory,
            directories: recorded != nil && approvalInsideControl ? ["approval"] : [],
            files: (recorded == nil ? [] : Set([intentFilename] + (approvalInsideControl ? planFilenames.map { "approval/\($0)" } : [])))
                .union(controlPending)
                .union(approvalInsideControl ? Set(approvalPending.map { "approval/\($0)" }) : [])
        )
        if !approvalInsideControl {
            try validateTree(
                approvalDirectory,
                directories: [],
                files: (recorded == nil ? [] : Set(planFilenames)).union(approvalPending)
            )
        }
        if recorded != nil {
            for path in planPaths {
                try requireMatchingPlanIfPresent(root: workspaceURL, path: path, brief: brief)
            }
            for filename in planFilenames {
                try requireMatchingPlanIfPresent(root: approvalDirectory, path: filename, brief: brief)
            }
        }

        let workspace = try readUnmodifiedWorkspace(databaseURL: workspaceURL.appendingPathComponent(databasePath))
        guard matchesBundledWorkspace(workspace, try LearnfoldStarterCourse.makeWorkspace()) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let adoptedCourse = recorded ?? course
        guard isBundledCourse(adoptedCourse) else { throw CocoaError(.fileWriteFileExists) }

        // The intent precedes every authorization write. A crash can resume only
        // this installation, after repeating the untouched-page and metadata checks.
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        let controlFiles = CourseWorkspaceFileSystem(rootURL: controlDirectory)
        if !intentWasPersisted {
            try controlFiles.write(try JSONEncoder().encode(adoptedCourse), to: intentFilename)
        }
        // Remove only complete, exact payloads whose randomly named temporary
        // files were left by our atomic writer before its rename. Unknown or
        // truncated artifacts have already failed validation and stay untouched.
        for (root, paths) in [(controlDirectory, controlPending), (workspaceURL, workspacePending), (approvalDirectory, approvalPending)] {
            for path in paths { try CourseWorkspaceFileSystem(rootURL: root).removeRecursively(path) }
        }
        let workspaceFiles = CourseWorkspaceFileSystem(rootURL: workspaceURL)
        try writeIfMissing(planData, root: workspaceURL, path: "course.json")
        for filename in planFilenames {
            try writeIfMissing(planData, root: workspaceURL, path: ".course/\(filename)")
        }
        try workspaceFiles.ensureDirectory("sources/originals")
        try FileManager.default.createDirectory(at: approvalDirectory, withIntermediateDirectories: true)
        for filename in planFilenames {
            try writeIfMissing(planData, root: approvalDirectory, path: filename)
        }
        try controlFiles.write(try JSONEncoder().encode(adoptedCourse), to: receiptFilename)
        return adoptedCourse
    }

    /// Dates are installation/read metadata, and block IDs are newly generated
    /// on each bundle decode. Every other page, item and document field must match.
    static func matchesBundledWorkspace(_ actual: PageWorkspace, _ expected: PageWorkspace) -> Bool {
        guard actual.rootPageID == expected.rootPageID,
              Set(actual.pages.keys) == Set(expected.pages.keys),
              Set(actual.items.keys) == Set(expected.items.keys) else { return false }
        for (id, page) in expected.pages {
            guard let candidate = actual.pages[id], candidate.id == page.id,
                  candidate.title == page.title, candidate.icon == page.icon,
                  candidate.parentID == page.parentID,
                  matchesBlock(candidate.document.root, page.document.root) else { return false }
        }
        for (id, item) in expected.items {
            guard let candidate = actual.items[id], candidate.id == item.id,
                  candidate.kind == item.kind, candidate.parentID == item.parentID,
                  candidate.sortKey == item.sortKey, candidate.title == item.title,
                  candidate.icon == item.icon, candidate.isFavorite == item.isFavorite,
                  candidate.trashedAt == item.trashedAt else { return false }
        }
        return true
    }

    private static func matchesBlock(_ actual: BlockNode, _ expected: BlockNode) -> Bool {
        if expected.data["block_id"] != nil {
            guard let blockID = actual.data["block_id"]?.stringValue, UUID(uuidString: blockID) != nil else { return false }
        } else if actual.data["block_id"] != nil {
            return false
        }
        guard actual.type == expected.type, actual.children.count == expected.children.count,
              actual.data.filter({ $0.key != "block_id" }) == expected.data.filter({ $0.key != "block_id" }) else { return false }
        return zip(actual.children, expected.children).allSatisfy { matchesBlock($0.0, $0.1) }
    }

    private static func isBundledCourse(_ course: LearningCourse) -> Bool {
        course.id == LearnfoldStarterCourse.workspaceID && course.workspaceID == course.id
            && course.title == LearnfoldStarterCourse.title && course.subtitle == LearnfoldStarterCourse.subtitle
            && course.accentHex == "1F6FEB" && course.progress == 0
            && course.lessonCount == LearnfoldStarterCourse.lessons.count && course.duration == "20–30 min"
            && course.status == .ready && course.agentThreadID == nil
            && course.appleSessionID == nil && course.hostedSessionID == nil
    }

    private static func validateTree(_ root: URL, directories: Set<String>, files: Set<String>) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue,
              try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteFileExists)
        }
        func walk(_ directory: URL, prefix: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                let path = prefix + child.lastPathComponent
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileWriteFileExists) }
                if values.isDirectory == true {
                    guard directories.contains(path) else { throw CocoaError(.fileWriteFileExists) }
                    try walk(child, prefix: path + "/")
                } else {
                    guard values.isRegularFile == true, files.contains(path) else { throw CocoaError(.fileWriteFileExists) }
                }
            }
        }
        try walk(root, prefix: "")
    }

    private static func requireMatchingPlanIfPresent(root: URL, path: String, brief: CourseBrief) throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return }
        let data = try CourseWorkspaceFileSystem(rootURL: root).read(path, maximumBytes: 256 * 1_024)
        guard try JSONDecoder().decode(CourseBrief.self, from: data) == brief else { throw CocoaError(.fileWriteFileExists) }
    }

    private static func writeIfMissing(_ data: Data, root: URL, path: String) throws {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { return }
        try CourseWorkspaceFileSystem(rootURL: root).write(data, to: path)
    }

    private static func pendingWrites(root: URL, directories: [String], expectedData: Data) throws -> Set<String> {
        var result: Set<String> = []
        let expected = try JSONSerialization.jsonObject(with: expectedData) as? NSDictionary
        for path in directories {
            let directory = path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let prefix = ".learnfold-write-"
                guard child.lastPathComponent.hasPrefix(prefix),
                      UUID(uuidString: String(child.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
                let relative = path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent
                let data = try CourseWorkspaceFileSystem(rootURL: root).read(relative, maximumBytes: 256 * 1_024)
                guard let pending = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                      let expected, pending.isEqual(expected) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                result.insert(relative)
            }
        }
        return result
    }

    /// A read-only SQLite snapshot avoids rewriting documents or their revisions.
    private static func readUnmodifiedWorkspace(databaseURL: URL) throws -> PageWorkspace {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 3_000)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        func query(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw CocoaError(.fileReadCorruptFile)
            }
            defer { sqlite3_finalize(statement) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
                try row(statement)
            }
        }
        func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var rootPageID: String?
        try query("SELECT value FROM metadata WHERE key = 'root_page_id'") { rootPageID = text($0, 0) }
        var historyCount: Int64 = -1
        try query("SELECT COUNT(*) FROM page_history") { historyCount = sqlite3_column_int64($0, 0) }
        guard historyCount == 0, let rootPageID else { throw CocoaError(.fileWriteFileExists) }
        var items: [String: NativeBlockEditorCore.LibraryItem] = [:]
        try query("SELECT id, kind, parent_id, sort_key, title, icon, is_favorite, trashed_at FROM library_items") { row in
            guard let id = text(row, 0), let kind = text(row, 1).flatMap(NativeBlockEditorCore.LibraryItemKind.init(rawValue:)),
                  let title = text(row, 4), title == title.trimmingCharacters(in: .whitespacesAndNewlines),
                  let icon = text(row, 5) else { throw CocoaError(.fileReadCorruptFile) }
            items[id] = NativeBlockEditorCore.LibraryItem(
                id: id, kind: kind, parentID: text(row, 2), sortKey: sqlite3_column_double(row, 3),
                title: title, icon: icon, isFavorite: sqlite3_column_int(row, 6) != 0,
                trashedAt: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 7))
            )
        }
        var pages: [String: PageRecord] = [:]
        try query("SELECT page_id, document_json, revision FROM page_documents") { row in
            guard let id = text(row, 0), let item = items[id], item.kind == .page,
                  sqlite3_column_int64(row, 2) == 1, let bytes = sqlite3_column_blob(row, 1),
                  sqlite3_column_bytes(row, 1) > 0, sqlite3_column_bytes(row, 1) <= 2 * 1_024 * 1_024 else {
                throw CocoaError(.fileWriteFileExists)
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 1)))
            try validateDocumentShape(data)
            let document = try JSONDecoder().decode(BlockDocument.self, from: data)
            guard document.flattenedNodes().allSatisfy({
                $0.node.stableBlockID.flatMap(UUID.init(uuidString:)) != nil
            }) else { throw CocoaError(.fileWriteFileExists) }
            pages[id] = PageRecord(id: id, title: item.title, icon: item.icon, parentID: item.parentID, document: document)
        }
        return try PageWorkspace(rootPageID: rootPageID, pages: pages, items: items)
    }

    private static func validateDocumentShape(_ data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(document.keys) == ["document"], let root = document["document"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func validateNode(_ node: [String: Any]) throws {
            guard Set(node.keys).isSubset(of: ["type", "data", "children"]), node["type"] is String,
                  node["data"] == nil || node["data"] is [String: Any],
                  node["children"] == nil || node["children"] is [[String: Any]] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for child in node["children"] as? [[String: Any]] ?? [] { try validateNode(child) }
        }
        try validateNode(root)
    }
}
