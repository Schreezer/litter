import XCTest
@testable import Litter

/// Hosted model providers reject tool schemas nested more than 10 levels.
/// Every tool the course agents see must stay well under that.
final class CourseAgentToolSchemaDepthTests: XCTestCase {
    static let maximumSchemaDepth = 8

    func testHostedToolSchemasStayWellUnderTheProviderNestingLimit() throws {
        let definitions = try CourseAgentTools.mcpToolDefinitions()
        XCTAssertTrue(definitions.contains { $0.name == CourseAgentTools.presentPlan })
        for definition in definitions {
            let depth = Self.schemaDepth(definition.inputSchema)
            XCTAssertLessThanOrEqual(
                depth,
                Self.maximumSchemaDepth,
                "\(definition.name) schema is nested \(depth) levels"
            )
        }
    }

    func testDynamicToolSchemasStayWellUnderTheProviderNestingLimit() throws {
        let specs = try [
            CourseAgentTools.dynamicToolSpec(),
            CourseAgentTools.courseBashDynamicToolSpec(),
        ] + CourseAgentTools.documentToolSpecs()
        for spec in specs {
            let object = try JSONSerialization.jsonObject(with: Data(spec.inputSchemaJson.utf8))
            let depth = Self.schemaDepth(object)
            XCTAssertLessThanOrEqual(depth, Self.maximumSchemaDepth, "\(spec.name) schema is nested \(depth) levels")
        }
    }

    func testAppleLessonToolTitleAndCheckAreRequiredShallowAndBounded() throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Foundation Models tools require iOS 26 or later.")
        }
        for kind in [
            CourseLessonExampleKind.topicDemonstration,
            .runnableCode(languageOrFramework: "Swift"),
        ] {
            let spec = try AppleCourseToolFactory.generateLessonSpec(exampleKind: kind)
            let schema = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(spec.inputSchemaJson.utf8)) as? [String: Any]
            )
            XCTAssertLessThanOrEqual(Self.schemaDepth(schema), Self.maximumSchemaDepth)
            let title = try XCTUnwrap((schema["properties"] as? [String: Any])?["title"] as? [String: Any])
            XCTAssertEqual(title["type"] as? String, "string")
            XCTAssertEqual(title["maxLength"] as? Int, CoursePlanHierarchyPolicy.maximumNodeTitleLength)
            // Small models skip optional fields, so every field is required;
            // planned lessons ignore the title they repeat.
            let required = Set(schema["required"] as? [String] ?? [])
            XCTAssertTrue(required.isSuperset(of: [
                "title", "explanation", "example", "exercise",
                "check_question", "check_options", "check_answer", "check_explanation",
            ]))
            let options = try XCTUnwrap((schema["properties"] as? [String: Any])?["check_options"] as? [String: Any])
            XCTAssertEqual(options["minItems"] as? Int, 2)
            XCTAssertEqual(options["maxItems"] as? Int, 4)
        }
        // The model writes fields in schema order: teach first, then check.
        let properties = try XCTUnwrap(
            (try JSONSerialization.jsonObject(
                with: Data(try AppleCourseToolFactory.generateLessonSpec(exampleKind: .topicDemonstration)
                    .inputSchemaJson.utf8)
            ) as? [String: Any])?["properties"] as? [String: [String: Any]]
        )
        XCTAssertEqual(AppleCourseGenerationSchemaOrdering.orderedKeys(in: properties), [
            "title", "explanation", "example", "exercise", "check_question",
            "check_options", "check_answer", "check_explanation", "visualization_html",
        ])
        #else
        throw XCTSkip("Foundation Models is unavailable.")
        #endif
    }

    func testPlanSchemaStillDescribesTheFourLevelHierarchy() throws {
        let schema = CourseAgentTools.planInputSchemaObject()
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let path = try XCTUnwrap(properties["learning_path"] as? [String: Any])
        let root = try XCTUnwrap(path["items"] as? [String: Any])
        let rootChildren = try XCTUnwrap((root["properties"] as? [String: Any])?["children"] as? [String: Any])
        let level2 = try XCTUnwrap(rootChildren["items"] as? [String: Any])
        let level2Properties = try XCTUnwrap(level2["properties"] as? [String: Any])
        XCTAssertEqual(
            (level2Properties["role"] as? [String: Any])?["enum"] as? [String],
            ["subchapter", "lesson", "module", "explainer"]
        )
        let level2Children = try XCTUnwrap(level2Properties["children"] as? [String: Any])
        let level3 = try XCTUnwrap(level2Children["items"] as? [String: Any])
        XCTAssertEqual(level3["type"] as? String, "object")
        let description = try XCTUnwrap(level3["description"] as? String)
        XCTAssertTrue(description.contains("children"))
        XCTAssertTrue(description.contains("\(CoursePlanHierarchyPolicy.maximumDepth) levels"))
    }

    /// Counts nested schema objects: each subschema reached through
    /// `properties`, `items`, `additionalProperties`, combinators,
    /// conditionals or definitions is one level deeper than its parent.
    static func schemaDepth(_ value: Any) -> Int {
        guard let schema = value as? [String: Any] else { return 0 }
        var children: [Any] = []
        for key in ["properties", "patternProperties", "$defs", "definitions"] {
            if let map = schema[key] as? [String: Any] {
                children.append(contentsOf: map.values)
            }
        }
        for key in ["items", "additionalProperties", "not", "if", "then", "else", "contains"] {
            if let child = schema[key] {
                if let array = child as? [Any] {
                    children.append(contentsOf: array)
                } else {
                    children.append(child)
                }
            }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            if let array = schema[key] as? [Any] {
                children.append(contentsOf: array)
            }
        }
        return 1 + (children.map(schemaDepth).max() ?? 0)
    }
}
