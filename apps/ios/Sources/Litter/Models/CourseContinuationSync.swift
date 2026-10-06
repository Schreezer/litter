import Foundation

/// Cloud continuation contains app-owned course state and learner-visible text.
/// App-server thread IDs, local server IDs, credentials, tools and reasoning stay
/// with the runtime that owns them.
struct CourseSyncPortableCourse: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var accentHex: String
    var progress: Double
    var lessonCount: Int
    var duration: String
    var status: String
    var workspaceID: String
    var agentRuntimeKind: String?
    var agentModelID: String?
    var agentReasoningEffortID: String?
    var hostedSessionID: UUID?
    var hostedOwnerSubject: String?
    var hostedServiceBaseURL: String?

    init(_ course: LearningCourse, hostedOwnerSubject: String? = nil, hostedServiceBaseURL: String? = nil) {
        id = course.id
        title = course.title
        subtitle = course.subtitle
        accentHex = course.accentHex
        progress = course.progress
        lessonCount = course.lessonCount
        duration = course.duration
        status = course.status.rawValue
        workspaceID = course.workspaceID ?? ""
        agentRuntimeKind = course.agentRuntimeKind
        agentModelID = course.agentModelID
        agentReasoningEffortID = course.agentReasoningEffortID
        hostedSessionID = course.hostedSessionID
        self.hostedOwnerSubject = hostedOwnerSubject
        self.hostedServiceBaseURL = hostedServiceBaseURL
    }

    var learningCourse: LearningCourse {
        LearningCourse(
            id: id, title: title, subtitle: subtitle, accentHex: accentHex,
            progress: progress, lessonCount: lessonCount, duration: duration,
            status: LearningCourse.Status(rawValue: status) ?? .ready,
            workspaceID: workspaceID, agentRuntimeKind: agentRuntimeKind,
            agentModelID: agentModelID, agentReasoningEffortID: agentReasoningEffortID,
            hostedSessionID: hostedSessionID
        )
    }
}

struct CourseSyncReadingBookmark: Codable, Equatable, Sendable {
    var pageID: String
    var offset: Double
    var isAtEnd: Bool
    var updatedAt: Date

    init(_ bookmark: CourseReadingBookmark, updatedAt: Date = .now) {
        pageID = bookmark.pageID
        offset = bookmark.offset
        isAtEnd = bookmark.isAtEnd
        self.updatedAt = updatedAt
    }

    var bookmark: CourseReadingBookmark {
        CourseReadingBookmark(pageID: pageID, offset: offset, isAtEnd: isAtEnd)
    }
}

struct CourseSyncDiscussionTranscript: Codable, Equatable, Sendable {
    /// "course" or the stable selection discussion UUID, never a thread ID.
    var discussionID: String
    var messages: [CodexCourseTranscriptMessage]
    var messageIDs: [String]? = nil

    var stableMessageIDs: [String] {
        if let messageIDs, messageIDs.count == messages.count { return messageIDs }
        return messages.enumerated().map { index, message in
            CourseSyncChecksum.value(forUTF8: "\(discussionID)\u{0}\(index)\u{0}\(message.role.rawValue)\u{0}\(message.text)")
        }
    }
}

struct CourseSyncHostedBinding: Codable, Equatable, Sendable {
    var discussionID: String
    var ownerSubject: String
    var serviceBaseURL: String
    var sessionID: UUID
}

struct CourseSyncContinuationMetadata: Codable, Equatable, Sendable {
    var course: CourseSyncPortableCourse?
    var readingBookmark: CourseSyncReadingBookmark?
    var discussions: [CourseSelectionDiscussion]
    var transcripts: [CourseSyncDiscussionTranscript]
    var hostedBindings: [CourseSyncHostedBinding] = []

    func sanitized() -> Self {
        var result = self
        result.discussions = discussions.map { discussion in
            var copy = discussion
            copy.serverID = nil
            copy.threadID = nil
            copy.appleSessionID = nil
            copy.remoteArchivePending = nil
            return copy
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        result.transcripts.sort { $0.discussionID < $1.discussionID }
        result.hostedBindings.sort { $0.discussionID < $1.discussionID }
        return result
    }
}

struct CourseSyncContinuationFile: Codable, Equatable, Sendable {
    var relativePath: String
    var data: Data
    var checksum: String

