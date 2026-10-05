import NativeBlockEditorCore
import XCTest
@testable import Litter

final class CourseAssessmentPageContentTests: XCTestCase {
    func testAllThreeAssessmentKindsProjectWithoutChangingNativeDocument() throws {
        let document = BlockDocument(root: BlockNode(type: "page", children: [
            .paragraph("The lesson stays readable."),
            .code(choice(id: "oxygen-check"), language: "learnfold-assessment"),
            .code("""
                {"version":1,"id":"energy-explain","kind":"free_text","prompt":"Why do pumps need ATP?","rubric":["ATP supplies energy.","Pumps use that energy to maintain gradients."]}
                """, language: "learnfold-assessment"),
            .code("""
                {"version":1,"id":"energy-discussion","kind":"discussion","prompt":"Discuss energy loss.","opening_prompt":"What happens when ATP production falls?"}
                """, language: "learnfold-assessment"),
            .paragraph("Continue with the next lesson whenever you are ready."),
        ]))
        let original = document
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(document)

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertEqual(content.assessments.map(\.id), ["oxygen-check", "energy-explain", "energy-discussion"])
        XCTAssertEqual(content.assessments.map(\.kind), [.multipleChoice, .freeText, .discussion])
        XCTAssertEqual(content.hiddenBlockIDs.count, 3)
        XCTAssertEqual(content.invalidCheckCount, 0)
        XCTAssertEqual(document, original)
        XCTAssertEqual(try encoder.encode(document), encoded)
        XCTAssertFalse(visibleText(document, content: content).contains("SECRET-ASSESSMENT-KEY"))
        XCTAssertTrue(visibleText(document, content: content).contains("The lesson stays readable."))
    }

    func testDuplicateAssessmentIDsInvalidateBothDefinitionsAndKeepTheirKeysHidden() {
        let document = document([
            .code(choice(id: "same-check"), language: "learnfold-assessment"),
            .code(choice(id: "same-check"), language: "learnfold-assessment"),
            .code(choice(id: "different-check"), language: "learnfold-assessment"),
        ])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertEqual(content.assessments.map(\.id), ["different-check"])
        XCTAssertEqual(content.invalidCheckCount, 2)
        XCTAssertEqual(content.hiddenBlockIDs, Set(document.root.children.map(\.id)))
        XCTAssertFalse(visibleText(document, content: content).contains("SECRET-ASSESSMENT-KEY"))
    }

    func testOrdinaryCodeAndProseRemainVisibleEvenWhenTheyDiscussTheReservedFormat() {
        let ordinaryCode = BlockNode.code("""
            let example = "```learnfold-assessment"
            let key = "option_id"
            """, language: "swift")
        let ordinaryProse = BlockNode.paragraph("Use learnfold-assessment only for optional checks.")
        let document = document([ordinaryCode, ordinaryProse])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertTrue(content.assessments.isEmpty)
        XCTAssertTrue(content.hiddenBlockIDs.isEmpty)
        XCTAssertEqual(content.invalidCheckCount, 0)
        XCTAssertTrue(visibleText(document, content: content).contains("let key"))
        XCTAssertTrue(visibleText(document, content: content).contains("Use learnfold-assessment"))
    }

    func testMalformedUnsupportedAndMetadataTaggedReservedCodeNeverFallsBackToVisibleCode() {
        let document = document([
            .code("{\"answer\":\"SECRET-ASSESSMENT-KEY\"", language: "learnfold-assessment"),
            .code(choice(id: "future-check", version: 99), language: "learnfold-assessment"),
            .code("{\"unknown\":\"SECRET-ASSESSMENT-KEY\"}",
                  language: "Learnfold-Assessment unsupported-version"),
        ])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertTrue(content.assessments.isEmpty)
        XCTAssertEqual(content.hiddenBlockIDs, Set(document.root.children.map(\.id)))
        XCTAssertEqual(content.invalidCheckCount, 3)
        XCTAssertTrue(visibleText(document, content: content).isEmpty)
    }

