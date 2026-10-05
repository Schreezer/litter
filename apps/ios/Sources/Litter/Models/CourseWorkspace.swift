import Foundation

enum CourseWorkspaceError: LocalizedError, Equatable {
    case unavailable
    case invalidRelativePath
    case fileNotFound
    case fileTooLarge
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "This course’s files are not available on this device."
        case .invalidRelativePath:
            return "That file is outside the course workspace."
        case .fileNotFound:
            return "That course file no longer exists."
        case .fileTooLarge:
            return "That file is too large to preview in the app."
        case .unreadableText:
            return "That file could not be read as text."
        }
    }
}

enum CourseFileKind: String, Hashable, Sendable {
    case folder
    case markdown
    case json
    case pdf
    case image
    case sourceCode
    case text
    case other
}

struct CourseFileNode: Identifiable, Hashable, Sendable {
    let relativePath: String
    let name: String
    let kind: CourseFileKind
    let byteCount: Int64?
    let children: [CourseFileNode]

    var id: String { relativePath }
    var isDirectory: Bool { kind == .folder }

    var immediateFileCount: Int {
        children.filter { !$0.isDirectory }.count
    }

    var immediateFolderCount: Int {
        children.filter(\.isDirectory).count
    }

    var descendantFileCount: Int {
        children.reduce(0) { count, child in
            count + (child.isDirectory ? child.descendantFileCount : 1)
        }
    }

    var descendantFolderCount: Int {
        children.reduce(0) { count, child in
            count + (child.isDirectory ? 1 + child.descendantFolderCount : 0)
        }
    }
}

struct CourseWorkspaceSnapshot: Equatable, Sendable {
    let rootURL: URL
    let nodes: [CourseFileNode]
    let fileCount: Int
    let folderCount: Int

    var firstLessonPath: String? {
        flattenedFiles.first(where: {
            $0.name.caseInsensitiveCompare("lesson.md") == .orderedSame
                && $0.relativePath.hasPrefix("chapters/")
        })?.relativePath
    }

    var flattenedFiles: [CourseFileNode] {
        nodes.flatMap(Self.flattenedFiles(in:))
    }

    var directoryPaths: Set<String> {
        Set(nodes.flatMap(Self.directoryPaths(in:)))
    }

    static func load(from rootURL: URL, fileManager: FileManager = .default) throws -> Self {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CourseWorkspaceError.unavailable
        }

        let nodes = try loadChildren(
            in: rootURL,
            rootURL: rootURL,
            relativeParent: "",
            fileManager: fileManager
        )
        let fileCount = nodes.reduce(0) { count, node in
            count + (node.isDirectory ? node.descendantFileCount : 1)
        }
        let folderCount = nodes.reduce(0) { count, node in
            count + (node.isDirectory ? 1 + node.descendantFolderCount : 0)
        }
        return Self(rootURL: rootURL, nodes: nodes, fileCount: fileCount, folderCount: folderCount)
    }

    static func validatedFileURL(
        relativePath: String,
        rootURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw CourseWorkspaceError.invalidRelativePath
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw CourseWorkspaceError.invalidRelativePath
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CourseWorkspaceError.fileNotFound
        }
        return candidate
    }

    static func relativePath(for fileURL: URL, rootURL: URL) -> String? {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else { return nil }
        // `URL.path` is already decoded. Decoding again renamed any file whose
        // real name contains an escape-like sequence ("report%20v2.md" became
        // "report v2.md"), and returned nil outright for names percent-decoding
        // rejects ("50%.md"), hiding those files from the workspace entirely.
        return String(candidate.path.dropFirst(prefix.count))
    }

    static func readText(
        relativePath: String,
        rootURL: URL,
        maximumBytes: Int = 5_000_000,
        fileManager: FileManager = .default
    ) throws -> String {
        let url = try validatedFileURL(relativePath: relativePath, rootURL: rootURL, fileManager: fileManager)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumBytes {
            throw CourseWorkspaceError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else { throw CourseWorkspaceError.fileTooLarge }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let unicode = String(data: data, encoding: .unicode) { return unicode }
        throw CourseWorkspaceError.unreadableText
    }

    private static func loadChildren(
        in directoryURL: URL,
        rootURL: URL,
        relativeParent: String,
        fileManager: FileManager
    ) throws -> [CourseFileNode] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let nodes = try contents.compactMap { url -> CourseFileNode? in
            if relativeParent.isEmpty, url.lastPathComponent == ".course" { return nil }
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isSymbolicLink == true { return nil }

            let relativePath = relativeParent.isEmpty
                ? url.lastPathComponent
                : "\(relativeParent)/\(url.lastPathComponent)"
            if values.isDirectory == true {
                let children = try loadChildren(
                    in: url,
                    rootURL: rootURL,
                    relativeParent: relativePath,
                    fileManager: fileManager
                )
                return CourseFileNode(
                    relativePath: relativePath,
                    name: url.lastPathComponent,
                    kind: .folder,
                    byteCount: nil,
                    children: children
                )
            }
            guard values.isRegularFile == true else { return nil }
            return CourseFileNode(
                relativePath: relativePath,
                name: url.lastPathComponent,
                kind: fileKind(for: url),
                byteCount: values.fileSize.map(Int64.init),
                children: []
            )
        }
        return nodes.sorted(by: nodeSort)
    }

    private static func fileKind(for url: URL) -> CourseFileKind {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "json": return .json
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return .image
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "kt", "java", "c", "h", "cpp", "sh", "rb":
            return .sourceCode
        case "txt", "csv", "yaml", "yml", "toml", "xml": return .text
        default: return .other
        }
    }

    private static func nodeSort(_ lhs: CourseFileNode, _ rhs: CourseFileNode) -> Bool {
        let left = sortPriority(for: lhs.name)
        let right = sortPriority(for: rhs.name)
        if left != right { return left < right }
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func sortPriority(for name: String) -> Int {
        switch name.lowercased() {
        case "index.md": return 0
        case "course.json": return 1
        case "context": return 2
        case "sources": return 3
        case "chapters": return 4
        case "assets": return 5
        case "originals": return 10
        case "extracted": return 11
        case "readme.md": return 20
        case "lesson.md": return 21
        case "practice.md": return 22
        case "project.md": return 23
        case "examples": return 24
        default: return 100
        }
    }

    private static func flattenedFiles(in node: CourseFileNode) -> [CourseFileNode] {
        node.isDirectory ? node.children.flatMap(flattenedFiles(in:)) : [node]
    }

    private static func directoryPaths(in node: CourseFileNode) -> [String] {
        guard node.isDirectory else { return [] }
        return [node.relativePath] + node.children.flatMap(directoryPaths(in:))
    }
}

