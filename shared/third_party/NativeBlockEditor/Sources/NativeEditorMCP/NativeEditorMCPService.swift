import Foundation
import NativeBlockEditorCore

public enum NativeEditorMCPError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case pageNotFound(String)
    case unsupportedCommand(String)
    case contentNotFound(String)
    case ambiguousContent(String, matches: Int)
    case protectedContent([String])
    case asyncTaskNotFound(String)
    case revisionConflict(pageID: String, expected: Int64, actual: Int64)
    case workspaceGenerationConflict(expected: Int64, actual: Int64)
}

extension NativeEditorMCPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        case let .pageNotFound(id): "Page \(id) was not found or is not accessible."
        case let .unsupportedCommand(command): "Unsupported page update command: \(command)"
        case let .contentNotFound(content): "The exact content was not found: \(content)"
        case let .ambiguousContent(content, matches):
            "The content matched \(matches) locations. Provide a unique old_str or explicitly replace all matches: \(content)"
        case let .protectedContent(items):
            "The operation would delete protected child pages or databases: \(items.joined(separator: ", ")). Set allow_deleting_content to true to proceed."
        case let .asyncTaskNotFound(id): "Async task \(id) was not found."
        case let .revisionConflict(pageID, expected, actual):
            "Page \(pageID) changed from revision \(expected) to \(actual). Fetch it again and retry against the new revision."
        case let .workspaceGenerationConflict(expected, actual):
            "The workspace changed from generation \(expected) to \(actual). Reload it and retry."
        }
    }

    public var code: String {
        switch self {
        case .invalidArguments, .unsupportedCommand, .contentNotFound, .ambiguousContent, .protectedContent:
            "validation_error"
        case .revisionConflict, .workspaceGenerationConflict:
            "conflict"
        case .pageNotFound, .asyncTaskNotFound:
            "object_not_found"
        }
    }
}

public struct NativeEditorPageSnapshot: Sendable {
    public let id: String
    public let title: String
    public let icon: String
    public let parentID: String?
    public let document: BlockDocument
    public let revision: Int64

    public init(page: PageRecord, revision: Int64) {
        id = page.id
        title = page.title
        icon = page.icon
        parentID = page.parentID
        document = page.document
        self.revision = revision
    }
}

public struct NativeEditorWorkspaceSnapshot: Sendable {
    public let workspace: PageWorkspace
    public let generation: Int64

    public init(workspace: PageWorkspace, generation: Int64) {
        self.workspace = workspace
        self.generation = generation
    }
}

