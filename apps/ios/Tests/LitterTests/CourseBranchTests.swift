import NativeBlockEditorCore
import NativeBlockEditorLibrary
import XCTest
@testable import Litter

final class CourseBranchTests: XCTestCase {
    private func document(role: String, status: String? = nil, question: String? = nil) -> BlockDocument {
        var document = BlockDocument(
            root: BlockNode(type: "page", children: [.paragraph("Lesson content")])
        )
        document.root.data["course_role"] = .string(role)
        if let status { document.root.data["course_generation_status"] = .string(status) }
        if let question { document.root.data["course_origin_question"] = .string(question) }
        return document
    }

    func testLessonWithQuestionBranchStaysAReadableLesson() throws {
        var workspace = PageWorkspace(rootTitle: "Course")
        let chapter = try workspace.createPage(
            title: "Chapter", parentID: workspace.rootPageID, icon: "doc.richtext",
            document: document(role: "chapter"), id: "chapter"
        )
        let lesson = try workspace.createPage(
            title: "Lesson", parentID: chapter.id, icon: "doc.richtext",
            document: document(role: "lesson", status: "generated"), id: "lesson"
        )
        _ = try workspace.createPage(
            title: "Why bills use discount rates", parentID: lesson.id, icon: "doc.richtext",
            document: document(
                role: "explainer", status: "pending_generation",
                question: "Why not quote a yield?"
            ),
            id: "branch"
        )

        let outline = try CourseDocumentRepository.outline(from: workspace)
        let lessonNode = try XCTUnwrap(outline.learningPages.first?.children.first)
        XCTAssertEqual(lessonNode.kind, .markdown)
        XCTAssertEqual(lessonNode.status, .generated, "A pending branch must not downgrade its lesson.")
        XCTAssertEqual(lessonNode.children.first?.originQuestion, "Why not quote a yield?")
        XCTAssertEqual(
            CourseReadingOrder.lessons(in: outline.learningPages).map(\.id),
            ["lesson"],
            "Branches are explorations, not part of the suggested route."
        )
    }

    func testFinishingABranchContinuesTheMainPath() {
        let branch = CourseLearningNode(
            id: "branch", title: "Branch", kind: .markdown, status: .generated,
            role: .explainer, pageID: "page-branch"
        )
        var first = CourseLearningNode(
            id: "a", title: "A", kind: .markdown, status: .generated,
            role: .lesson, pageID: "page-a"
        )
        first.children = [branch]
        let second = CourseLearningNode(
            id: "b", title: "B", kind: .markdown, status: .generated,
            role: .lesson, pageID: "page-b"
        )
        let nodes = [first, second]

        XCTAssertEqual(CourseReadingOrder.next(after: "page-branch", in: nodes)?.id, "b")
        XCTAssertEqual(
            CourseReadingOrder.resume(
                in: nodes,
                bookmark: .init(pageID: "page-branch", offset: 0, isAtEnd: false)
            )?.id,
            "branch",
            "Continue returns the learner to where they left off, even inside a branch."
        )
    }
}
