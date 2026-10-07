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

    func testAppleLessonToolTitleIsOptionalShallowAndBounded() throws {
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
            XCTAssertFalse(
                (schema["required"] as? [String] ?? []).contains("title"),
                "Planned lessons omit the title, so the schema must not require it."
            )
        }
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
