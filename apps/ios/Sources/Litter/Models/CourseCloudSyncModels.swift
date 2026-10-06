import CryptoKit
import Foundation
import NativeBlockEditorCore

enum CourseCloudSyncSchema {
    static let version = 1
    static let catalogZoneName = "LearnfoldCatalog-v1"
    static let contentZoneName = "LearnfoldContent-v1"
}

struct CourseSyncDot: Codable, Hashable, Sendable {
    let replicaID: String
    let counter: UInt64
}

enum CourseSyncCausalRelation: Equatable, Sendable {
    case equal
    case before
    case after
    case concurrent
}

struct CourseSyncVersionVector: Codable, Hashable, Sendable {
    private(set) var counters: [String: UInt64]

    init(counters: [String: UInt64] = [:]) {
        self.counters = counters.filter { !$0.key.isEmpty && $0.value > 0 }
    }

    func counter(for replicaID: String) -> UInt64 {
        counters[replicaID, default: 0]
    }

    func observes(_ dot: CourseSyncDot) -> Bool {
        counter(for: dot.replicaID) >= dot.counter
    }

    mutating func nextDot(replicaID: String) -> CourseSyncDot {
        let next = counter(for: replicaID) &+ 1
        counters[replicaID] = next
        return CourseSyncDot(replicaID: replicaID, counter: next)
    }

    mutating func observe(_ dot: CourseSyncDot) {
        counters[dot.replicaID] = max(counter(for: dot.replicaID), dot.counter)
    }

    mutating func merge(_ other: Self) {
        for (replicaID, counter) in other.counters {
            counters[replicaID] = max(self.counter(for: replicaID), counter)
        }
    }

    func merged(with other: Self) -> Self {
        var result = self
        result.merge(other)
        return result
    }

    func relation(to other: Self) -> CourseSyncCausalRelation {
        let replicaIDs = Set(counters.keys).union(other.counters.keys)
        var hasLower = false
        var hasHigher = false

        for replicaID in replicaIDs {
            let lhs = counter(for: replicaID)
            let rhs = other.counter(for: replicaID)
            hasLower = hasLower || lhs < rhs
            hasHigher = hasHigher || lhs > rhs
        }

        switch (hasLower, hasHigher) {
        case (false, false): return .equal
        case (true, false): return .before
        case (false, true): return .after
        case (true, true): return .concurrent
        }
    }
}

struct CourseSyncMutationVersion: Codable, Hashable, Sendable {
    let dot: CourseSyncDot
    let observed: CourseSyncVersionVector
    let ancestorChecksum: String?

    var resultingVector: CourseSyncVersionVector {
        var result = observed
        result.observe(dot)
        return result
    }
}

struct CourseCloudHead: Codable, Equatable, Sendable {
    let workspaceID: String
    let generationID: String
    let generationRecordName: String
    let commitRecordName: String
    let checksum: String
    let title: String
    let previousGenerationID: String?
    let version: CourseSyncVersionVector
}

enum CourseCloudHeadResolution: Equatable, Sendable {
    case ignoreHistorical
    case accept
    case mergeConcurrent
    case invalidEqualVersion
}

enum CourseCloudHeadResolver {
    static func resolve(
        accepted: CourseCloudHead?,
        incoming: CourseCloudHead
    ) -> CourseCloudHeadResolution {
        guard let accepted else { return .accept }
        switch incoming.version.relation(to: accepted.version) {
        case .before:
            return .ignoreHistorical
        case .after:
            return .accept
        case .concurrent:
            return .mergeConcurrent
        case .equal:
            return incoming.generationID == accepted.generationID
                && incoming.checksum == accepted.checksum
                ? .accept
                : .invalidEqualVersion
        }
    }
}

struct CourseSyncLibraryItem: Codable, Hashable, Sendable {
    let id: String
    let kind: LibraryItemKind
    let parentID: String?
    let sortKey: Double
    let title: String
    let icon: String
    let isFavorite: Bool
    let createdAt: Date
    let updatedAt: Date
    let lastOpenedAt: Date?
    let trashedAt: Date?

    init(_ item: NativeBlockEditorLibrary.LibraryItem) {
        id = item.id
        kind = item.kind
        parentID = item.parentID
        sortKey = item.sortKey
        title = item.title
        icon = item.icon
        isFavorite = item.isFavorite
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        lastOpenedAt = item.lastOpenedAt
        trashedAt = item.trashedAt
    }

    var libraryItem: NativeBlockEditorLibrary.LibraryItem {
        NativeBlockEditorLibrary.LibraryItem(
            id: id,
            kind: kind,
            parentID: parentID,
            sortKey: sortKey,
            title: title,
            icon: icon,
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            trashedAt: trashedAt
        )
    }
}