    func testTildeAndIndentedImportsCannotLeakTheirParagraphPayloads() throws {
        let payload = choice(id: "imported-check")
        for fence in [
            "~~~learnfold-assessment\n\(payload)\n~~~",
            "    ```learnfold-assessment\n    \(payload)\n    ```",
        ] {
            let document = try AppFlowyMarkdownCodec().decode("""
                Before the check.

                \(fence)

                After the check.
                """)
            let original = document
            XCTAssertTrue(document.flattenedNodes().contains {
                $0.node.type == "paragraph" && ($0.node.delta?.plainText.contains("learnfold-assessment") == true)
            }, "The native importer exposes this unsupported fence as paragraph text")

            let content = CourseAssessmentPageContent.extract(from: document)
            let visible = visibleText(document, content: content)

            XCTAssertFalse(content.hiddenBlockIDs.isEmpty)
            XCTAssertTrue(content.assessments.isEmpty,
                          "Inline-imported payloads are not repaired or trusted by the Swift projection")
            XCTAssertEqual(content.invalidCheckCount, 1)
            XCTAssertFalse(visible.contains("SECRET-ASSESSMENT-KEY"))
            XCTAssertFalse(visible.contains("option_id"))
            XCTAssertFalse(visible.contains("learnfold-assessment"))
            XCTAssertTrue(visible.contains("Before the check."))
            XCTAssertTrue(visible.contains("After the check."))
            XCTAssertEqual(document, original)
        }
    }

    func testReservedFenceSplitAcrossParagraphsHidesEveryPayloadFragment() {
        let opening = BlockNode.paragraph("~~~learnfold-assessment")
        let payload = BlockNode.paragraph(choice(id: "future-check", version: 99))
        let closing = BlockNode.paragraph("~~~")
        let after = BlockNode.paragraph("The next explanation remains visible.")
        let document = document([opening, payload, closing, after])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertTrue(content.assessments.isEmpty)
        XCTAssertEqual(content.hiddenBlockIDs, [opening.id, payload.id, closing.id])
        XCTAssertEqual(content.invalidCheckCount, 1)
        XCTAssertEqual(visibleText(document, content: content), "The next explanation remains visible.")
    }

    func testUnclosedReservedParagraphFenceKeepsFollowingAnswerFragmentsHidden() {
        let opening = BlockNode.paragraph("~~~learnfold-assessment")
        let payload = BlockNode.paragraph("{\"answer\":\"SECRET-ASSESSMENT-KEY\"")
        let remainder = BlockNode.paragraph("Remaining payload without a closing fence.")
        let document = document([opening, payload, remainder])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertTrue(content.assessments.isEmpty)
        XCTAssertEqual(content.invalidCheckCount, 1)
        XCTAssertEqual(content.hiddenBlockIDs, Set(document.root.children.map(\.id)))
        XCTAssertTrue(visibleText(document, content: content).isEmpty)
    }

    func testCompleteUnmodifiedParagraphFenceUsesRustValidation() {
        let valid = BlockNode.paragraph("```learnfold-assessment\n\(choice(id: "paragraph-check"))\n```")
        let document = document([valid])

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertEqual(content.assessments.map(\.id), ["paragraph-check"])
        XCTAssertEqual(content.hiddenBlockIDs, [valid.id])
        XCTAssertEqual(content.invalidCheckCount, 0)
    }

    func testMaximumEightChecksStillHidesEveryReservedSourceBlock() {
        let blocks = (0..<10).map {
            BlockNode.code(choice(id: "check-\($0)"), language: "learnfold-assessment")
        }
        let document = document(blocks)

        let content = CourseAssessmentPageContent.extract(from: document)

        XCTAssertEqual(content.assessments.map(\.id), (0..<8).map { "check-\($0)" })
        XCTAssertEqual(content.invalidCheckCount, 2)
        XCTAssertEqual(content.hiddenBlockIDs, Set(blocks.map(\.id)))
        XCTAssertTrue(visibleText(document, content: content).isEmpty)
    }

    func testAssessmentOnlyExerciseHeadingIsHiddenWithoutChangingNativeDocument() throws {
        for label in ["Exercise", "Exercises:", " Test your understanding "] {
            let heading = BlockNode.heading(label, level: 2)
            let check = BlockNode.code(choice(id: "heading-check"), language: "learnfold-assessment")
            let document = document([.paragraph("Keep this explanation."), heading, .paragraph("  "), check])
            let original = document
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let originalData = try encoder.encode(document)

            let content = CourseAssessmentPageContent.extract(from: document)

            XCTAssertTrue(content.hiddenBlockIDs.contains(heading.id))
            XCTAssertTrue(content.hiddenBlockIDs.contains(check.id))
            XCTAssertEqual(content.assessments.map(\.id), ["heading-check"])
            XCTAssertTrue(visibleText(document, content: content).contains("Keep this explanation."))
            XCTAssertEqual(document, original)
            XCTAssertEqual(try encoder.encode(document), originalData)
        }
    }