/// A persistent, Notion-style agent facade over the native block engine.
///
/// Calls reload the SQLite library before reading or mutating it so a long-lived
/// MCP process does not intentionally operate from an old snapshot. Page content
/// crosses the boundary only as enhanced Markdown.
public actor NativeEditorMCPService {
    private struct AsyncTaskRecord: Sendable {
        enum Status: String, Sendable { case queued, running, retrying, succeeded, failed }

        var id: String
        var status: Status
        var operation: String
        var createdAt: Date
        var result: JSONValue? = nil
        var error: JSONValue? = nil
    }

    private let store: SQLiteLibraryStore
    private let markdownCodec = NotionEnhancedMarkdownCodec()
    private var workspace: PageWorkspace
    private var workspaceGeneration: Int64
    private var lastOpenPageID: String?
    private var asyncTasks: [String: AsyncTaskRecord] = [:]

    private init(
        store: SQLiteLibraryStore,
        workspace: PageWorkspace,
        workspaceGeneration: Int64,
        lastOpenPageID: String?
    ) {
        self.store = store
        self.workspace = workspace
        self.workspaceGeneration = workspaceGeneration
        self.lastOpenPageID = lastOpenPageID
    }

    /// `seedWorkspace` is an autoclosure so a caller can hand over an
    /// expensive import without paying for it on every open: it is evaluated
    /// only when the database holds no workspace yet. Callers must not decide
    /// that for themselves from the database file's existence — the file is
    /// created before the first workspace is committed, so an interrupted
    /// first open would otherwise be seeded with a blank "Home" forever.
    public static func open(
        databaseURL: URL,
        seedWorkspace: @autoclosure () -> PageWorkspace? = nil
    ) async throws -> NativeEditorMCPService {
        let store = try SQLiteLibraryStore(url: databaseURL)
        if let persisted = try await store.load() {
            return NativeEditorMCPService(
                store: store,
                workspace: persisted.workspace,
                workspaceGeneration: persisted.workspaceGeneration,
                lastOpenPageID: persisted.lastOpenPageID
            )
        }
        let workspace = seedWorkspace() ?? PageWorkspace(rootTitle: "Home")
        let workspaceGeneration = try await store.save(
            workspace,
            lastOpenPageID: workspace.rootPageID,
            recordHistory: false
        )
        return NativeEditorMCPService(
            store: store,
            workspace: workspace,
            workspaceGeneration: workspaceGeneration,
            lastOpenPageID: workspace.rootPageID
        )
    }

    public func callTool(
        named name: String,
        arguments: [String: JSONValue]
    ) async -> NativeEditorMCPToolResult {
        do {
            let value: JSONValue
            switch name {
            case NativeEditorMCPToolCatalog.search:
                value = try await search(arguments)
            case NativeEditorMCPToolCatalog.fetch:
                value = try await fetch(arguments)
            case NativeEditorMCPToolCatalog.createPages:
                value = try await createPages(arguments)
            case NativeEditorMCPToolCatalog.updatePage:
                value = try await updatePage(arguments)
            case NativeEditorMCPToolCatalog.movePages:
                value = try await movePages(arguments)
            case NativeEditorMCPToolCatalog.duplicatePage:
                value = try await duplicatePage(arguments)
            case NativeEditorMCPToolCatalog.getAsyncTask:
                value = try asyncTask(arguments)
            default:
                throw NativeEditorMCPError.invalidArguments("Unknown tool: \(name)")
            }
            return NativeEditorMCPToolResult(value: value)
        } catch {
            return NativeEditorMCPToolResult(value: errorValue(error), isError: true)
        }
    }

    public func search(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let query = try requiredString("query", in: arguments)
        let limit = min(100, max(1, arguments["limit"]?.intValue ?? 40))
        try await reload()
        let results = try await store.search(query, limit: limit)
        return .object([
            "object": "list",
            "type": "page_or_data_source",
            "results": .array(results.map { result in
                .object([
                    "object": "page",
                    "id": .string(result.pageID),
                    "title": .string(result.title),
                    "url": .string(pageURL(result.pageID)),
                    "highlight": .string(result.snippet),
                    "score": .number(result.score),
                ])
            }),
            "has_more": false,
            "next_cursor": .null,
        ])
    }

    public func fetch(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        let requestedID = try requiredString("id", in: arguments)
        try await reload()
        if requestedID == "self" { return identityValue() }
        let pageID = normalizedPageID(requestedID)
        guard let page = workspace.page(id: pageID), let item = workspace.item(id: pageID), item.trashedAt == nil else {
            throw NativeEditorMCPError.pageNotFound(pageID)
        }
        let revision = try await store.revision(for: pageID) ?? 0
        return pageMarkdownValue(page, revision: revision)
    }

    public func rootPageSnapshot() async throws -> NativeEditorPageSnapshot {
        try await pageSnapshot(id: workspace.rootPageID)
    }

    public func workspaceSnapshot() async throws -> PageWorkspace {
        try await workspaceSnapshotWithGeneration().workspace
    }

    public func workspaceSnapshotWithGeneration() async throws -> NativeEditorWorkspaceSnapshot {
        try await reload()
        return NativeEditorWorkspaceSnapshot(
            workspace: workspace,
            generation: workspaceGeneration
        )
    }

    /// Atomically replaces the complete workspace through the same validated
    /// SQLite transaction used by local learner and agent mutations.
    ///
    /// Cloud/import callers must perform their merge before invoking this
    /// method. The store records page history, rebuilds FTS, and emits a
    /// durable mutation receipt in the same commit.
    public func replaceWorkspace(_ replacement: PageWorkspace) async throws {
        try await reload()
        try await replaceWorkspace(
            replacement,
            expectedGeneration: workspaceGeneration
        )
    }

    /// Commits a fully staged workspace only if no editor, tool, or cloud
    /// writer changed the SQLite library after the caller read its generation.
    /// The generation check and complete replacement share one BEGIN IMMEDIATE
    /// transaction, so a losing caller cannot expose a partial workspace.
    public func replaceWorkspace(
        _ replacement: PageWorkspace,
        expectedGeneration: Int64
    ) async throws {
        try replacement.validate()
        let previousPageIDs = Set(workspace.pages.keys)
        let replacementPageIDs = Set(replacement.pages.keys)
        let changedPageIDs = previousPageIDs.union(replacementPageIDs)
        let committedGeneration = try await store.save(
            replacement,
            lastOpenPageID: replacement.pages[lastOpenPageID ?? ""] == nil
                ? replacement.rootPageID
                : lastOpenPageID,
            changedPageIDs: changedPageIDs,
            recordHistory: true,
            expectedWorkspaceGeneration: expectedGeneration
        )
        workspace = replacement
        workspaceGeneration = committedGeneration
        if workspace.pages[lastOpenPageID ?? ""] == nil {
            lastOpenPageID = workspace.rootPageID
        }
    }

    public func pendingSyncMutationReceipts(limit: Int = 256) async throws -> [LibraryMutationReceipt] {
        try await store.pendingMutationReceipts(limit: limit)
    }

    public func acknowledgeSyncMutationReceipts(ids: [String]) async throws {
        try await store.acknowledgeMutationReceipts(ids: ids)
    }

    public func pageSnapshot(id requestedID: String) async throws -> NativeEditorPageSnapshot {
        try await reload()
        let pageID = normalizedPageID(requestedID)
        guard let page = workspace.page(id: pageID), workspace.item(id: pageID)?.trashedAt == nil else {
            throw NativeEditorMCPError.pageNotFound(pageID)
        }
        return NativeEditorPageSnapshot(
            page: page,
            revision: try await store.revision(for: pageID) ?? 0
        )
    }

    public func saveDocument(
        _ document: BlockDocument,
        pageID: String,
        expectedRevision: Int64
    ) async throws -> NativeEditorPageSnapshot {
        try await reload()
        let normalizedID = normalizedPageID(pageID)
        guard workspace.page(id: normalizedID) != nil else {
            throw NativeEditorMCPError.pageNotFound(normalizedID)
        }
        try workspace.saveDocument(document, for: normalizedID)
        try await persistRevisionChecked(
            changedPageIDs: [normalizedID],
            pageID: normalizedID,
            expectedRevision: expectedRevision
        )
        return try await pageSnapshot(id: normalizedID)
    }

    public func createPages(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        if arguments["allow_async"]?.boolValue == true {
            return enqueue(operation: "create_pages", arguments: arguments)
        }
        return try await createPagesSynchronously(arguments)
    }

    public func updatePage(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        if arguments["allow_async"]?.boolValue == true {
            return enqueue(operation: "update_page", arguments: arguments)
        }
        return try await updatePageSynchronously(arguments)
    }

    public func movePages(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await reload()
        guard let ids = arguments["page_ids"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty else {
            throw NativeEditorMCPError.invalidArguments("page_ids must contain at least one page ID.")
        }
        guard let parentObject = arguments["new_parent"]?.objectValue,
              let destination = parentObject["page_id"]?.stringValue else {
            throw NativeEditorMCPError.invalidArguments("new_parent.page_id is required.")
        }
        guard let destinationItem = workspace.item(id: destination), destinationItem.trashedAt == nil else {
            throw NativeEditorMCPError.pageNotFound(destination)
        }

        var changedPageIDs: Set<String> = []
        for rawID in ids {
            let pageID = normalizedPageID(rawID)
            guard let page = workspace.page(id: pageID), let oldParentID = page.parentID else {
                throw NativeEditorMCPError.pageNotFound(pageID)
            }
            try workspace.moveItem(pageID, to: destination)
            if oldParentID != destination {
                if var oldParent = workspace.page(id: oldParentID)?.document {
                    convertOwnedPageBlockToReference(pageID: pageID, nodes: &oldParent.root.children)
                    try workspace.saveDocument(oldParent, for: oldParentID)
                    changedPageIDs.insert(oldParentID)
                }
                if var newParent = workspace.page(id: destination)?.document,
                   !containsOwnedPage(pageID, in: newParent),
                   let movedPage = workspace.page(id: pageID) {
                    newParent.root.children.append(.childPage(
                        pageID: pageID,
                        title: movedPage.title,
                        icon: movedPage.icon
                    ))
                    try workspace.saveDocument(newParent, for: destination)
                    changedPageIDs.insert(destination)
                }
            }
        }
        try await persist(changedPageIDs: changedPageIDs)
        return .object([
            "object": "list",
            "results": .array(ids.compactMap { id in workspace.page(id: normalizedPageID(id)).map(pageSummaryValue) }),
        ])
    }

    public func duplicatePage(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        _ = try requiredString("page_id", in: arguments)
        return enqueue(operation: "duplicate_page", arguments: arguments)
    }

    public func asyncTask(_ arguments: [String: JSONValue]) throws -> JSONValue {
        let id = try requiredString("task_id", in: arguments)
        guard let task = asyncTasks[id] else { throw NativeEditorMCPError.asyncTaskNotFound(id) }
        return asyncTaskValue(task)
    }

    private func createPagesSynchronously(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await reload()
        guard let pageInputs = arguments["pages"]?.arrayValue, !pageInputs.isEmpty else {
            throw NativeEditorMCPError.invalidArguments("pages must contain at least one page.")
        }
        let parentID = arguments["parent"]?.objectValue?["page_id"]?.stringValue ?? workspace.libraryRootID
        guard let parent = workspace.item(id: parentID), parent.trashedAt == nil else {
            throw NativeEditorMCPError.pageNotFound(parentID)
        }
        var created: [PageRecord] = []
        var changedPageIDs: Set<String> = []
        for inputValue in pageInputs {
            guard let input = inputValue.objectValue,
                  let properties = input["properties"]?.objectValue,
                  let title = titleValue(properties["title"]) else {
                throw NativeEditorMCPError.invalidArguments("Each page requires properties.title.")
            }
            let content = input["content"]?.stringValue ?? ""
            let icon = input["icon"]?.stringValue ?? "doc.text"
            let provisionalID = UUID().uuidString.lowercased()
            var document = try markdownCodec.decode(
                content,
                pageID: provisionalID,
                workspace: workspace
            )
            applyCourseMetadata(properties, to: &document)
            let page = try workspace.createPage(
                title: title,
                parentID: parentID,
                icon: icon,
                document: document,
                id: provisionalID
            )
            created.append(page)
            changedPageIDs.insert(page.id)
            if workspace.page(id: parentID) != nil {
                var parentDocument = workspace.page(id: parentID)?.document ?? .blank()
                parentDocument.root.children.append(.childPage(pageID: page.id, title: page.title, icon: page.icon))
                try workspace.saveDocument(parentDocument, for: parentID)
                changedPageIDs.insert(parentID)
            }
        }
        try await persist(changedPageIDs: changedPageIDs)
        return .object([
            "object": "list",
            "results": .array(created.compactMap { workspace.page(id: $0.id).map(pageSummaryValue) }),
        ])
    }

    private func updatePageSynchronously(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await reload()
        let pageID = normalizedPageID(try requiredString("page_id", in: arguments))
        let command = try requiredString("command", in: arguments)
        guard let expectedRevisionValue = arguments["expected_revision"]?.intValue,
              expectedRevisionValue >= 0 else {
            throw NativeEditorMCPError.invalidArguments("expected_revision is required and must be non-negative.")
        }
        let expectedRevision = Int64(expectedRevisionValue)
        let actualRevision = try await store.revision(for: pageID) ?? 0
        guard expectedRevision == actualRevision else {
            throw NativeEditorMCPError.revisionConflict(
                pageID: pageID,
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        guard let page = workspace.page(id: pageID), workspace.item(id: pageID)?.trashedAt == nil else {
            throw NativeEditorMCPError.pageNotFound(pageID)
        }

        switch command {
        case "update_properties":
            guard let properties = arguments["properties"]?.objectValue,
                  !properties.isEmpty else {
                throw NativeEditorMCPError.invalidArguments("properties must contain at least one update.")
            }
            var changedPageIDs: Set<String> = []
            if let title = titleValue(properties["title"]) {
                try workspace.renamePage(pageID, to: title)
            }
            if var document = workspace.page(id: pageID)?.document,
               applyCourseMetadata(properties, to: &document) {
                try workspace.saveDocument(document, for: pageID)
                changedPageIDs.insert(pageID)
            }
            try await persistRevisionChecked(
                changedPageIDs: changedPageIDs,
                pageID: pageID,
                expectedRevision: expectedRevision
            )
        case "trash":
            let shouldTrash = arguments["in_trash"]?.boolValue ?? true
            if shouldTrash { try workspace.trashItem(pageID) }
            else { try workspace.restoreItem(pageID) }
            try await persistRevisionChecked(
                changedPageIDs: [],
                pageID: pageID,
                expectedRevision: expectedRevision
            )
        case "update_content", "replace_content", "insert_content", "replace_content_range":
            let oldMarkdown = markdownCodec.encode(page.document)
            let newMarkdown = try updatedMarkdown(oldMarkdown, command: command, arguments: arguments)
            var updatedDocument = try markdownCodec.decode(
                newMarkdown,
                pageID: pageID,
                workspace: workspace,
                previousDocument: page.document
            )
            preserveCourseMetadata(from: page.document, in: &updatedDocument)
            if let properties = arguments["properties"]?.objectValue {
                if let title = titleValue(properties["title"]) {
                    try workspace.renamePage(pageID, to: title)
                }
                applyCourseMetadata(properties, to: &updatedDocument)
            }
            reconcileStableIDs(from: page.document.root.children, into: &updatedDocument.root.children)
            updatedDocument.ensureStableBlockIDs()
            if arguments["allow_deleting_content"]?.boolValue != true {
                let removed = removedProtectedContent(from: page.document, after: updatedDocument)
                guard removed.isEmpty else { throw NativeEditorMCPError.protectedContent(removed) }
            }
            try workspace.saveDocument(updatedDocument, for: pageID)
            try await persistRevisionChecked(
                changedPageIDs: [pageID],
                pageID: pageID,
                expectedRevision: expectedRevision
            )
        default:
            throw NativeEditorMCPError.unsupportedCommand(command)
        }

        guard let updated = workspace.page(id: pageID) else { throw NativeEditorMCPError.pageNotFound(pageID) }
        return pageMarkdownValue(
            updated,
            revision: try await store.revision(for: pageID) ?? expectedRevision
        )
    }

    private func duplicatePageSynchronously(_ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await reload()
        let pageID = normalizedPageID(try requiredString("page_id", in: arguments))
        guard workspace.page(id: pageID) != nil else { throw NativeEditorMCPError.pageNotFound(pageID) }
        let previousPageIDs = Set(workspace.pages.keys)
        let duplicated = try workspace.duplicateItem(pageID)
        var changedPageIDs = Set(workspace.pages.keys).subtracting(previousPageIDs)
        if let parentID = duplicated.parentID,
           var parentDocument = workspace.page(id: parentID)?.document,
           let page = workspace.page(id: duplicated.id) {
            parentDocument.root.children.append(.childPage(pageID: page.id, title: page.title, icon: page.icon))
            try workspace.saveDocument(parentDocument, for: parentID)
            changedPageIDs.insert(parentID)
        }
        try await persist(changedPageIDs: changedPageIDs)
        guard let page = workspace.page(id: duplicated.id) else {
            throw NativeEditorMCPError.pageNotFound(duplicated.id)
        }
        return pageSummaryValue(page)
    }

    private func updatedMarkdown(
        _ markdown: String,
        command: String,
        arguments: [String: JSONValue]
    ) throws -> String {
        switch command {
        case "update_content":
            guard let updates = arguments["content_updates"]?.arrayValue, !updates.isEmpty else {
                throw NativeEditorMCPError.invalidArguments("content_updates is required for update_content.")
            }
            var result = markdown
            for value in updates {
                guard let update = value.objectValue,
                      let oldString = update["old_str"]?.stringValue,
                      let newString = update["new_str"]?.stringValue,
                      !oldString.isEmpty else {
                    throw NativeEditorMCPError.invalidArguments("Each content update requires a non-empty old_str and a new_str.")
                }
                result = try replacingExactMatches(
                    in: result,
                    oldString: oldString,
                    newString: newString,
                    replaceAll: update["replace_all_matches"]?.boolValue == true
                )
            }
            return result
        case "replace_content":
            guard let replacement = arguments["new_str"]?.stringValue else {
                throw NativeEditorMCPError.invalidArguments("new_str is required for replace_content.")
            }
            return replacement
        case "insert_content":
            guard let content = arguments["content"]?.stringValue else {
                throw NativeEditorMCPError.invalidArguments("content is required for insert_content.")
            }
            if let after = arguments["after"]?.stringValue {
                guard arguments["position"] == nil else {
                    throw NativeEditorMCPError.invalidArguments("Provide either after or position, not both.")
                }
                let selection = try uniqueEllipsisSelection(after, in: markdown)
                return inserting(content, after: selection, in: markdown)
            }
            let position = arguments["position"]?.objectValue?["type"]?.stringValue ?? "end"
            switch position {
            case "start": return content + (markdown.isEmpty ? "" : "\n" + markdown)
            case "end": return markdown + (markdown.isEmpty ? "" : "\n") + content
            default: throw NativeEditorMCPError.invalidArguments("position.type must be start or end.")
            }
        case "replace_content_range":
            guard let content = arguments["content"]?.stringValue,
                  let selector = arguments["content_range"]?.stringValue else {
                throw NativeEditorMCPError.invalidArguments("content and content_range are required.")
            }
            let range = try uniqueEllipsisSelection(selector, in: markdown)
            var result = markdown
            result.replaceSubrange(range, with: content)
            return result
        default:
            throw NativeEditorMCPError.unsupportedCommand(command)
        }
    }

    private func replacingExactMatches(
        in source: String,
        oldString: String,
        newString: String,
        replaceAll: Bool
    ) throws -> String {
        let ranges = exactRanges(of: oldString, in: source)
        guard !ranges.isEmpty else { throw NativeEditorMCPError.contentNotFound(oldString) }
        guard ranges.count == 1 || replaceAll else {
            throw NativeEditorMCPError.ambiguousContent(oldString, matches: ranges.count)
        }
        var result = source
        for range in (replaceAll ? ranges : [ranges[0]]).reversed() {
            result.replaceSubrange(range, with: newString)
        }
        return result
    }

    private func exactRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = haystack.startIndex
        while cursor < haystack.endIndex,
              let range = haystack.range(of: needle, range: cursor ..< haystack.endIndex) {
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }

    private func uniqueEllipsisSelection(
        _ selector: String,
        in source: String
    ) throws -> Range<String.Index> {
        let parts = selector.components(separatedBy: "...")
        if parts.count == 1 {
            let ranges = exactRanges(of: selector, in: source)
            guard !ranges.isEmpty else { throw NativeEditorMCPError.contentNotFound(selector) }
            guard ranges.count == 1 else { throw NativeEditorMCPError.ambiguousContent(selector, matches: ranges.count) }
            return ranges[0]
        }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw NativeEditorMCPError.invalidArguments("Ellipsis selectors must be 'start text...end text'.")
        }
        let starts = exactRanges(of: parts[0], in: source)
        var candidates: [Range<String.Index>] = []
        for start in starts {
            guard let end = source.range(of: parts[1], range: start.upperBound ..< source.endIndex) else { continue }
            candidates.append(start.lowerBound ..< end.upperBound)
        }
        guard !candidates.isEmpty else { throw NativeEditorMCPError.contentNotFound(selector) }
        guard candidates.count == 1 else { throw NativeEditorMCPError.ambiguousContent(selector, matches: candidates.count) }
        return candidates[0]
    }

    private func inserting(
        _ content: String,
        after range: Range<String.Index>,
        in source: String
    ) -> String {
        var result = source
        let separator = content.isEmpty ? "" : "\n"
        result.insert(contentsOf: separator + content, at: range.upperBound)
        return result
    }

    private func reconcileStableIDs(from oldNodes: [BlockNode], into newNodes: inout [BlockNode]) {
        let matches = longestCommonSubsequence(oldNodes, newNodes)
        var oldCursor = 0
        var newCursor = 0
        for (oldIndex, newIndex) in matches + [(oldNodes.count, newNodes.count)] {
            reconcileChangedGap(
                old: Array(oldNodes[oldCursor ..< oldIndex]),
                new: &newNodes,
                newRange: newCursor ..< newIndex
            )
            if oldIndex < oldNodes.count, newIndex < newNodes.count {
                // The agent-visible enhanced Markdown is unchanged. Keep the
                // complete native node so styling and extension payload fields
                // that are intentionally absent from the compact MCP surface
                // cannot be erased by an unrelated page edit.
                newNodes[newIndex] = oldNodes[oldIndex]
            }
            oldCursor = oldIndex + 1
            newCursor = newIndex + 1
        }
    }

    private func reconcileChangedGap(
        old: [BlockNode],
        new: inout [BlockNode],
        newRange: Range<Int>
    ) {
        guard old.count == newRange.count else { return }
        for offset in old.indices {
            let newIndex = newRange.lowerBound + offset
            copyStableIdentity(from: old[offset], into: &new[newIndex])
        }
    }

    private func copyStableIdentity(from old: BlockNode, into new: inout BlockNode) {
        if let id = old.stableBlockID { new.data["block_id"] = .string(id) }
        reconcileStableIDs(from: old.children, into: &new.children)
    }

    private func longestCommonSubsequence(
        _ old: [BlockNode],
        _ new: [BlockNode]
    ) -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        let oldSignatures = old.map(agentVisibleSignature)
        let newSignatures = new.map(agentVisibleSignature)
        var lengths = Array(
            repeating: Array(repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[i][j] = oldSignatures[i] == newSignatures[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if oldSignatures[i] == newSignatures[j] {
                matches.append((i, j)); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    private func agentVisibleSignature(_ node: BlockNode) -> String {
        markdownCodec.encode(BlockDocument(root: BlockNode(type: "page", children: [node])))
    }

    private func removedProtectedContent(
        from oldDocument: BlockDocument,
        after newDocument: BlockDocument
    ) -> [String] {
        let before = protectedContent(in: oldDocument)
        let after = Set(protectedContent(in: newDocument))
        return before.filter { !after.contains($0) }
    }

    private func protectedContent(in document: BlockDocument) -> [String] {
        document.flattenedNodes().compactMap { _, node in
            guard node.type == "nbe/child_page" || node.type == "nbe/database" else { return nil }
            if node.type == "nbe/child_page" {
                return "page:\(node.data["page_id"]?.stringValue ?? node.stableBlockID ?? "unknown")"
            }
            return "database:\(node.stableBlockID ?? node.data["title"]?.stringValue ?? "unknown")"
        }
    }

    private func enqueue(
        operation: String,
        arguments: [String: JSONValue]
    ) -> JSONValue {
        let id = "task_" + UUID().uuidString.lowercased()
        let record = AsyncTaskRecord(
            id: id,
            status: .queued,
            operation: operation,
            createdAt: .now
        )
        asyncTasks[id] = record
        Task { await self.runAsyncTask(id: id, operation: operation, arguments: arguments) }
        return asyncTaskValue(record)
    }

    private func runAsyncTask(
        id: String,
        operation: String,
        arguments: [String: JSONValue]
    ) async {
        guard var task = asyncTasks[id] else { return }
        task.status = .running
        asyncTasks[id] = task
        do {
            var synchronousArguments = arguments
            synchronousArguments["allow_async"] = .bool(false)
            let result: JSONValue
            switch operation {
            case "create_pages": result = try await createPagesSynchronously(synchronousArguments)
            case "update_page": result = try await updatePageSynchronously(synchronousArguments)
            case "duplicate_page": result = try await duplicatePageSynchronously(synchronousArguments)
            default: throw NativeEditorMCPError.unsupportedCommand(operation)
            }
            task.status = .succeeded
            task.result = result
        } catch {
            task.status = .failed
            task.error = errorValue(error)
        }
        asyncTasks[id] = task
    }

    private func asyncTaskValue(_ task: AsyncTaskRecord) -> JSONValue {
        var value: [String: JSONValue] = [
            "object": "async_task",
            "id": .string(task.id),
            "status": .string(task.status.rawValue),
            "created_time": .string(iso8601(task.createdAt)),
            "status_url": .string("native-editor://async-task/\(task.id)"),
            "poll_after_seconds": 2,
            "operation": .object([
                "surface": "mcp",
                "name": .string(task.operation),
            ]),
        ]
        if let result = task.result { value["result"] = result }
        if let error = task.error { value["error"] = error }
        return .object(value)
    }

    private func reload() async throws {
        guard let persisted = try await store.load() else { return }
        workspace = persisted.workspace
        workspaceGeneration = persisted.workspaceGeneration
        lastOpenPageID = persisted.lastOpenPageID
    }

    private func persist(
        changedPageIDs: Set<String>,
        expectedRevisions: [String: Int64] = [:]
    ) async throws {
        workspaceGeneration = try await store.save(
            workspace,
            lastOpenPageID: lastOpenPageID,
            changedPageIDs: changedPageIDs,
            recordHistory: !changedPageIDs.isEmpty,
            expectedRevisions: expectedRevisions,
            expectedWorkspaceGeneration: workspaceGeneration
        )
    }

    private func persistRevisionChecked(
        changedPageIDs: Set<String>,
        pageID: String,
        expectedRevision: Int64
    ) async throws {
        do {
            try await persist(
                changedPageIDs: changedPageIDs,
                expectedRevisions: [pageID: expectedRevision]
            )
        } catch LibraryStoreError.revisionConflict(let conflictPageID, let expected, let actual) {
            throw NativeEditorMCPError.revisionConflict(
                pageID: conflictPageID,
                expected: expected,
                actual: actual
            )
        } catch LibraryStoreError.workspaceGenerationConflict(let expected, let actual) {
            throw NativeEditorMCPError.workspaceGenerationConflict(
                expected: expected,
                actual: actual
            )
        }
    }

    private func identityValue() -> JSONValue {
        let access = Dictionary(uniqueKeysWithValues: NativeEditorMCPToolCatalog.tools.map { tool in
            let baseName = tool.name
                .replacingOccurrences(of: "native-editor-", with: "")
                .replacingOccurrences(of: "-", with: "_")
            return (baseName, JSONValue.string("available"))
        })
        return .object([
            "object": "self",
            "workspace": .object([
                "id": .string(workspace.rootPageID),
                "name": "Native Editor",
                "root_page_id": .string(workspace.rootPageID),
            ]),
            "user": .object([
                "id": "local-user",
                "name": "Local User",
                "type": "person",
            ]),
            "current_tool_access": .object(access),
        ])
    }

    private func pageMarkdownValue(_ page: PageRecord, revision: Int64 = 0) -> JSONValue {
        let unknownIDs = page.document.flattenedNodes().compactMap { _, node -> JSONValue? in
            guard !Self.agentVisibleBlockTypes.contains(node.type), let id = node.stableBlockID else { return nil }
            return .string(id)
        }
        return .object([
            "object": "page_markdown",
            "id": .string(page.id),
            "title": .string(page.title),
            "url": .string(pageURL(page.id)),
            "parent": parentValue(page.parentID),
            "markdown": .string(markdownCodec.encode(page.document)),
            "truncated": false,
            "unknown_block_ids": .array(unknownIDs),
            "in_trash": .bool(workspace.item(id: page.id)?.trashedAt != nil),
            "created_time": .string(iso8601(page.createdAt)),
            "last_edited_time": .string(iso8601(page.updatedAt)),
            "revision": .integer(Int(revision)),
            "course_metadata": courseMetadataValue(page.document),
        ])
    }

    @discardableResult
    private func applyCourseMetadata(
        _ properties: [String: JSONValue],
        to document: inout BlockDocument
    ) -> Bool {
        let mappings = [
            ("course_node_id", "course_node_id"),
            ("course_role", "course_role"),
            ("generation_status", "course_generation_status"),
            ("bootstrap_status", "course_bootstrap_status"),
            ("origin_question", "course_origin_question"),
            ("origin_anchor", "course_origin_anchor"),
        ]
        var changed = false
        for (property, dataKey) in mappings {
            guard let value = properties[property]?.stringValue else { continue }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  document.root.data[dataKey]?.stringValue != normalized else { continue }
            document.root.data[dataKey] = .string(normalized)
            changed = true
        }
        return changed
    }

    private func preserveCourseMetadata(
        from previousDocument: BlockDocument,
        in updatedDocument: inout BlockDocument
    ) {
        for key in [
            "course_node_id",
            "course_role",
            "course_generation_status",
            "course_bootstrap_status",
            "course_origin_question",
            "course_origin_anchor",
        ] where updatedDocument.root.data[key] == nil {
            updatedDocument.root.data[key] = previousDocument.root.data[key]
        }
    }

    private func courseMetadataValue(_ document: BlockDocument) -> JSONValue {
        .object([
            "node_id": document.root.data["course_node_id"] ?? .null,
            "role": document.root.data["course_role"] ?? .null,
            "generation_status": document.root.data["course_generation_status"] ?? .null,
            "bootstrap_status": document.root.data["course_bootstrap_status"] ?? .null,
            "origin_question": document.root.data["course_origin_question"] ?? .null,
        ])
    }

    private func pageSummaryValue(_ page: PageRecord) -> JSONValue {
        .object([
            "object": "page",
            "id": .string(page.id),
            "title": .string(page.title),
            "url": .string(pageURL(page.id)),
            "parent": parentValue(page.parentID),
            "in_trash": .bool(workspace.item(id: page.id)?.trashedAt != nil),
            "created_time": .string(iso8601(page.createdAt)),
            "last_edited_time": .string(iso8601(page.updatedAt)),
        ])
    }

    private func pageURL(_ id: String) -> String {
        "native-editor://page/\(id)"
    }

    private func parentValue(_ parentID: String?) -> JSONValue {
        guard let parentID else { return .null }
        if parentID == workspace.libraryRootID {
            return .object(["type": "workspace", "workspace": true])
        }
        if workspace.page(id: parentID) != nil {
            return .object(["type": "page_id", "page_id": .string(parentID)])
        }
        return .object(["type": "folder_id", "folder_id": .string(parentID)])
    }

    private func normalizedPageID(_ value: String) -> String {
        guard let components = URLComponents(string: value), components.scheme == "native-editor" else {
            return value
        }
        if components.host == "page", let id = components.path.split(separator: "/").first {
            return String(id)
        }
        return value
    }

    private func requiredString(
        _ key: String,
        in arguments: [String: JSONValue]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw NativeEditorMCPError.invalidArguments("\(key) is required.")
        }
        return value
    }

    private func titleValue(_ value: JSONValue?) -> String? {
        if let title = value?.stringValue { return title }
        if let object = value?.objectValue {
            return object["title"]?.stringValue ?? object["name"]?.stringValue
        }
        return nil
    }

    private func containsOwnedPage(_ pageID: String, in document: BlockDocument) -> Bool {
        document.flattenedNodes().contains { _, node in
            node.type == "nbe/child_page" && node.data["page_id"]?.stringValue == pageID
        }
    }

    private func convertOwnedPageBlockToReference(pageID: String, nodes: inout [BlockNode]) {
        for index in nodes.indices {
            if nodes[index].type == "nbe/child_page",
               nodes[index].data["page_id"]?.stringValue == pageID {
                nodes[index].type = "nbe/page_reference"
            }
            convertOwnedPageBlockToReference(pageID: pageID, nodes: &nodes[index].children)
        }
    }

    private func errorValue(_ error: Error) -> JSONValue {
        let code = (error as? NativeEditorMCPError)?.code ?? "internal_error"
        return .object([
            "object": "error",
            "code": .string(code),
            "message": .string(error.localizedDescription),
        ])
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let agentVisibleBlockTypes: Set<String> = [
        "paragraph", "heading", "quote", "divider", "code", "nbe/formula",
        "bulleted_list", "numbered_list", "todo_list", "image", "table",
        "columns", "column", "nbe/media", "link_preview", "nbe/child_page",
        "nbe/page_reference", "nbe/database",
    ]
}
