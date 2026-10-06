import NativeBlockEditorCore
import NativeBlockEditorLibrary
import XCTest
@testable import Litter

final class CourseCloudSyncModelsTests: XCTestCase {
    func testCourseCloudRuntimeCapabilityMatchesBuildTarget() async throws {
        #if targetEnvironment(simulator)
        XCTAssertFalse(CourseCloudEntitlement.isRuntimeCloudKitAvailable)
        #elseif targetEnvironment(macCatalyst)
        // Catalyst capability comes from the running executable's signature;
        // an ad-hoc local app must stop before CKContainer raises an exception.
        if !CourseCloudEntitlement.isRuntimeCloudKitAvailable {
            let engine = CourseCloudSyncEngine()
            await engine.startIfAvailable()
            let availability = await engine.availability
            XCTAssertEqual(availability, .missingEntitlement)
        }
        #else
        XCTAssertTrue(CourseCloudEntitlement.isRuntimeCloudKitAvailable)
        #endif
    }

    func testCourseCloudSimulatorStartupStopsBeforeCloudKitConstruction() async throws {
        #if targetEnvironment(simulator)
        let engine = CourseCloudSyncEngine()

        await engine.startIfAvailable()

        let availability = await engine.availability
        XCTAssertEqual(availability, .missingEntitlement)
        #else
        throw XCTSkip("This regression only verifies the Simulator CloudKit guard.")
        #endif
    }

    func testDottedVectorDistinguishesCausalityFromConcurrency() {
        var first = CourseSyncVersionVector()
        let firstDot = first.nextDot(replicaID: "iphone")
        XCTAssertEqual(firstDot, CourseSyncDot(replicaID: "iphone", counter: 1))

        var descendant = first
        _ = descendant.nextDot(replicaID: "ipad")
        XCTAssertEqual(first.relation(to: descendant), .before)
        XCTAssertEqual(descendant.relation(to: first), .after)

        var concurrentA = first
        _ = concurrentA.nextDot(replicaID: "iphone")
        var concurrentB = first
        _ = concurrentB.nextDot(replicaID: "ipad")
        XCTAssertEqual(concurrentA.relation(to: concurrentB), .concurrent)
    }

    func testMutationResultIncludesDotAndObservedContext() {
        var observed = CourseSyncVersionVector(counters: ["iphone": 3, "ipad": 2])
        let dot = observed.nextDot(replicaID: "iphone")
        let mutation = CourseSyncMutationVersion(
            dot: dot,
            observed: CourseSyncVersionVector(counters: ["iphone": 3, "ipad": 2]),
            ancestorChecksum: "base"
        )

        XCTAssertEqual(mutation.resultingVector.counter(for: "iphone"), 4)
        XCTAssertEqual(mutation.resultingVector.counter(for: "ipad"), 2)
    }

    func testWorkspaceSnapshotRoundTripsEveryWorkspaceField() throws {
        let rootDate = Date(timeIntervalSince1970: 1_700_000_000)
        let root = PageRecord(
            id: "root",
            title: "Course",
            icon: "book",
            parentID: PageWorkspace.libraryRootItemID,
            document: .blank(),
            createdAt: rootDate,
            updatedAt: rootDate
        )
        var workspace = PageWorkspace(rootPage: root)
        let child = try workspace.createPage(
            title: "Lesson",
            parentID: "root",
            icon: "doc.richtext",
            document: BlockDocument(
                root: BlockNode(type: "page", children: [.paragraph("Synced content")])
            ),
            id: "lesson"
        )
        var items = workspace.items
        let originalItem = try XCTUnwrap(items[child.id])
        items[child.id] = NativeBlockEditorLibrary.LibraryItem(
            id: originalItem.id,
            kind: originalItem.kind,
            parentID: originalItem.parentID,
            sortKey: originalItem.sortKey,
            title: originalItem.title,
            icon: originalItem.icon,
            isFavorite: true,
            createdAt: originalItem.createdAt,
            updatedAt: originalItem.updatedAt,
            lastOpenedAt: rootDate.addingTimeInterval(60),
            trashedAt: originalItem.trashedAt
        )
        workspace = try PageWorkspace(
            rootPageID: workspace.rootPageID,
            pages: workspace.pages,
            items: items
        )

        let snapshot = try CourseSyncWorkspaceSnapshot(
            workspaceID: "workspace",
            workspace: workspace,
            generationID: "generation-1",
            version: CourseSyncVersionVector(counters: ["iphone": 7])
        )
        let restored = try snapshot.validatedWorkspace()

        XCTAssertEqual(restored, workspace)
        XCTAssertEqual(snapshot.manifest.rootPageID, "root")
        XCTAssertEqual(snapshot.manifest.pageChecksums.keys.sorted(), ["lesson", "root"])
        XCTAssertEqual(restored.item(id: "lesson")?.isFavorite, true)
        XCTAssertEqual(restored.item(id: "lesson")?.lastOpenedAt, rootDate.addingTimeInterval(60))
    }