struct CourseSyncPageDocument: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    let parentID: String?
    let document: BlockDocument
    let createdAt: Date
    let updatedAt: Date
    let checksum: String

    init(_ page: PageRecord) throws {
        id = page.id
        title = page.title
        icon = page.icon
        parentID = page.parentID
        document = page.document
        createdAt = page.createdAt
        updatedAt = page.updatedAt
        checksum = try CourseSyncChecksum.value(for: page.document)
    }

    var pageRecord: PageRecord {
        PageRecord(
            id: id,
            title: title,
            icon: icon,
            parentID: parentID,
            document: document,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct CourseSyncWorkspaceManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let workspaceID: String
    let generationID: String
    let previousGenerationID: String?
    let rootPageID: String
    let itemIDs: [String]
    let pageChecksums: [String: String]
    let version: CourseSyncVersionVector
    let createdAt: Date

    init(
        workspaceID: String,
        generationID: String,
        previousGenerationID: String?,
        rootPageID: String,
        itemIDs: [String],
        pageChecksums: [String: String],
        version: CourseSyncVersionVector,
        createdAt: Date = .now
    ) {
        schemaVersion = CourseCloudSyncSchema.version
        self.workspaceID = workspaceID
        self.generationID = generationID
        self.previousGenerationID = previousGenerationID
        self.rootPageID = rootPageID
        self.itemIDs = itemIDs.sorted()
        self.pageChecksums = pageChecksums
        self.version = version
        self.createdAt = createdAt
    }
}

struct CourseSyncWorkspaceSnapshot: Codable, Equatable, Sendable {
    let manifest: CourseSyncWorkspaceManifest
    let items: [CourseSyncLibraryItem]
    let pages: [CourseSyncPageDocument]
    /// Absent in legacy page-only generations. Existing checksums remain valid.
    let continuation: CourseSyncContinuation?
    let checksum: String

    init(
        workspaceID: String,
        workspace: PageWorkspace,
        generationID: String = UUID().uuidString.lowercased(),
        previousGenerationID: String? = nil,
        version: CourseSyncVersionVector = .init(),
        continuation: CourseSyncContinuation? = nil
    ) throws {
        let items = workspace.items.values
            .map(CourseSyncLibraryItem.init)
            .sorted { $0.id < $1.id }
        let pages = try workspace.pages.values
            .map(CourseSyncPageDocument.init)
            .sorted { $0.id < $1.id }
        let pageChecksums = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.checksum) })
        manifest = CourseSyncWorkspaceManifest(
            workspaceID: workspaceID,
            generationID: generationID,
            previousGenerationID: previousGenerationID,
            rootPageID: workspace.rootPageID,
            itemIDs: items.map(\.id),
            pageChecksums: pageChecksums,
            version: version
        )
        self.items = items
        self.pages = pages
        self.continuation = continuation
        try continuation?.validate(workspaceID: workspaceID)
        checksum = try Self.computeContentChecksum(
            rootPageID: workspace.rootPageID,
            items: items,
            pages: pages,
            continuation: continuation
        )
    }

    func validatedWorkspace() throws -> PageWorkspace {
        guard manifest.schemaVersion == CourseCloudSyncSchema.version else {
            throw CourseCloudSyncModelError.unsupportedSchema(manifest.schemaVersion)
        }
        // Comparing sets alone would accept a decoded generation that repeats
        // an ID, which then traps while building the lookups below. A remote
        // record is untrusted input: reject it instead.
        guard Set(manifest.itemIDs).count == manifest.itemIDs.count,
              Set(items.map(\.id)).count == items.count,
              Set(pages.map(\.id)).count == pages.count,
              Set(manifest.itemIDs) == Set(items.map(\.id)),
              Set(manifest.pageChecksums.keys) == Set(pages.map(\.id)) else {
            throw CourseCloudSyncModelError.incompleteGeneration(manifest.generationID)
        }
        for page in pages {
            guard manifest.pageChecksums[page.id] == page.checksum,
                  try CourseSyncChecksum.value(for: page.document) == page.checksum else {
                throw CourseCloudSyncModelError.checksumMismatch(page.id)
            }
        }
        try continuation?.validate(workspaceID: manifest.workspaceID)
        let expected = try Self.computeContentChecksum(
            rootPageID: manifest.rootPageID,
            items: items,
            pages: pages,
            continuation: continuation
        )
        guard expected == checksum else {
            throw CourseCloudSyncModelError.checksumMismatch(manifest.generationID)
        }

        let itemMap = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.libraryItem) })
        let pageMap = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.pageRecord) })
        return try PageWorkspace(
            rootPageID: manifest.rootPageID,
            pages: pageMap,
            items: itemMap
        )
    }

    private static func computeContentChecksum(
        rootPageID: String,
        items: [CourseSyncLibraryItem],
        pages: [CourseSyncPageDocument],
        continuation: CourseSyncContinuation?
    ) throws -> String {
        struct ChecksumEnvelope: Encodable {
            let rootPageID: String
            let items: [CourseSyncLibraryItem]
            let pages: [CourseSyncPageDocument]
            let continuation: CourseSyncContinuation?
        }
        return try CourseSyncChecksum.value(
            for: ChecksumEnvelope(rootPageID: rootPageID, items: items, pages: pages, continuation: continuation)
        )
    }
}