enum CourseLearningPathResolver {
    static func resolve(
        brief: CourseBrief,
        snapshot: CourseWorkspaceSnapshot?
    ) -> [CourseLearningNode] {
        if let explicit = brief.learningPath, !explicit.isEmpty {
            let markdownPaths = Set(
                snapshot?.flattenedFiles
                    .filter { $0.kind == .markdown }
                    .map(\.relativePath) ?? []
            )
            return explicit.map { reconcile($0, availableMarkdownPaths: markdownPaths) }
        }
        return fallbackPath(brief: brief, snapshot: snapshot)
    }

    static func overlayGeneratingStatus(
        in nodes: [CourseLearningNode],
        targetNodeID: String?
    ) -> [CourseLearningNode] {
        overlayGeneratingStatus(in: nodes, targetNodeIDs: targetNodeID.map { [$0] } ?? [])
    }

    /// Several pages can be written at once: the course agent's page plus
    /// any explorations their own agents are writing.
    static func overlayGeneratingStatus(
        in nodes: [CourseLearningNode],
        targetNodeIDs: Set<String>
    ) -> [CourseLearningNode] {
        guard !targetNodeIDs.isEmpty else { return nodes }
        return nodes.map { overlayGeneratingStatus(in: $0, targetNodeIDs: targetNodeIDs).node }
    }

    private static func overlayGeneratingStatus(
        in node: CourseLearningNode,
        targetNodeIDs: Set<String>
    ) -> (node: CourseLearningNode, containsTarget: Bool) {
        var result = node
        var containsTarget = false
        result.children = node.children.map { child in
            let overlaid = overlayGeneratingStatus(in: child, targetNodeIDs: targetNodeIDs)
            containsTarget = containsTarget || overlaid.containsTarget
            return overlaid.node
        }
        if targetNodeIDs.contains(node.id) {
            result.status = .generating
            return (result, true)
        }
        if containsTarget, result.kind == .folder, result.status != .generating {
            result.status = .partiallyGenerated
        }
        return (result, containsTarget)
    }

    private static func reconcile(
        _ node: CourseLearningNode,
        availableMarkdownPaths: Set<String>
    ) -> CourseLearningNode {
        guard node.kind == .folder else {
            var result = node
            if node.status == .generated,
               (node.relativePath == nil || !availableMarkdownPaths.contains(node.relativePath ?? "")) {
                result.status = .pendingGeneration
            }
            return result
        }

        var result = node
        result.children = node.children.map {
            reconcile($0, availableMarkdownPaths: availableMarkdownPaths)
        }
        guard node.status != .generating, !result.children.isEmpty else { return result }
        let statuses = result.children.map(\.status)
        if statuses.allSatisfy({ $0 == .generated }) {
            result.status = .generated
        } else if statuses.allSatisfy({ $0 == .pendingGeneration }) {
            result.status = .pendingGeneration
        } else {
            result.status = .partiallyGenerated
        }
        return result
    }

    private static func fallbackPath(
        brief: CourseBrief,
        snapshot: CourseWorkspaceSnapshot?
    ) -> [CourseLearningNode] {
        let chapterFolders = snapshot?.nodes
            .first(where: { $0.relativePath == "chapters" })?
            .children
            .filter(\.isDirectory) ?? []

        return brief.chapters.enumerated().map { index, chapter in
            let folder = chapterFolders.indices.contains(index) ? chapterFolders[index] : nil
            let children = folder.map(markdownChildren(in:)) ?? []
            return CourseLearningNode(
                id: chapter.id,
                title: chapter.title,
                kind: .folder,
                status: children.isEmpty ? .pendingGeneration : .generated,
                children: children
            )
        }
    }

    private static func markdownChildren(in folder: CourseFileNode) -> [CourseLearningNode] {
        folder.children.compactMap { child in
            if child.isDirectory {
                let children = markdownChildren(in: child)
                guard !children.isEmpty else { return nil }
                return CourseLearningNode(
                    id: child.relativePath,
                    title: displayTitle(for: child.name),
                    kind: .folder,
                    status: .generated,
                    children: children
                )
            }
            guard child.kind == .markdown,
                  child.name.caseInsensitiveCompare("README.md") != .orderedSame else { return nil }
            return CourseLearningNode(
                id: child.relativePath,
                title: displayTitle(for: child.name),
                kind: .markdown,
                status: .generated,
                relativePath: child.relativePath
            )
        }
    }

    private static func displayTitle(for filename: String) -> String {
        filename
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)?
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ") ?? filename
    }
}