    func testWorkspaceSnapshotRejectsTamperedPageChecksum() throws {
        let workspace = PageWorkspace(rootTitle: "Course")
        let snapshot = try CourseSyncWorkspaceSnapshot(
            workspaceID: "workspace",
            workspace: workspace,
            generationID: "generation-1"
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        pages[0]["checksum"] = "tampered"
        object["pages"] = pages
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let tampered = try JSONDecoder().decode(CourseSyncWorkspaceSnapshot.self, from: tamperedData)

        XCTAssertThrowsError(try tampered.validatedWorkspace()) { error in
            XCTAssertEqual(
                error as? CourseCloudSyncModelError,
                .checksumMismatch(workspace.rootPageID)
            )
        }
    }

    func testPathValidationRejectsTraversalAndAbsolutePaths() throws {
        XCTAssertEqual(
            try CourseSyncPathValidator.normalizedRelativePath("sources/originals/file.pdf"),
            "sources/originals/file.pdf"
        )
        XCTAssertThrowsError(try CourseSyncPathValidator.normalizedRelativePath("../secret"))
        XCTAssertThrowsError(try CourseSyncPathValidator.normalizedRelativePath("/private/file"))
        XCTAssertThrowsError(try CourseSyncPathValidator.normalizedRelativePath("sources/./file"))
    }

    func testRecordNamesAreDeterministicAndDoNotRevealIdentifiers() {
        let first = CourseSyncRecordName.page(
            workspaceID: "private-workspace",
            pageID: "private-page",
            checksum: "content-checksum"
        )
        let second = CourseSyncRecordName.page(
            workspaceID: "private-workspace",
            pageID: "private-page",
            checksum: "content-checksum"
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("private-workspace"))
        XCTAssertFalse(first.contains("private-page"))
    }

    func testCourseHeadRecordNameIsStableAcrossGenerations() {
        let first = CourseSyncRecordName.course(workspaceID: "private-workspace")
        let second = CourseSyncRecordName.course(workspaceID: "private-workspace")

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("private-workspace"))
    }

    func testHeadResolverIgnoresHistoricalDeliveryAfterNewerHead() {
        let accepted = makeHead(
            generationID: "generation-2",
            checksum: "checksum-2",
            counters: ["iphone": 2]
        )
        let historical = makeHead(
            generationID: "generation-1",
            checksum: "checksum-1",
            counters: ["iphone": 1]
        )

        XCTAssertEqual(
            CourseCloudHeadResolver.resolve(accepted: accepted, incoming: historical),
            .ignoreHistorical
        )
    }

    func testHeadResolverAcceptsNewerDeliveryAfterOlderHead() {
        let accepted = makeHead(
            generationID: "generation-1",
            checksum: "checksum-1",
            counters: ["iphone": 1]
        )
        let newer = makeHead(
            generationID: "generation-2",
            checksum: "checksum-2",
            counters: ["iphone": 2]
        )

        XCTAssertEqual(
            CourseCloudHeadResolver.resolve(accepted: accepted, incoming: newer),
            .accept
        )
    }

    func testHeadResolverMergesConcurrentDeliveries() {
        let accepted = makeHead(
            generationID: "generation-iphone",
            checksum: "checksum-iphone",
            counters: ["iphone": 1]
        )
        let concurrent = makeHead(
            generationID: "generation-ipad",
            checksum: "checksum-ipad",
            counters: ["ipad": 1]
        )

        XCTAssertEqual(
            CourseCloudHeadResolver.resolve(accepted: accepted, incoming: concurrent),
            .mergeConcurrent
        )
    }

    func testHeadResolverRejectsDifferentContentAtEqualVersion() {
        let accepted = makeHead(
            generationID: "generation-1",
            checksum: "checksum-1",
            counters: ["iphone": 1]
        )
        let invalid = makeHead(
            generationID: "generation-2",
            checksum: "checksum-2",
            counters: ["iphone": 1]
        )

        XCTAssertEqual(
            CourseCloudHeadResolver.resolve(accepted: accepted, incoming: invalid),
            .invalidEqualVersion
        )
    }

    private func makeHead(
        generationID: String,
        checksum: String,
        counters: [String: UInt64]
    ) -> CourseCloudHead {
        CourseCloudHead(
            workspaceID: "workspace",
            generationID: generationID,
            generationRecordName: "generation-\(generationID)",
            commitRecordName: "commit-\(generationID)",
            checksum: checksum,
            title: "Course",
            previousGenerationID: nil,
            version: CourseSyncVersionVector(counters: counters)
        )
    }
}
