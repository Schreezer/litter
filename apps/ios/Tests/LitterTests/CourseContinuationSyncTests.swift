import NativeBlockEditorCore
import XCTest
@testable import Litter

final class CourseContinuationSyncTests: XCTestCase {
    func testOversizedCourseFailureIsIsolatedFromOtherWorkspaceAndTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CourseSyncFailurePolicy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try CourseCloudSyncStateStore(url: root.appendingPathComponent("sync.sqlite"))
        let engine = CourseCloudSyncEngine(stateStore: state, stagingDirectory: root.appendingPathComponent("staging"))
        let before = await engine.availability
        await engine.recordWorkspaceQueueFailure(CourseCloudSyncModelError.invalidContinuation("Sources exceed the sync limit."), workspaceID: "oversized-course")
        let after = await engine.availability
        let errors = await engine.workspaceErrors
        XCTAssertEqual(after, before, "An invalid local course must not change CloudKit transport availability.")
        XCTAssertNotNil(errors["oversized-course"])
        XCTAssertNil(errors["next-course"])
        XCTAssertTrue(CourseCloudSyncFailurePolicy.isWorkspaceSpecific(CourseCloudSyncModelError.invalidContinuation("too large")))
        XCTAssertFalse(CourseCloudSyncFailurePolicy.isWorkspaceSpecific(NSError(domain: "CloudKitNetwork", code: 1)))
    }
    func testMacToPhoneAndPhoneToMacRestorePlansSourcesPracticeAndDiscussionWithoutRuntimeHandles() async throws {
        let fixture = try fixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mac = try await repository(directory: fixture.mac, control: fixture.macControl)
        let phone = try await repository(directory: fixture.phone, control: fixture.phoneControl)
        let plan = validPlan()
        try await mac.presentPlan(plan)
        try await mac.approvePlan(plan)

        let hostedSession = UUID()
        var course = learningCourse()
        course.agentRuntimeKind = "hosted"
        course.hostedSessionID = hostedSession
        course.agentServerID = "mac-private-server"
        course.agentThreadID = "mac-private-thread"
        course.appleSessionID = UUID()
        var discussion = CourseSelectionDiscussion(courseID: course.id, pageID: "lesson-01", pageTitle: "First lesson")
        discussion.serverID = "selection-private-server"
        discussion.threadID = "selection-private-thread"
        discussion.appleSessionID = UUID()
        let subject = "guest-" + String(repeating: "a", count: 64)
        let metadata = CourseSyncContinuationMetadata(
            course: CourseSyncPortableCourse(course, hostedOwnerSubject: subject, hostedServiceBaseURL: "https://learnfold.example"),
            readingBookmark: CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-01", offset: 72, isAtEnd: false), updatedAt: Date(timeIntervalSince1970: 10)),
            discussions: [discussion],
            transcripts: [CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.learner, "Explain this course"), message(.agent, "Here is the explanation")])],
            hostedBindings: [CourseSyncHostedBinding(discussionID: "course", ownerSubject: subject, serviceBaseURL: "https://learnfold.example", sessionID: hostedSession)]
        )
        try CourseContinuationSyncStore.saveMetadata(metadata, courseDirectory: fixture.mac)
        let sourceURL = fixture.mac.appendingPathComponent("sources/originals/notes.pdf")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original PDF bytes".utf8).write(to: sourceURL)
        let assetURL = fixture.mac.appendingPathComponent("assets/diagram.png")
        try FileManager.default.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assetURL)
        let attempt = practiceAttempt()
        let filename = CourseSyncChecksum.value(for: Data("\(attempt.courseID)\u{0}\(attempt.pageID)".utf8)) + ".json"
        try CourseContinuationSyncStore.apply(
            CourseSyncContinuation(metadata: metadata.sanitized(), presentedPlan: plan, approvedPlan: plan, files: [], assessments: [CourseSyncAssessmentArchive(filename: filename, attempts: [attempt])]),
            courseDirectory: fixture.mac, controlDirectory: fixture.macControl
        )
        let initial = try await mac.exportSyncSnapshot(generationID: "mac-generation")
        let encoded = try JSONEncoder().encode(initial)
        let wire = try JSONDecoder().decode(CourseSyncWorkspaceSnapshot.self, from: encoded)
        let emptyPhone = try await phone.exportSyncSnapshot(generationID: "phone-empty")
        try await phone.materializeRemoteSyncSnapshot(wire, expectedLocalChecksum: emptyPhone.checksum)

        let phoneApproved = await phone.isLatestPlanApproved()
        XCTAssertTrue(phoneApproved)
        let restored = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: fixture.phone))
        XCTAssertEqual(restored.course?.hostedSessionID, hostedSession)
        XCTAssertNil(restored.course?.learningCourse.agentThreadID)
        XCTAssertNil(restored.discussions.first?.threadID)
        XCTAssertNil(restored.discussions.first?.serverID)
        XCTAssertNil(restored.discussions.first?.appleSessionID)
        XCTAssertEqual(try Data(contentsOf: fixture.phone.appendingPathComponent("sources/originals/notes.pdf")), Data("original PDF bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.phone.appendingPathComponent("assets/diagram.png")), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.phoneControl.appendingPathComponent("assessment-attempts/\(filename)").path))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-thread"))

        var phoneMetadata = restored
        phoneMetadata.readingBookmark = CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-02", offset: 110, isAtEnd: true), updatedAt: Date(timeIntervalSince1970: 20))
        phoneMetadata.transcripts[0].messages.append(message(.learner, "Continue from my iPhone"))
        try CourseContinuationSyncStore.saveMetadata(phoneMetadata, courseDirectory: fixture.phone)
        let phoneGeneration = try await phone.exportSyncSnapshot(generationID: "phone-generation")
        XCTAssertNotEqual(phoneGeneration.checksum, initial.checksum, "A metadata-only update must change the generation checksum.")
        _ = try await mac.applyRemoteSyncSnapshot(phoneGeneration, baseSnapshot: initial)
        let returned = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: fixture.mac))
        XCTAssertEqual(returned.readingBookmark?.pageID, "lesson-02")
        XCTAssertEqual(returned.transcripts[0].messages.last?.text, "Continue from my iPhone")
        let finalMac = try await mac.exportSyncSnapshot(generationID: "mac-after-phone")
        XCTAssertEqual(finalMac.checksum, phoneGeneration.checksum)
    }

    func testConcurrentProgressAndDiscussionKeepBothDevicesChangesDeterministically() throws {
        var metadata = CourseSyncContinuationMetadata(course: CourseSyncPortableCourse(learningCourse()), readingBookmark: nil, discussions: [], transcripts: [CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.learner, "Common question")])])
        let base = continuation(metadata)
        metadata.course?.progress = 0.6
        metadata.transcripts[0].messages.append(message(.agent, "Mac answer"))
        let mac = continuation(metadata)
        metadata.course?.progress = 0.4
        metadata.readingBookmark = CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-02", offset: 40, isAtEnd: false))
        metadata.transcripts[0].messages = [message(.learner, "Common question"), message(.agent, "Phone answer")]
        let phone = continuation(metadata)
        let merged = try XCTUnwrap(CourseSyncContinuationMerger.merge(base: base, local: mac, remote: phone))
        let reversed = try XCTUnwrap(CourseSyncContinuationMerger.merge(base: base, local: phone, remote: mac))
        XCTAssertEqual(merged, reversed)
        XCTAssertEqual(merged.metadata?.course?.progress, 0.6)
        XCTAssertEqual(merged.metadata?.readingBookmark?.pageID, "lesson-02")
        XCTAssertEqual(Set(merged.metadata?.transcripts.first?.messages.map(\.text) ?? []), ["Common question", "Mac answer", "Phone answer"])
    }

    func testIndependentCourseDisplayAndProgressChangesMergeInEitherDirection() throws {
        let metadata = CourseSyncContinuationMetadata(course: CourseSyncPortableCourse(learningCourse()), readingBookmark: nil, discussions: [], transcripts: [])
        let base = continuation(metadata)
        var local = base
        var remote = base
        local.metadata?.course?.progress = 0.5
        remote.metadata?.course?.lessonCount = 3
        remote.metadata?.course?.title = "Updated course title"
        let forward = try XCTUnwrap(CourseSyncContinuationMerger.merge(base: base, local: local, remote: remote))
        let reversed = try XCTUnwrap(CourseSyncContinuationMerger.merge(base: base, local: remote, remote: local))
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.metadata?.course?.progress, 0.5)
        XCTAssertEqual(forward.metadata?.course?.lessonCount, 3)
        XCTAssertEqual(forward.metadata?.course?.title, "Updated course title")
    }

    #if DEBUG
    func testBookmarkSavedDuringRemoteWorkspaceCommitSurvivesContinuationApply() async throws {
        let fixture = try fixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try await repository(directory: fixture.mac, control: fixture.macControl)
        let baseMetadata = CourseSyncContinuationMetadata(
            course: CourseSyncPortableCourse(learningCourse()),
            readingBookmark: CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-01", offset: 10, isAtEnd: false), updatedAt: Date(timeIntervalSince1970: 10)),
            discussions: [], transcripts: []
        )
        try CourseContinuationSyncStore.saveMetadata(baseMetadata, courseDirectory: fixture.mac)
        let base = try await repository.exportSyncSnapshot(generationID: "before-remote")
        var incomingMetadata = baseMetadata
        incomingMetadata.transcripts = [CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.agent, "Cloud discussion")])]
        let remote = try CourseSyncWorkspaceSnapshot(workspaceID: "workspace", workspace: base.validatedWorkspace(), generationID: "remote", continuation: continuation(incomingMetadata))
        let directory = fixture.mac
        await repository.configureDebugContinuationApplyInterleaving {
            var current = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: directory))
            current.readingBookmark = CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-02", offset: 150, isAtEnd: true), updatedAt: Date(timeIntervalSince1970: 20))
            try CourseContinuationSyncStore.saveMetadata(current, courseDirectory: directory)
        }
        _ = try await repository.applyRemoteSyncSnapshot(remote, baseSnapshot: base)
        let applied = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: directory))
        XCTAssertEqual(applied.readingBookmark?.pageID, "lesson-02")
        XCTAssertEqual(applied.readingBookmark?.offset, 150)
        XCTAssertEqual(applied.transcripts.first?.messages.first?.text, "Cloud discussion")
    }
    #endif

    func testStableMessageIDsPreserveImportedBranchWhenLocalHistoryAppends() throws {
        let saved = CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.learner, "base"), message(.agent, "A"), message(.agent, "B")], messageIDs: ["base", "a", "b"])
        let local = CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.learner, "base"), message(.agent, "A"), message(.agent, "C")], messageIDs: ["base", "a", "c"])
        let merged = try CourseSyncContinuationMerger.mergeTranscript(local: saved, remote: local)
        let reversed = try CourseSyncContinuationMerger.mergeTranscript(local: local, remote: saved)
        XCTAssertEqual(merged, reversed)
        XCTAssertEqual(merged.messageIDs, ["base", "a", "b", "c"])
        XCTAssertEqual(merged.messages.map(\.text), ["base", "A", "B", "C"])
        XCTAssertEqual(try CourseSyncContinuationMerger.mergeTranscript(local: merged, remote: local), merged)
    }

    func testStaleLocalMetadataSaveMergesCloudFieldsInsteadOfReplacingThem() throws {
        let fixture = try fixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let previous = CourseSyncContinuationMetadata(course: CourseSyncPortableCourse(learningCourse()), readingBookmark: nil, discussions: [], transcripts: [])
        try CourseContinuationSyncStore.saveMetadata(previous, courseDirectory: fixture.mac)
        var localCandidate = previous
        localCandidate.readingBookmark = CourseSyncReadingBookmark(CourseReadingBookmark(pageID: "lesson-02", offset: 80, isAtEnd: false))
        var cloud = previous
        cloud.course?.lessonCount = 4
        cloud.transcripts = [CourseSyncDiscussionTranscript(discussionID: "course", messages: [message(.agent, "Message from another device")])]
        try CourseContinuationSyncStore.apply(continuation(cloud), courseDirectory: fixture.mac, controlDirectory: fixture.macControl)
        try CourseContinuationSyncStore.saveMetadata(localCandidate, replacing: previous, courseDirectory: fixture.mac)
        let final = try XCTUnwrap(CourseContinuationSyncStore.loadMetadata(courseDirectory: fixture.mac))
        XCTAssertEqual(final.course?.lessonCount, 4)
        XCTAssertEqual(final.readingBookmark?.pageID, "lesson-02")
        XCTAssertEqual(final.transcripts.first?.messages.first?.text, "Message from another device")
    }

    func testConflictingSourceAndPracticeChangesRemainUnapplied() throws {
        let baseFile = try CourseSyncContinuationFile(relativePath: "sources/extracted/input.md", data: Data("base".utf8))
        let localFile = try CourseSyncContinuationFile(relativePath: baseFile.relativePath, data: Data("local".utf8))
        let remoteFile = try CourseSyncContinuationFile(relativePath: baseFile.relativePath, data: Data("remote".utf8))
        let base = CourseSyncContinuation(metadata: nil, presentedPlan: nil, approvedPlan: nil, files: [baseFile], assessments: [])
        var local = base
        var remote = base
        local.files = [localFile]
        remote.files = [remoteFile]
        XCTAssertThrowsError(try CourseSyncContinuationMerger.merge(base: base, local: local, remote: remote))
        var first = practiceAttempt()
        let filename = CourseSyncChecksum.value(for: Data("\(first.courseID)\u{0}\(first.pageID)".utf8)) + ".json"
        let archive = CourseSyncAssessmentArchive(filename: filename, attempts: [first])
        let practiceBase = CourseSyncContinuation(metadata: nil, presentedPlan: nil, approvedPlan: nil, files: [], assessments: [archive])
        local = practiceBase
        remote = practiceBase
        first.answerText = "Mac response"
        local.assessments[0].attempts = [first]
        first.answerText = "Phone response"
        remote.assessments[0].attempts = [first]
        XCTAssertThrowsError(try CourseSyncContinuationMerger.merge(base: practiceBase, local: local, remote: remote))
    }

    func testShellWritableApprovalMirrorCannotGrantApprovalThroughSync() async throws {
        let fixture = try fixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try await repository(directory: fixture.mac, control: fixture.macControl)
        let mirror = fixture.mac.appendingPathComponent(".course/approved-plan.json")
        try JSONEncoder().encode(validPlan()).write(to: mirror)
        let snapshot = try await repository.exportSyncSnapshot(generationID: "untrusted-mirror")
        XCTAssertNil(snapshot.continuation?.approvedPlan)
        let mirrorApproved = await repository.isLatestPlanApproved()
        XCTAssertFalse(mirrorApproved)
    }

    func testTamperedAndEscapingSourceFilesAreRejectedBeforeImport() throws {
        var file = try CourseSyncContinuationFile(relativePath: "sources/input.txt", data: Data("source".utf8))
        var value = CourseSyncContinuation(metadata: nil, presentedPlan: nil, approvedPlan: nil, files: [file], assessments: [])
        file.data = Data("tampered".utf8)
        value.files = [file]
        XCTAssertThrowsError(try value.validate(workspaceID: "workspace"))
        file.relativePath = "../outside.txt"
        value.files = [file]
        XCTAssertThrowsError(try value.validate(workspaceID: "workspace"))
        file.relativePath = ".course/course-library.sqlite"
        value.files = [file]
        XCTAssertThrowsError(try value.validate(workspaceID: "workspace"))
    }

    func testHostedConversationBindingCannotPointAtDifferentCourseSession() throws {
        var course = learningCourse()
        course.hostedSessionID = UUID()
        let metadata = CourseSyncContinuationMetadata(
            course: CourseSyncPortableCourse(course), readingBookmark: nil, discussions: [], transcripts: [],
            hostedBindings: [CourseSyncHostedBinding(discussionID: "course", ownerSubject: "guest-" + String(repeating: "b", count: 64), serviceBaseURL: "https://learnfold.example", sessionID: UUID())]
        )
        XCTAssertThrowsError(try continuation(metadata).validate(workspaceID: "workspace"))
    }

    func testSourceSymlinkCannotOverwriteNativeCourseDatabase() throws {
        let fixture = try fixtureDirectories()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = fixture.mac.appendingPathComponent(".course/course-library.sqlite")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("protected database".utf8).write(to: database)
        let sources = fixture.mac.appendingPathComponent("sources")
        try FileManager.default.createSymbolicLink(at: sources, withDestinationURL: fixture.mac.appendingPathComponent(".course"))
        let file = try CourseSyncContinuationFile(relativePath: "sources/course-library.sqlite", data: Data("overwrite attempt".utf8))
        let value = CourseSyncContinuation(metadata: nil, presentedPlan: nil, approvedPlan: nil, files: [file], assessments: [])
        XCTAssertThrowsError(try CourseContinuationSyncStore.apply(value, courseDirectory: fixture.mac, controlDirectory: fixture.macControl))
        XCTAssertEqual(try Data(contentsOf: database), Data("protected database".utf8))
    }

    func testLegacyGenerationDoesNotEraseContinuationAndRetainsOldChecksumShape() throws {
        let metadata = CourseSyncContinuationMetadata(course: CourseSyncPortableCourse(learningCourse()), readingBookmark: nil, discussions: [], transcripts: [])
        let local = continuation(metadata)
        XCTAssertEqual(try CourseSyncContinuationMerger.merge(base: nil, local: local, remote: nil), local)
        let snapshot = try CourseSyncWorkspaceSnapshot(workspaceID: "workspace", workspace: PageWorkspace(rootTitle: "Course"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertNil(object["continuation"])
        let decoded = try JSONDecoder().decode(CourseSyncWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = try decoded.validatedWorkspace()
        let restoredSnapshot = try CourseSyncWorkspaceSnapshot(workspaceID: "workspace", workspace: restored)
        XCTAssertEqual(decoded.manifest, snapshot.manifest)
        XCTAssertEqual(decoded.checksum, snapshot.checksum)
        XCTAssertEqual(restoredSnapshot.checksum, snapshot.checksum)
    }

    private func continuation(_ metadata: CourseSyncContinuationMetadata) -> CourseSyncContinuation {
        CourseSyncContinuation(metadata: metadata.sanitized(), presentedPlan: nil, approvedPlan: nil, files: [], assessments: [])
    }

    private func message(_ role: CodexCourseTranscriptMessage.Role, _ text: String) -> CodexCourseTranscriptMessage {
        CodexCourseTranscriptMessage(role: role, text: text)
    }

    private func learningCourse() -> LearningCourse {
        LearningCourse(id: "continuation-course", title: "Continuation course", subtitle: "Continue on every device", accentHex: "00FF9C", progress: 0.2, lessonCount: 2, duration: "30 minutes", status: .ready, workspaceID: "workspace", agentRuntimeKind: "codex")
    }

    private func practiceAttempt() -> CourseAssessmentAttempt {
        CourseAssessmentAttempt(id: UUID(), courseID: "continuation-course", pageID: "lesson-01", assessmentID: "assessment-01", fingerprint: "question-fingerprint", questionTitle: "Practice question", questionPrompt: "Explain the first lesson", options: [], createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), submissionID: "", selectedOptionID: nil, answerText: "Saved learner answer", phase: .draft, review: nil, reviewError: nil, discussionOpened: false)
    }

    private func validPlan() -> CourseBrief {
        CourseBrief(planID: "continuation-plan", revision: 1, title: "Continuation course", summary: "Learn across devices", outcome: "Explain the core idea", startingPoint: "Some basic knowledge", focusGap: "Need a worked example", estimatedDuration: "30 minutes", structureVersion: 2, learningPath: [CourseLearningNode(id: "chapter-01", title: "First chapter", kind: .folder, status: .pendingGeneration, role: .chapter, children: [CourseLearningNode(id: "lesson-01", title: "First lesson", kind: .markdown, status: .pendingGeneration, role: .lesson)])], chapters: [CourseChapter(id: "chapter-01", title: "First chapter", objective: "Understand the core idea", deliverables: ["First lesson"])])
    }

    private func repository(directory: URL, control: URL) async throws -> CourseDocumentRepository {
        let repository = try await CourseDocumentRepository.open(workspaceID: "workspace", databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"), rootTitle: "Continuation course", autosaveDelay: .seconds(60))
        await repository.configureContinuationControlDirectory(control)
        return repository
    }

    private func fixtureDirectories() throws -> (root: URL, mac: URL, phone: URL, macControl: URL, phoneControl: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CourseContinuationSyncTests-\(UUID().uuidString)", isDirectory: true)
        let mac = root.appendingPathComponent("Mac/Courses/workspace", isDirectory: true)
        let phone = root.appendingPathComponent("Phone/Courses/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: phone, withIntermediateDirectories: true)
        return (root, mac, phone, root.appendingPathComponent("Mac/Control/workspace"), root.appendingPathComponent("Phone/Control/workspace"))
    }
}