struct CourseSyncGenerationCommit: Codable, Hashable, Sendable {
    struct Record: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case workspaceManifest
            case libraryItem
            case pageDocument
            case fileManifest
            case fileBlob
            case tombstoneLedger
        }

        let recordName: String
        let kind: Kind
        let checksum: String
    }

    let schemaVersion: Int
    let workspaceID: String
    let generationID: String
    let previousGenerationID: String?
    let manifestShardNames: [String]
    let records: [Record]
    let version: CourseSyncVersionVector
    let createdAt: Date

    init(
        workspaceID: String,
        generationID: String,
        previousGenerationID: String?,
        manifestShardNames: [String],
        records: [Record],
        version: CourseSyncVersionVector,
        createdAt: Date = .now
    ) throws {
        guard Set(records.map(\.recordName)).count == records.count,
              Set(manifestShardNames).count == manifestShardNames.count else {
            throw CourseCloudSyncModelError.duplicateRecord
        }
        schemaVersion = CourseCloudSyncSchema.version
        self.workspaceID = workspaceID
        self.generationID = generationID
        self.previousGenerationID = previousGenerationID
        self.manifestShardNames = manifestShardNames.sorted()
        self.records = records.sorted { $0.recordName < $1.recordName }
        self.version = version
        self.createdAt = createdAt
    }
}

struct CourseSyncFileManifest: Codable, Hashable, Sendable {
    let fileID: String
    let relativePath: String
    let originalFilename: String
    let mimeType: String
    let byteCount: Int64
    let checksum: String
    let blobRecordNames: [String]

    init(
        fileID: String,
        relativePath: String,
        originalFilename: String,
        mimeType: String,
        byteCount: Int64,
        checksum: String,
        blobRecordNames: [String]
    ) throws {
        let normalizedPath = try CourseSyncPathValidator.normalizedRelativePath(relativePath)
        guard byteCount >= 0, !blobRecordNames.isEmpty else {
            throw CourseCloudSyncModelError.invalidFileManifest
        }
        self.fileID = fileID
        self.relativePath = normalizedPath
        self.originalFilename = URL(fileURLWithPath: originalFilename).lastPathComponent
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.checksum = checksum
        self.blobRecordNames = blobRecordNames
    }
}

enum CourseSyncRecordName {
    static func course(workspaceID: String) -> String {
        "course.\(CourseSyncChecksum.value(forUTF8: workspaceID))"
    }

    static func page(workspaceID: String, pageID: String, checksum: String) -> String {
        "page.\(CourseSyncChecksum.value(forUTF8: workspaceID + "\u{0}" + pageID)).\(checksum)"
    }

    static func generation(workspaceID: String, generationID: String) -> String {
        "generation.\(CourseSyncChecksum.value(forUTF8: workspaceID + "\u{0}" + generationID))"
    }
}

enum CourseSyncPathValidator {
    static func normalizedRelativePath(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !normalized.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw CourseCloudSyncModelError.unsafeRelativePath(value)
        }
        return components.joined(separator: "/")
    }
}

enum CourseSyncChecksum {
    static func value<T: Encodable>(for value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return digest(try encoder.encode(value))
    }

    static func value(for data: Data) -> String {
        digest(data)
    }

    static func value(forUTF8 value: String) -> String {
        digest(Data(value.utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CourseCloudSyncModelError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case incompleteGeneration(String)
    case checksumMismatch(String)
    case duplicateRecord
    case invalidFileManifest
    case unsafeRelativePath(String)
    case invalidContinuation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Unsupported course sync schema \(version)."
        case .incompleteGeneration(let id): "Course generation \(id) is incomplete."
        case .checksumMismatch(let id): "Course sync checksum mismatch for \(id)."
        case .duplicateRecord: "A generation contains duplicate record identifiers."
        case .invalidFileManifest: "The course file manifest is invalid."
        case .unsafeRelativePath(let path): "Unsafe course-relative path: \(path)"
        case .invalidContinuation(let detail): "Course continuation could not be synchronized. \(detail)"
        }
    }
}
