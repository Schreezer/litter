#if os(iOS)
import NativeBlockEditorEngine
@testable import NativeBlockEditorUI
import UIKit
import XCTest

@MainActor
final class ReadingFlowLayoutTests: XCTestCase {
    private func block(_ node: BlockNode, _ index: Int, depth: Int = 0, number: Int? = nil) -> ReadingFlowBlock {
        var node = node
        node.data["block_id"] = .string("block-\(index)")
        return ReadingFlowBlock(node: node, path: BlockPath([index]), depth: depth, number: number)
    }

    private func layout(_ blocks: [ReadingFlowBlock], annotations: [NativeBlockEditorTextAnnotation] = []) -> ReadingFlowLayout {
        ReadingFlowLayout(blocks: blocks, annotations: annotations, traits: UITraitCollection())
    }

    func testSelectionAcrossParagraphsSplitsIntoBlockSegments() throws {
        let flow = layout([
            block(.paragraph("First paragraph."), 0),
            block(.paragraph("Second paragraph."), 1),
        ])
        XCTAssertEqual(flow.attributedText.string, "First paragraph.\nSecond paragraph.")
        XCTAssertEqual(flow.blockRanges, [NSRange(location: 0, length: 16), NSRange(location: 17, length: 17)])

        // "paragraph." through "Second".
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 6, length: 17)))
        XCTAssertEqual(selection.segments.map(\.text), ["paragraph.", "Second"])
        XCTAssertEqual(selection.segments.map(\.range), [
            NSRange(location: 6, length: 10),
            NSRange(location: 0, length: 6),
        ])
        XCTAssertEqual(selection.segments.map(\.blockID), ["block-0", "block-1"])
        XCTAssertEqual(selection.blockID, "block-0")
        XCTAssertEqual(selection.range, NSRange(location: 6, length: 10))
        XCTAssertEqual(selection.text, "paragraph.\nSecond")
        XCTAssertTrue(selection.spansMultipleBlocks)
    }

    func testSelectionInsideOneBlockStaysSingleSegment() throws {
        let flow = layout([
            block(.paragraph("Alpha beta"), 0),
            block(.paragraph("Gamma"), 1),
        ])
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 11, length: 5)))
        XCTAssertFalse(selection.spansMultipleBlocks)
        XCTAssertEqual(selection.path, BlockPath([1]))
        XCTAssertEqual(selection.text, "Gamma")
        XCTAssertNil(flow.selection(for: NSRange(location: 3, length: 0)))
    }

    func testSelectionDropsTheParagraphBreakAtEitherEnd() throws {
        let flow = layout([
            block(.paragraph("One"), 0),
            block(.paragraph("Two"), 1),
            block(.paragraph("Three"), 2),
        ])
        // From the end of "One" (only its break) through the start of "Three".
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 3, length: 5)))
        XCTAssertEqual(selection.segments.map(\.text), ["Two"])
    }

    func testSoftBreaksStayInsideTheirBlockAndKeepOffsets() throws {
        let flow = layout([
            block(.paragraph("Line one\nline two"), 0),
            block(.paragraph("Next"), 1),
        ])
        XCTAssertEqual(flow.blockRanges[1].location, 18)
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 5, length: 18)))
        XCTAssertEqual(selection.segments.map(\.text), ["one\nline two", "Next"],
                       "Selections report the block's own text, not the layout's line separator.")
    }

    func testMarkersAndQuoteBarsStayOutOfTheText() {
        let flow = layout([
            block(.bulletedList("Bullet"), 0),
            block(.numberedList("Numbered"), 1, number: 3),
            block(.quote("Quoted"), 2),
            block(.paragraph("Nested"), 3, depth: 1),
        ])
        XCTAssertEqual(flow.attributedText.string, "Bullet\nNumbered\nQuoted\nNested")
        XCTAssertEqual(flow.decorations.map(\.kind), [.bullet, .number(3), .quoteBar])

        let nested = flow.attributedText.attribute(
            .paragraphStyle, at: flow.blockRanges[3].location, effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(nested?.headIndent, ReadingFlowLayout.depthIndent)
        let bullet = flow.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bullet?.headIndent, ReadingFlowLayout.markerWidth + ReadingFlowLayout.markerSpacing)
    }

    func testAnnotationsLandInTheirOwnBlock() {
        let flow = layout(
            [block(.paragraph("Alpha"), 0), block(.paragraph("Beta gamma"), 1)],
            annotations: [NativeBlockEditorTextAnnotation(
                id: "discussion", blockID: "block-1", path: BlockPath([9]), range: NSRange(location: 5, length: 5)
            )]
        )
        var range = NSRange()
        let id = flow.attributedText.attribute(
            RichTextCodec.annotationIDKey, at: 11, effectiveRange: &range
        ) as? String
        XCTAssertEqual(id, "discussion")
        XCTAssertEqual(range, NSRange(location: 11, length: 5))
    }

    func testSelectionPassesOverAnImage() throws {
        var image = BlockNode(type: "image", data: ["url": .string("https://example.com/cell.png"), "alt": .string("A cell")])
        image.data["block_id"] = .string("block-1")
        let flow = layout([
            block(.paragraph("Before the image."), 0),
            ReadingFlowBlock(node: image, path: BlockPath([1]), depth: 0, number: nil),
            block(.paragraph("After the image."), 2),
        ])
        XCTAssertEqual(flow.attributedText.string, "Before the image.\n\u{FFFC}\nAfter the image.")
        XCTAssertEqual(flow.embedIndices[image.id], 18)
        XCTAssertNotNil(flow.attributedText.attribute(.attachment, at: 18, effectiveRange: nil) as? ReadingFlowAttachment)

        // "image." through "After".
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 11, length: 14)))
        XCTAssertEqual(selection.segments.map(\.text), ["image.", "[Image: A cell]", "After"])
        let picture = selection.segments[1]
        XCTAssertTrue(picture.isWholeBlock)
        XCTAssertEqual(picture.blockID, "block-1")
        XCTAssertEqual(picture.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(picture.imageSource, "https://example.com/cell.png")
        XCTAssertFalse(selection.segments[0].isWholeBlock)
    }

    func testCodeAndTablesJoinASelectionWithTheirText() throws {
        let table = BlockNode.table(cellRows: [
            [[.paragraph("Input")], [.paragraph("Output")]],
            [[.paragraph("2")], [.paragraph("4")]],
        ])
        let flow = layout([
            block(.code("let doubled = 2 * x"), 0),
            block(table, 1),
            block(.divider(), 2),
            block(.paragraph("Done"), 3),
        ])
        let selection = try XCTUnwrap(flow.selection(for: NSRange(location: 0, length: flow.attributedText.length)))
        XCTAssertEqual(selection.segments.map(\.text), [
            "let doubled = 2 * x",
            "Input | Output\n2 | 4",
            "Done",
        ], "Dividers carry nothing to discuss.")
        XCTAssertFalse(selection.segments[0].isWholeBlock, "Code keeps its text and range.")
        XCTAssertEqual(selection.segments[0].range, NSRange(location: 0, length: 19))
        XCTAssertTrue(selection.segments[1].isWholeBlock)
    }

    func testOnlyProseFlows() {
        XCTAssertTrue(ReadingFlowBlock.flows(.paragraph("Text")))
        XCTAssertTrue(ReadingFlowBlock.flows(.heading("Title")))
        XCTAssertFalse(ReadingFlowBlock.flows(.code("let x = 1")), "Code keeps its own view.")
        XCTAssertFalse(ReadingFlowBlock.flows(.divider()))
        XCTAssertTrue(block(.code("x"), 0).handlesOwnTouches, "Code scrolls on its own.")
        XCTAssertFalse(
            block(BlockNode(type: "image", data: [:]), 1).handlesOwnTouches,
            "Holding an image selects it."
        )
    }
}
#endif