    func testExerciseHeadingRemainsWhenSectionHasProseOrUnrelatedCode() {
        for additionalBlock in [
            BlockNode.paragraph("Explain your reasoning before checking your answer."),
            BlockNode.code("print(ATP)", language: "swift"),
        ] {
            let heading = BlockNode.heading("Exercise", level: 2)
            let check = BlockNode.code(choice(id: "mixed-check"), language: "learnfold-assessment")
            let document = document([heading, check, additionalBlock])

            let content = CourseAssessmentPageContent.extract(from: document)

            XCTAssertFalse(content.hiddenBlockIDs.contains(heading.id))
            XCTAssertFalse(content.hiddenBlockIDs.contains(additionalBlock.id))
            XCTAssertTrue(content.hiddenBlockIDs.contains(check.id))
        }
        let heading = BlockNode.heading("Exercise", level: 2)
        let malformedFence = BlockNode.paragraph("~~~learnfold-assessment")
        let document = document([heading, malformedFence, .paragraph("Unclosed assessment payload.")])
        XCTAssertFalse(CourseAssessmentPageContent.extract(from: document).hiddenBlockIDs.contains(heading.id),
                       "Hidden malformed paragraph fragments are not evidence of an assessment-only native section")
    }

    func testExerciseHeadingUsesSectionBoundaryAndPreservesNestedOrChildContent() {
        let boundaryHeading = BlockNode.heading("Exercises", level: 2)
        let summaryHeading = BlockNode.heading("Summary", level: 2)
        let summary = BlockNode.paragraph("This summary belongs to the next section.")
        let bounded = document([
            boundaryHeading,
            .code(choice(id: "bounded-check"), language: "learnfold-assessment"),
            summaryHeading,
            summary,
        ])
        let boundedContent = CourseAssessmentPageContent.extract(from: bounded)
        XCTAssertTrue(boundedContent.hiddenBlockIDs.contains(boundaryHeading.id))
        XCTAssertFalse(boundedContent.hiddenBlockIDs.contains(summaryHeading.id))
        XCTAssertFalse(boundedContent.hiddenBlockIDs.contains(summary.id))

        let heading = BlockNode.heading("Exercise", level: 2)
        let nestedHeading = BlockNode.heading("Challenge", level: 3)
        let nested = document([heading, nestedHeading,
                               .code(choice(id: "nested-check"), language: "learnfold-assessment")])
        let nestedContent = CourseAssessmentPageContent.extract(from: nested)
        XCTAssertFalse(nestedContent.hiddenBlockIDs.contains(heading.id))
        XCTAssertFalse(nestedContent.hiddenBlockIDs.contains(nestedHeading.id))

        var headingWithChild = BlockNode.heading("Exercise", level: 2)
        headingWithChild.children = [.paragraph("Keep this child explanation.")]
        let childSection = document([headingWithChild,
                                     .code(choice(id: "child-check"), language: "learnfold-assessment")])
        XCTAssertFalse(CourseAssessmentPageContent.extract(from: childSection)
            .hiddenBlockIDs.contains(headingWithChild.id))

        let embeddedHeading = BlockNode.heading("Exercise", level: 2)
        let container = BlockNode(type: "quote", children: [embeddedHeading,
            .code(choice(id: "embedded-check"), language: "learnfold-assessment")])
        XCTAssertFalse(CourseAssessmentPageContent.extract(from: document([container]))
            .hiddenBlockIDs.contains(embeddedHeading.id), "Nested containers remain intact")
    }

    private func document(_ blocks: [BlockNode]) -> BlockDocument {
        BlockDocument(root: BlockNode(type: "page", children: blocks))
    }

    private func choice(id: String, version: Int = 1) -> String {
        """
        {"version":\(version),"id":"\(id)","kind":"multiple_choice","prompt":"What gives ion pumps energy?","options":[{"id":"a","text":"ATP"},{"id":"b","text":"DNA storage"}],"answer":{"option_id":"a","explanation":"SECRET-ASSESSMENT-KEY"}}
        """
    }

    private func visibleText(_ document: BlockDocument, content: CourseAssessmentPageContent) -> String {
        document.flattenedNodes()
            .filter { !content.hiddenBlockIDs.contains($0.node.id) }
            .compactMap { $0.node.delta?.plainText }
            .joined(separator: "\n")
    }
}