    init(relativePath: String, data: Data) throws {
        self.relativePath = try CourseSyncPathValidator.normalizedRelativePath(relativePath)
        self.data = data
        checksum = CourseSyncChecksum.value(for: data)
    }
}

struct CourseSyncAssessmentArchive: Codable, Equatable, Sendable {
    var filename: String
    var attempts: [CourseAssessmentAttempt]
}

struct CourseSyncContinuation: Codable, Equatable, Sendable {
    static let maximumFileBytes = 20 * 1024 * 1024
    static let maximumTotalFileBytes = 40 * 1024 * 1024
    var metadata: CourseSyncContinuationMetadata?
    var presentedPlan: CourseBrief?
    var approvedPlan: CourseBrief?
    var files: [CourseSyncContinuationFile]
    var assessments: [CourseSyncAssessmentArchive]

    func validate(workspaceID: String) throws {
        guard CourseBashTool.isValidWorkspaceID(workspaceID),
              Set(files.map(\.relativePath)).count == files.count,
              files.count <= 4_096,
              Set(assessments.map(\.filename)).count == assessments.count else {
            throw CourseCloudSyncModelError.invalidContinuation("Invalid course identity or duplicate files.")
        }
        if let metadata {
            guard metadata == metadata.sanitized(),
                  metadata.course == nil || metadata.course?.workspaceID == workspaceID,
                  metadata.course?.progress.isFinite != false,
                  metadata.course.map({ !$0.id.isEmpty && !$0.title.isEmpty && (0...1).contains($0.progress) }) != false,
                  metadata.readingBookmark.map({ !$0.pageID.isEmpty && $0.offset.isFinite && $0.offset >= 0 }) != false,
                  Set(metadata.discussions.map(\.id)).count == metadata.discussions.count,
                  Set(metadata.transcripts.map(\.discussionID)).count == metadata.transcripts.count,
                  Set(metadata.hostedBindings.map(\.discussionID)).count == metadata.hostedBindings.count,
                  metadata.transcripts.allSatisfy({ transcript in
                      !transcript.discussionID.isEmpty && transcript.messages.count <= 20_000
                          && transcript.messages.allSatisfy { $0.text.utf8.count <= 1_000_000 }
                          && transcript.messageIDs.map({ $0.count == transcript.messages.count && Set($0).count == $0.count && $0.allSatisfy { !$0.isEmpty && $0.count <= 256 } }) != false
                  }) else {
                throw CourseCloudSyncModelError.invalidContinuation("Invalid portable course metadata.")
            }
            guard try JSONEncoder().encode(metadata).count <= 4 * 1024 * 1024 else {
                throw CourseCloudSyncModelError.invalidContinuation("Course discussion history exceeds the 4 MB sync generation limit.")
            }
            for binding in metadata.hostedBindings {
                guard !binding.discussionID.isEmpty,
                      ["guest-", "access-"].contains(where: { prefix in
                          binding.ownerSubject.hasPrefix(prefix)
                              && binding.ownerSubject.count == prefix.count + 64
                              && binding.ownerSubject.dropFirst(prefix.count).allSatisfy({ $0.isHexDigit })
                      }),
                      let url = URL(string: binding.serviceBaseURL),
                      url.host != nil,
                      url.user == nil, url.password == nil,
                      url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")) else {
                    throw CourseCloudSyncModelError.invalidContinuation("Invalid hosted owner binding.")
                }
                if binding.discussionID == "course", let course = metadata.course {
                    guard course.hostedSessionID.map({ $0 == binding.sessionID }) != false,
                          course.hostedOwnerSubject.map({ $0 == binding.ownerSubject }) != false,
                          course.hostedServiceBaseURL.map({ $0 == binding.serviceBaseURL }) != false else {
                        throw CourseCloudSyncModelError.invalidContinuation("The hosted course session does not match its owner binding.")
                    }
                } else if let discussion = metadata.discussions.first(where: { $0.id.uuidString == binding.discussionID }) {
                    guard discussion.hostedSessionID.map({ $0 == binding.sessionID }) != false else {
                        throw CourseCloudSyncModelError.invalidContinuation("The hosted discussion session does not match its owner binding.")
                    }
                }
            }
        }
        if let presentedPlan, AppleCoursePlanValidator.issue(in: presentedPlan, requiresTypedHierarchy: true) != nil {
            throw CourseCloudSyncModelError.invalidContinuation("Invalid presented course plan.")
        }
        if let approvedPlan {
            guard approvedPlan == presentedPlan else {
                throw CourseCloudSyncModelError.invalidContinuation("Course approval does not match its presented plan.")
            }
        }
        var total = 0
        for file in files {
            let path = try CourseSyncPathValidator.normalizedRelativePath(file.relativePath)
            guard path == file.relativePath,
                  Self.isPortableFilePath(path),
                  file.data.count <= Self.maximumFileBytes,
                  CourseSyncChecksum.value(for: file.data) == file.checksum else {
                throw CourseCloudSyncModelError.invalidContinuation("Invalid source file \(file.relativePath).")
            }
            total += file.data.count
        }
        guard total <= Self.maximumTotalFileBytes else {
            throw CourseCloudSyncModelError.invalidContinuation("Course sources exceed the 40 MB sync generation limit.")
        }
        for archive in assessments {
            guard archive.filename.count == 69, archive.filename.hasSuffix(".json"),
                  archive.filename.dropLast(5).allSatisfy({ $0.isHexDigit }),
                  archive.attempts.count <= 200,
                  Set(archive.attempts.map(\.id)).count == archive.attempts.count,
                  archive.attempts.allSatisfy({ !$0.courseID.isEmpty && !$0.pageID.isEmpty }) else {
                throw CourseCloudSyncModelError.invalidContinuation("Invalid practice archive.")
            }
            guard archive.attempts.allSatisfy({ attempt in
                let identity = Data("\(attempt.courseID)\u{0}\(attempt.pageID)".utf8)
                return CourseSyncChecksum.value(for: identity) + ".json" == archive.filename
            }) else {
                throw CourseCloudSyncModelError.invalidContinuation("Practice attempts do not match their page identity.")
            }
        }
        guard try JSONEncoder().encode(assessments).count <= 8 * 1024 * 1024 else {
            throw CourseCloudSyncModelError.invalidContinuation("Practice history exceeds the 8 MB sync generation limit.")
        }
    }

