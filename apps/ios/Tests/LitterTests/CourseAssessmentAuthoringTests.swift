import XCTest
@testable import Litter

@MainActor
final class CourseAssessmentAuthoringTests: XCTestCase {
    func testInitialApprovedGenerationCarriesAuthoringContractForHostedAndOtherRuntimes() {
        var brief = CourseBrief()
        brief.planID = "cell-energy"
        brief.revision = 3
        brief.title = "Cellular energetics"
        let target = PreparedCourseLessonTarget(
            nodeID: "oxygen-and-atp",
            title: "Oxygen and ATP",
            pageID: "page-oxygen-and-atp",
            revision: 2,
            courseRole: "lesson"
        )

        for runtime in [CourseAgentProvider.hosted, CourseAgentProvider.codex, CourseAgentProvider.appleOnDevice] {
            let prompt = CourseExperienceStore.approvedCourseGenerationPrompt(
                brief: brief,
                runtimeID: runtime,
                target: target
            )
            assertGenerationEnvelope(
                prompt,
                purpose: "approve_course_plan",
                originalPrefix: "I approve course plan cell-energy, revision 3."
            )
            XCTAssertTrue(prompt.contains("page ID: page-oxygen-and-atp"), runtime)
            XCTAssertTrue(prompt.contains("Do not create or edit any sibling, ancestor, or later page"), runtime)
            XCTAssertTrue(prompt.contains("visible lesson prose limit excludes the reserved assessment JSON definition"), runtime)
        }
    }

    func testNextLessonGenerationCarriesAuthoringContractInsideOriginalTaggedInstruction() {
        let prompt = CourseExperienceStore.targetedGenerationPrompt(
            for: CourseLearningNode(
                id: "membrane-pumps",
                title: "Membrane pumps",
                kind: .markdown,
                status: .pendingGeneration,
                role: .lesson,
                pageID: "page-membrane-pumps"
            )
        )

        assertGenerationEnvelope(
            prompt,
            purpose: "generate_course_node",
            originalPrefix: "Generate only the existing approved module ‘Membrane pumps’ (node ID: membrane-pumps)."
        )
        XCTAssertTrue(prompt.contains("Its native editor page ID is page-membrane-pumps."))
        XCTAssertTrue(prompt.contains("This request was started from the Learn screen"))
        XCTAssertTrue(prompt.contains("Never report success from a chat reply alone"))
        XCTAssertTrue(prompt.contains("properties.generation_status=generated together in the same native-editor-update-page call"))
    }

    private func assertGenerationEnvelope(
        _ prompt: String,
        purpose: String,
        originalPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedPrefix = "<learnfold_internal_course_instruction version=\"1\">\npurpose: \(purpose)\n\(originalPrefix)"
        XCTAssertTrue(prompt.hasPrefix(expectedPrefix), file: file, line: line)
        XCTAssertTrue(prompt.hasSuffix("</learnfold_internal_course_instruction>"), file: file, line: line)
        XCTAssertTrue(CourseAgentInternalPromptPolicy.isInternalInstruction(prompt), file: file, line: line)
        XCTAssertEqual(
            prompt.components(separatedBy: CourseAssessmentAuthoring.authoringInstructions).count,
            2,
            "The full authoring contract must travel in the generation turn exactly once.",
            file: file,
            line: line
        )
        for kind in ["multiple_choice", "free_text", "discussion"] {
            XCTAssertTrue(prompt.contains("\"kind\":\"\(kind)\""), file: file, line: line)
        }
        XCTAssertFalse(prompt.contains("```learnfold-review"), file: file, line: line)
    }
}