    static func isPortableFilePath(_ path: String) -> Bool {
        (path.hasPrefix("sources/") || path.hasPrefix("assets/") || path.hasPrefix(".course/ingestion/"))
            && !path.split(separator: "/").contains(where: { $0 == ".git" })
    }
}

/// Protected application storage. The shell-writable `.course` plan mirrors
/// are never used to manufacture an approval receipt during export.
enum CourseContinuationSyncStore {
    private static let accessLock = NSRecursiveLock()
    private struct AssessmentArchive: Codable {
        var version: Int
        var attempts: [CourseAssessmentAttempt]
    }

    static func writeAppOwnedData(_ data: Data, to url: URL) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        try data.write(to: url, options: .atomic)
    }

    static func metadataURL(courseDirectory: URL) -> URL {
        AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: courseDirectory)
            .deletingLastPathComponent().appendingPathComponent("continuation.json")
    }

    static func loadMetadata(courseDirectory: URL) throws -> CourseSyncContinuationMetadata? {
        accessLock.lock()
        defer { accessLock.unlock() }
        let url = metadataURL(courseDirectory: courseDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let metadata = try JSONDecoder().decode(CourseSyncContinuationMetadata.self, from: Data(contentsOf: confined(url, to: url.deletingLastPathComponent())))
        try CourseSyncContinuation(metadata: metadata, presentedPlan: nil, approvedPlan: nil, files: [], assessments: []).validate(workspaceID: courseDirectory.lastPathComponent)
        return metadata
    }

    @discardableResult
    static func saveMetadata(_ metadata: CourseSyncContinuationMetadata, courseDirectory: URL) throws -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        let sanitized = metadata.sanitized()
        if try loadMetadata(courseDirectory: courseDirectory) == sanitized { return false }
        let probe = CourseSyncContinuation(metadata: sanitized, presentedPlan: nil, approvedPlan: nil, files: [], assessments: [])
        try probe.validate(workspaceID: courseDirectory.lastPathComponent)
        let url = metadataURL(courseDirectory: courseDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sanitized).write(to: confined(url, to: url.deletingLastPathComponent()), options: .atomic)
        return true
    }

    @discardableResult
    static func saveMetadata(_ metadata: CourseSyncContinuationMetadata, replacing previous: CourseSyncContinuationMetadata?, courseDirectory: URL) throws -> Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        let current = try loadMetadata(courseDirectory: courseDirectory)
        guard let merged = try CourseSyncContinuationMerger.mergeMetadata(base: previous, local: current, remote: metadata.sanitized()) else { return false }
        return try saveMetadata(merged, courseDirectory: courseDirectory)
    }

    static func export(courseDirectory: URL, controlDirectory: URL) throws -> CourseSyncContinuation? {
        accessLock.lock()
        defer { accessLock.unlock() }
        let manager = FileManager.default
        let metadata = try loadMetadata(courseDirectory: courseDirectory)
        var files: [CourseSyncContinuationFile] = []
        for prefix in ["sources", "assets", ".course/ingestion"] {
            let directory = courseDirectory.appendingPathComponent(prefix, isDirectory: true)
            guard manager.fileExists(atPath: directory.path) else { continue }
            _ = try confined(directory, to: courseDirectory)
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else {
                    throw CourseCloudSyncModelError.invalidContinuation("Symbolic source files cannot be synchronized.")
                }
                guard values.isRegularFile == true else { continue }
                guard (values.fileSize ?? 0) <= CourseSyncContinuation.maximumFileBytes else {
                    throw CourseCloudSyncModelError.invalidContinuation("A course source exceeds the 20 MB file limit.")
                }
                let confinedURL = try confined(url, to: courseDirectory)
                let relativePath = String(confinedURL.path.dropFirst(courseDirectory.standardizedFileURL.path.count + 1))
                files.append(try CourseSyncContinuationFile(relativePath: relativePath, data: Data(contentsOf: confinedURL)))
            }
        }
        var assessments: [CourseSyncAssessmentArchive] = []
        let assessmentDirectory = controlDirectory.appendingPathComponent("assessment-attempts", isDirectory: true)
        if manager.fileExists(atPath: assessmentDirectory.path) {
            _ = try confined(assessmentDirectory, to: controlDirectory)
            for url in try manager.contentsOfDirectory(at: assessmentDirectory, includingPropertiesForKeys: [.isRegularFileKey]) where url.pathExtension == "json" {
                let data = try Data(contentsOf: confined(url, to: controlDirectory))
                let archive = try JSONDecoder().decode(AssessmentArchive.self, from: data)
                guard archive.version == 1 else { throw CourseCloudSyncModelError.invalidContinuation("Unsupported practice archive.") }
                guard !archive.attempts.isEmpty else { continue }
                let attempts = archive.attempts.map { attempt in
                    metadata?.course.map { attempt.replacingCourseID($0.id) } ?? attempt
                }
                let first = attempts[0]
                let filename = CourseSyncChecksum.value(for: Data("\(first.courseID)\u{0}\(first.pageID)".utf8)) + ".json"
                assessments.append(CourseSyncAssessmentArchive(filename: filename, attempts: attempts))
            }
        }
        let result = CourseSyncContinuation(
            metadata: metadata,
            presentedPlan: AppleCourseApprovalPolicy.presentedPlan(courseDirectory: courseDirectory),
            approvedPlan: AppleCourseApprovalPolicy.approvedPlan(courseDirectory: courseDirectory),
            files: files.sorted { $0.relativePath < $1.relativePath },
            assessments: assessments.sorted { $0.filename < $1.filename }
        )
        try result.validate(workspaceID: courseDirectory.lastPathComponent)
        return result.metadata == nil && result.presentedPlan == nil && files.isEmpty && assessments.isEmpty ? nil : result
    }

    /// A legacy title-derived ID can collide on the receiving device. Its
    /// display identity is local; cloud archives keep the origin's identity.
    static func remapAssessmentCourseID(from oldID: String, to newID: String, controlDirectory: URL) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard oldID != newID else { return }
        let directory = controlDirectory.appendingPathComponent("assessment-attempts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for source in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where source.pathExtension == "json" {
            let archive = try JSONDecoder().decode(AssessmentArchive.self, from: Data(contentsOf: confined(source, to: controlDirectory)))
            guard archive.version == 1, !archive.attempts.isEmpty, archive.attempts.allSatisfy({ $0.courseID == oldID }) else { continue }
            guard Set(archive.attempts.map(\.id)).count == archive.attempts.count else {
                throw CourseCloudSyncModelError.invalidContinuation("Practice attempt identifiers are duplicated.")
            }
            var attempts = archive.attempts.map { $0.replacingCourseID(newID) }
            let filename = CourseSyncChecksum.value(for: Data("\(newID)\u{0}\(attempts[0].pageID)".utf8)) + ".json"
            let destination = try confined(directory.appendingPathComponent(filename), to: controlDirectory)
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try JSONDecoder().decode(AssessmentArchive.self, from: Data(contentsOf: destination))
                guard existing.version == 1, Set(existing.attempts.map(\.id)).count == existing.attempts.count else { throw CourseCloudSyncModelError.invalidContinuation("Unsupported or conflicting practice archive.") }
                var byID = Dictionary(uniqueKeysWithValues: existing.attempts.map { ($0.id, $0) })
                for attempt in attempts {
                    if let saved = byID[attempt.id], saved != attempt {
                        guard saved.answerText == attempt.answerText, saved.selectedOptionID == attempt.selectedOptionID else {
                            throw CourseCloudSyncModelError.invalidContinuation("Local practice differs from the imported attempt.")
                        }
                        byID[attempt.id] = saved.updatedAt >= attempt.updatedAt ? saved : attempt
                    } else { byID[attempt.id] = attempt }
                }
                attempts = byID.values.sorted { lhs, rhs in lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt }
            }
            try JSONEncoder().encode(AssessmentArchive(version: 1, attempts: attempts)).write(to: destination, options: .atomic)
            try FileManager.default.removeItem(at: source)
        }
    }

    static func apply(_ value: CourseSyncContinuation?, replacing previous: CourseSyncContinuation? = nil, courseDirectory: URL, controlDirectory: URL) throws {
        accessLock.lock()
        defer { accessLock.unlock() }
        // A legacy generation omits continuation; it must not erase progress.
        guard let value else { return }
        try value.validate(workspaceID: courseDirectory.lastPathComponent)
        let retainedPaths = Set(value.files.map(\.relativePath))
        for file in previous?.files ?? [] where !retainedPaths.contains(file.relativePath) {
            guard CourseSyncContinuation.isPortableFilePath(file.relativePath) else { continue }
            let url = try confined(courseDirectory.appendingPathComponent(file.relativePath), to: courseDirectory)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        for file in value.files {
            let url = try confined(courseDirectory.appendingPathComponent(file.relativePath), to: courseDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }
        if let metadata = value.metadata { try saveMetadata(metadata, courseDirectory: courseDirectory) }
        let approvalDirectory = AppleCourseApprovalPolicy.protectedMetadataDirectory(courseDirectory: courseDirectory)
        try FileManager.default.createDirectory(at: approvalDirectory, withIntermediateDirectories: true)
        for (filename, plan) in [
            (AppleCourseApprovalPolicy.presentedPlanFilename, value.presentedPlan),
            (AppleCourseApprovalPolicy.approvedPlanFilename, value.approvedPlan),
        ] {
            let url = try confined(approvalDirectory.appendingPathComponent(filename), to: approvalDirectory)
            if let plan {
                try JSONEncoder().encode(plan).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        for archive in value.assessments {
            let url = try confined(controlDirectory.appendingPathComponent("assessment-attempts").appendingPathComponent(archive.filename), to: controlDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AssessmentArchive(version: 1, attempts: archive.attempts)).write(to: url, options: .atomic)
        }
    }

    /// Metadata can advance while the repository awaits the SQLite CAS. Merge
    /// those new app-owned writes before materializing the cloud continuation.
    static func applyMergingConcurrentChanges(_ incoming: CourseSyncContinuation?, replacing previous: CourseSyncContinuation?, courseDirectory: URL, controlDirectory: URL) throws -> CourseSyncContinuation? {
        accessLock.lock()
        defer { accessLock.unlock() }
        let current = try export(courseDirectory: courseDirectory, controlDirectory: controlDirectory)
        let result = try CourseSyncContinuationMerger.merge(base: previous, local: current, remote: incoming)
        try apply(result, replacing: current, courseDirectory: courseDirectory, controlDirectory: controlDirectory)
        return result
    }

    private static func confined(_ url: URL, to root: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
            throw CourseCloudSyncModelError.unsafeRelativePath(url.lastPathComponent)
        }
        // A symlink into another directory *inside* the course is also unsafe:
        // `sources/link/course-library.sqlite` must not overwrite native state.
        var componentURL = root.standardizedFileURL
        // A missing leaf can retain /var while its existing parent resolves to
        // /private/var. Build from one canonical root after checking each child.
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var canonicalURL = canonicalRoot
        let relativeComponents = standardized.path.dropFirst(rootPath.count)
            .split(separator: "/", omittingEmptySubsequences: true)
        for component in relativeComponents {
            componentURL.appendPathComponent(String(component))
            canonicalURL.appendPathComponent(String(component))
            if let values = try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw CourseCloudSyncModelError.unsafeRelativePath(url.lastPathComponent)
            }
        }
        let resolvedPath = canonicalURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == canonicalRoot.path || resolvedPath.hasPrefix(canonicalRoot.path + "/") else {
            throw CourseCloudSyncModelError.unsafeRelativePath(url.lastPathComponent)
        }
        return standardized
    }
}

private extension CourseAssessmentAttempt {
    func replacingCourseID(_ courseID: String) -> Self {
        CourseAssessmentAttempt(
            id: id, courseID: courseID, pageID: pageID, assessmentID: assessmentID,
            fingerprint: fingerprint, questionTitle: questionTitle,
            questionPrompt: questionPrompt, options: options, createdAt: createdAt,
            updatedAt: updatedAt, submissionID: submissionID,
            selectedOptionID: selectedOptionID, answerText: answerText, phase: phase,
            review: review, reviewError: reviewError, discussionOpened: discussionOpened,
            discussionStarted: discussionStarted, discussionInstruction: discussionInstruction
        )
    }
}

enum CourseSyncContinuationMerger {
    static func merge(base: CourseSyncContinuation?, local: CourseSyncContinuation?, remote: CourseSyncContinuation?) throws -> CourseSyncContinuation? {
        if remote == base || remote == nil { return local }
        if local == base || local == nil { return remote }
        guard let local, let remote else { return local ?? remote }
        let presented = try field(base: base?.presentedPlan, local: local.presentedPlan, remote: remote.presentedPlan, key: "course plan")
        let approved = try field(base: base?.approvedPlan, local: local.approvedPlan, remote: remote.approvedPlan, key: "course approval")
        let metadata = try mergeMetadata(base: base?.metadata, local: local.metadata, remote: remote.metadata)
        let files = try mergeRecords(base: base?.files ?? [], local: local.files, remote: remote.files, id: { $0.relativePath }, merge: { try field(base: $0, local: $1, remote: $2, key: "source file") })
        let baseAssessments: [CourseSyncAssessmentArchive] = base?.assessments ?? []
        let assessments: [CourseSyncAssessmentArchive] = try mergeRecords(base: baseAssessments, local: local.assessments, remote: remote.assessments, id: { $0.filename }, merge: mergeAssessmentArchive)
        return CourseSyncContinuation(metadata: metadata, presentedPlan: presented, approvedPlan: approved, files: files, assessments: assessments)
    }

    private static func mergeAssessmentArchive(base: CourseSyncAssessmentArchive?, local: CourseSyncAssessmentArchive?, remote: CourseSyncAssessmentArchive?) throws -> CourseSyncAssessmentArchive? {
        guard let local, let remote else { return local ?? remote }
        let baseAttempts: [CourseAssessmentAttempt] = base?.attempts ?? []
        let attempts: [CourseAssessmentAttempt] = try mergeRecords(base: baseAttempts, local: local.attempts, remote: remote.attempts, id: { $0.id.uuidString }, merge: mergeAssessmentAttempt)
        return CourseSyncAssessmentArchive(filename: local.filename, attempts: attempts)
    }

    private static func mergeAssessmentAttempt(base: CourseAssessmentAttempt?, local: CourseAssessmentAttempt?, remote: CourseAssessmentAttempt?) throws -> CourseAssessmentAttempt? {
        if local == base { return remote }
        if remote == base { return local }
        guard let local, let remote else { return local ?? remote }
        guard local == remote || local.answerText == remote.answerText && local.selectedOptionID == remote.selectedOptionID else {
            throw CourseCloudSyncModelError.invalidContinuation("The same practice attempt has different answers on two devices.")
        }
        return local.updatedAt >= remote.updatedAt ? local : remote
    }

    static func mergeMetadata(base: CourseSyncContinuationMetadata?, local: CourseSyncContinuationMetadata?, remote: CourseSyncContinuationMetadata?) throws -> CourseSyncContinuationMetadata? {
        if local == base { return remote }
        if remote == base || remote == nil { return local }
        guard let local, let remote else { return local ?? remote }
        let course = try mergeCourse(base: base?.course, local: local.course, remote: remote.course)
        let bookmarkCandidates: [CourseSyncReadingBookmark] =
            [local.readingBookmark, remote.readingBookmark].compactMap { $0 }
        let bookmark: CourseSyncReadingBookmark? = bookmarkCandidates.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.pageID != rhs.pageID { return lhs.pageID < rhs.pageID }
            if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
            return !lhs.isAtEnd && rhs.isAtEnd
        }
        let baseDiscussions: [CourseSelectionDiscussion] = base?.discussions ?? []
        let discussions: [CourseSelectionDiscussion] = try mergeRecords(base: baseDiscussions, local: local.discussions, remote: remote.discussions, id: { $0.id.uuidString }, merge: mergeDiscussion)
        let baseTranscripts: [CourseSyncDiscussionTranscript] = base?.transcripts ?? []
        let transcripts: [CourseSyncDiscussionTranscript] = try mergeRecords(base: baseTranscripts, local: local.transcripts, remote: remote.transcripts, id: { $0.discussionID }, merge: mergeStoredTranscript)
        let bindings = try mergeRecords(base: base?.hostedBindings ?? [], local: local.hostedBindings, remote: remote.hostedBindings, id: { $0.discussionID }, merge: { try field(base: $0, local: $1, remote: $2, key: "hosted owner") })
        return CourseSyncContinuationMetadata(course: course, readingBookmark: bookmark, discussions: discussions, transcripts: transcripts, hostedBindings: bindings).sanitized()
    }

    private static func mergeDiscussion(base: CourseSelectionDiscussion?, local: CourseSelectionDiscussion?, remote: CourseSelectionDiscussion?) throws -> CourseSelectionDiscussion? {
        if local == base { return remote }
        if remote == base { return local }
        guard let local, let remote else { return local ?? remote }
        if local == remote { return local }
        guard local.hostedSessionID == remote.hostedSessionID,
              local.pageID == remote.pageID, local.selectedText == remote.selectedText else {
            throw CourseCloudSyncModelError.invalidContinuation("A discussion changed concurrently on two devices.")
        }
        var result = local
        if remote.status == .resolved, local.status != .resolved { result = remote }
        if remote.status == .resolved, local.status == .resolved {
            let localDate = local.resolvedAt ?? .distantPast
            let remoteDate = remote.resolvedAt ?? .distantPast
            if localDate < remoteDate { result = remote }
            if localDate == remoteDate {
                let localChecksum = try CourseSyncChecksum.value(for: local)
                let remoteChecksum = try CourseSyncChecksum.value(for: remote)
                if localChecksum < remoteChecksum { result = remote }
            }
        }
        result.hasSubmittedQuestion = local.hasSubmittedQuestion || remote.hasSubmittedQuestion
        return result
    }

    private static func mergeStoredTranscript(base: CourseSyncDiscussionTranscript?, local: CourseSyncDiscussionTranscript?, remote: CourseSyncDiscussionTranscript?) throws -> CourseSyncDiscussionTranscript? {
        guard let local, let remote else { return local ?? remote }
        if local.messageIDs != nil || remote.messageIDs != nil { return try mergeTranscript(local: local, remote: remote) }
        let messages = try mergeMessages(base: base?.messages ?? [], local: local.messages, remote: remote.messages)
        return CourseSyncDiscussionTranscript(discussionID: local.discussionID, messages: messages)
    }

    static func mergeTranscript(local: CourseSyncDiscussionTranscript, remote: CourseSyncDiscussionTranscript) throws -> CourseSyncDiscussionTranscript {
        guard local.discussionID == remote.discussionID else {
            throw CourseCloudSyncModelError.invalidContinuation("Discussion identities differ.")
        }
        var messages: [String: CodexCourseTranscriptMessage] = [:]
        var followers: [String: Set<String>] = [:]
        var prerequisites: [String: Set<String>] = [:]
        for transcript in [local, remote] {
            let ids = transcript.stableMessageIDs
            guard ids.count == transcript.messages.count, Set(ids).count == ids.count else {
                throw CourseCloudSyncModelError.invalidContinuation("Discussion message identifiers are invalid.")
            }
            for (id, message) in zip(ids, transcript.messages) {
                if let previous = messages[id], previous != message {
                    throw CourseCloudSyncModelError.invalidContinuation("The same discussion message changed on two devices.")
                }
                messages[id] = message
            }
            for (before, after) in zip(ids, ids.dropFirst()) {
                followers[before, default: []].insert(after)
                prerequisites[after, default: []].insert(before)
            }
        }
        var available = Set(messages.keys.filter { prerequisites[$0, default: []].isEmpty })
        var order: [String] = []
        while let id = available.min() {
            available.remove(id)
            order.append(id)
            for follower in followers[id, default: []] {
                prerequisites[follower, default: []].remove(id)
                if prerequisites[follower, default: []].isEmpty { available.insert(follower) }
            }
        }
        guard order.count == messages.count else {
            throw CourseCloudSyncModelError.invalidContinuation("Discussion message order changed concurrently.")
        }
        return CourseSyncDiscussionTranscript(discussionID: local.discussionID, messages: order.compactMap { messages[$0] }, messageIDs: order)
    }

    private static func mergeCourse(base: CourseSyncPortableCourse?, local: CourseSyncPortableCourse?, remote: CourseSyncPortableCourse?) throws -> CourseSyncPortableCourse? {
        if local == base { return remote }
        if remote == base || remote == local { return local }
        guard let local, let remote else { return try field(base: base, local: local, remote: remote, key: "course identity") }
        guard local.id == remote.id, local.workspaceID == remote.workspaceID else {
            throw CourseCloudSyncModelError.invalidContinuation("Course identities differ across devices.")
        }
        var result = local
        result.title = try requiredField(base: base?.title, local: local.title, remote: remote.title, key: "course title")
        result.subtitle = try requiredField(base: base?.subtitle, local: local.subtitle, remote: remote.subtitle, key: "course subtitle")
        result.accentHex = try requiredField(base: base?.accentHex, local: local.accentHex, remote: remote.accentHex, key: "course accent")
        result.lessonCount = try requiredField(base: base?.lessonCount, local: local.lessonCount, remote: remote.lessonCount, key: "lesson count")
        result.duration = try requiredField(base: base?.duration, local: local.duration, remote: remote.duration, key: "course duration")
        result.status = try requiredField(base: base?.status, local: local.status, remote: remote.status, key: "course status")
        result.progress = max(local.progress, remote.progress)
        result.agentRuntimeKind = try field(base: base?.agentRuntimeKind, local: local.agentRuntimeKind, remote: remote.agentRuntimeKind, key: "course runtime")
        result.agentModelID = try field(base: base?.agentModelID, local: local.agentModelID, remote: remote.agentModelID, key: "course model")
        result.agentReasoningEffortID = try field(base: base?.agentReasoningEffortID, local: local.agentReasoningEffortID, remote: remote.agentReasoningEffortID, key: "course reasoning effort")
        result.hostedSessionID = try field(base: base?.hostedSessionID, local: local.hostedSessionID, remote: remote.hostedSessionID, key: "hosted session")
        result.hostedOwnerSubject = try field(base: base?.hostedOwnerSubject, local: local.hostedOwnerSubject, remote: remote.hostedOwnerSubject, key: "hosted owner")
        result.hostedServiceBaseURL = try field(base: base?.hostedServiceBaseURL, local: local.hostedServiceBaseURL, remote: remote.hostedServiceBaseURL, key: "hosted service")
        return result
    }

    private static func requiredField<T: Equatable>(base: T?, local: T, remote: T, key: String) throws -> T {
        guard let value = try field(base: base, local: local, remote: remote, key: key) else {
            throw CourseCloudSyncModelError.invalidContinuation("The \(key) is missing.")
        }
        return value
    }

    /// Concurrent conversations fork. Keep both visible suffixes deterministically;
    /// neither side is discarded or represented as an app-server rollout.
    static func mergeMessages(base: [CodexCourseTranscriptMessage], local: [CodexCourseTranscriptMessage], remote: [CodexCourseTranscriptMessage]) throws -> [CodexCourseTranscriptMessage] {
        if local == remote { return local }
        if local.starts(with: remote) { return local }
        if remote.starts(with: local) { return remote }
        guard local.starts(with: base), remote.starts(with: base) else {
            throw CourseCloudSyncModelError.invalidContinuation("The discussion history changed without a common prefix.")
        }
        let lhs = Array(local.dropFirst(base.count))
        let rhs = Array(remote.dropFirst(base.count))
        let ordered = try [lhs, rhs].sorted { try CourseSyncChecksum.value(for: $0) < CourseSyncChecksum.value(for: $1) }
        return base + ordered.flatMap { $0 }
    }

    private static func field<T: Equatable>(base: T?, local: T?, remote: T?, key: String, resolve: ((T, T) -> T?)? = nil) throws -> T? {
        if local == remote || remote == base { return local }
        if local == base { return remote }
        if let local, let remote, let resolved = resolve?(local, remote) { return resolved }
        throw CourseCloudSyncModelError.invalidContinuation("Concurrent changes to \(key) require recovery.")
    }

    private static func mergeRecords<T>(base: [T], local: [T], remote: [T], id: (T) -> String, merge: (T?, T?, T?) throws -> T?) throws -> [T] {
        let baseMap = Dictionary(uniqueKeysWithValues: base.map { (id($0), $0) })
        let localMap = Dictionary(uniqueKeysWithValues: local.map { (id($0), $0) })
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.map { (id($0), $0) })
        return try Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys).sorted().compactMap { key in
            try merge(baseMap[key], localMap[key], remoteMap[key])
        }
    }
}
