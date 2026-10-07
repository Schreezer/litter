import Foundation
import NativeEditorMCP

struct CourseMCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    let openWorld: Bool

    var jsonObject: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": readOnly,
                "openWorldHint": openWorld,
            ],
        ]
    }
}

enum CourseAgentTools {
    static let mcpServerName = "learnfold_course"
    static let mcpDirectNamespace = "mcp__\(mcpServerName)"
    static let workspaceIDArgument = "workspace_id"
    static let presentPlan = "present_course_plan"
    static let courseBash = "course_bash"

    static func dynamicToolSpec() throws -> AppDynamicToolSpec {
        let schemaData = try JSONSerialization.data(
            withJSONObject: planInputSchemaObject(),
            options: [.sortedKeys]
        )
        return AppDynamicToolSpec(
            name: presentPlan,
            description: """
            Present a complete course plan in the native course card after you have enough context. Speak a short natural-language introduction first, then call this tool. Do not print the plan as JSON or Markdown. Call it again with the same plan_id and a higher revision whenever the learner asks to change the plan. Do not call it after the learner approves the plan. Learnfold creates and validates the complete approved native course shell; the approval instruction names the one existing initial leaf you may update. Never create a missing planned page yourself; stop and request course-shell repair.
            """,
            inputSchemaJson: String(decoding: schemaData, as: UTF8.self),
            deferLoading: false
        )
    }

    static func courseBashDynamicToolSpec() throws -> AppDynamicToolSpec {
        let schemaData = try JSONSerialization.data(
            withJSONObject: addingWorkspaceID(to: courseBashSchema),
            options: [.sortedKeys]
        )
        return AppDynamicToolSpec(
            name: courseBash,
            description: """
            Run a shell script on the learner's iPhone against only the active course folder at /workspace. The workspace is read-only until the learner approves the protected course plan and read-write afterward. Network sockets and symbolic links are unavailable. Include the exact active workspace_id in every call.
            """,
            inputSchemaJson: String(decoding: schemaData, as: UTF8.self),
            deferLoading: false
        )
    }

    static func documentToolSpecs() throws -> [AppDynamicToolSpec] {
        try NativeEditorMCPToolCatalog.tools.map { tool in
            let schemaData = try JSONEncoder().encode(tool.inputSchema)
            return AppDynamicToolSpec(
                name: tool.name,
                description: tool.description,
                inputSchemaJson: String(data: schemaData, encoding: .utf8) ?? "{}",
                deferLoading: false
            )
        }
    }

    static func mcpToolDefinitions(
        includePresentPlan: Bool = true,
        includeCourseBash: Bool = true
    ) throws -> [CourseMCPToolDefinition] {
        var definitions: [CourseMCPToolDefinition] = []
        if includePresentPlan {
            definitions.append(CourseMCPToolDefinition(
                name: presentPlan,
                description: """
                Present a complete course plan in Learnfold's native approval card after you have enough learner context. Do not print the plan as JSON or Markdown. Call it again with the same plan_id and a higher revision when the learner requests changes.
                """,
                inputSchema: addingWorkspaceID(to: planInputSchemaObject()),
                readOnly: true,
                destructive: false,
                openWorld: false
            ))
        }
        if includeCourseBash {
            definitions.append(
                CourseMCPToolDefinition(
                    name: courseBash,
                    description: """
                    Run a shell script on this iPhone against the live course folder at /workspace. Before the learner approves the latest protected course plan, /workspace is read-only so you may inspect deterministic source material but cannot alter course files. After approval it is read-write. The shell cannot navigate to sibling courses or unrelated app files, symbolic links are unsupported, and internet/network sockets are unavailable. Use normal commands such as find, grep, sed, awk, cat, cp, mv, mkdir, and rm. Commands may partially modify files after approval even when they exit nonzero, so inspect the workspace before retrying a failed mutation.
                    """,
                    inputSchema: addingWorkspaceID(to: courseBashSchema),
                    readOnly: false,
                    destructive: true,
                    openWorld: false
                )
            )
        }
        definitions.append(contentsOf: try NativeEditorMCPToolCatalog.tools.map { tool in
            let schemaData = try JSONEncoder().encode(tool.inputSchema)
            return CourseMCPToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: addingWorkspaceID(to: try schemaObject(from: schemaData)),
                readOnly: tool.readOnly,
                destructive: tool.destructive,
                openWorld: false
            )
        })
        return definitions
    }

    static func isEditorTool(_ name: String) -> Bool {
        NativeEditorMCPToolCatalog.tools.contains(where: { $0.name == name })
    }

    static func isMutatingEditorTool(_ name: String) -> Bool {
        NativeEditorMCPToolCatalog.tools.contains {
            $0.name == name && !$0.readOnly
        }
    }

    static func isCourseTool(_ name: String) -> Bool {
        name == presentPlan || name == courseBash || isEditorTool(name)
    }

    static func isMutatingCourseTool(_ name: String) -> Bool {
        name == courseBash || isMutatingEditorTool(name)
    }

    private static func schemaObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return object
    }

    private static func addingWorkspaceID(to schema: [String: Any]) -> [String: Any] {
        var schema = schema
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties[workspaceIDArgument] = [
            "type": "string",
            "description": "The current Learnfold course workspace ID. Use the final path component of the course cwd.",
            "minLength": 1,
        ]
        schema["properties"] = properties
        var required = schema["required"] as? [String] ?? []
        if !required.contains(workspaceIDArgument) {
            required.append(workspaceIDArgument)
        }
        schema["required"] = required
        schema["additionalProperties"] = false
        return schema
    }

    static func planInputSchemaObject() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "plan_id": [
                    "type": "string",
                    "description": "Stable lowercase identifier for this plan. Reuse it for revisions.",
                    "minLength": 2,
                    "maxLength": 128,
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$",
                    "not": ["enum": CoursePlanHierarchyPolicy.reservedContextNodeIDs.sorted()],
                ],
                "revision": [
                    "type": "integer",
                    "description": "Positive revision number. Increase it for every replacement plan.",
                    "minimum": 1,
                ],
                "structure_version": [
                    "type": "integer",
                    "description": "Typed Learnfold course hierarchy version. Always use 2.",
                    "minimum": CoursePlanHierarchyPolicy.currentStructureVersion,
                    "maximum": CoursePlanHierarchyPolicy.currentStructureVersion,
                ],
                "title": [
                    "type": "string",
                    "description": "Human-facing course title.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumPlanTitleLength,
                ],
                "summary": [
                    "type": "string",
                    "description": "One concise sentence describing the course.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumNarrativeFieldLength,
                ],
                "outcome": [
                    "type": "string",
                    "description": "What the learner will understand or be able to build.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumNarrativeFieldLength,
                ],
                "starting_point": [
                    "type": "string",
                    "description": "The learner knowledge and experience this plan assumes.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumNarrativeFieldLength,
                ],
                "focus_gap": [
                    "type": "string",
                    "description": "The most important gap this course should close.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumNarrativeFieldLength,
                ],
                "estimated_duration": [
                    "type": "string",
                    "description": "Short human-readable estimate, such as 3h 30m or Adaptive.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumEstimatedDurationLength,
                ],
                "chapters": [
                    "type": "array",
                    "description": "Chapter summaries. IDs, titles, and order must exactly match the chapter roots in learning_path.",
                    "minItems": 1,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "id": [
                                "type": "string",
                                "description": "Stable lowercase chapter slug.",
                                "minLength": 2,
                                "maxLength": 128,
                                "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$",
                            ],
                            "title": [
                                "type": "string",
                                "description": "Short chapter title.",
                                "minLength": 1,
                                "maxLength": CoursePlanHierarchyPolicy.maximumNodeTitleLength,
                            ],
                            "objective": [
                                "type": "string",
                                "description": "What this chapter teaches.",
                                "minLength": 1,
                                "maxLength": CoursePlanHierarchyPolicy.maximumChapterObjectiveLength,
                            ],
                            "deliverables": [
                                "type": "array",
                                "minItems": 1,
                                "description": "Learner outcomes or artifacts for this chapter. Do not encode folders, subchapters, or lesson hierarchy here; use learning_path.",
                                "items": [
                                    "type": "string",
                                    "description": "A learner outcome or artifact.",
                                    "minLength": 1,
                                    "maxLength": CoursePlanHierarchyPolicy.maximumDeliverableLength,
                                ],
                            ],
                        ],
                        "required": ["id", "title", "objective", "deliverables"],
                    ],
                ],
                "learning_path": [
                    "type": "array",
                    "description": "The complete ordered native page hierarchy. Every planned chapter, subchapter, lesson, module, and explainer is a separate typed node. At most \(CoursePlanHierarchyPolicy.maximumDepth) levels deep, and every chapter or subchapter has at least one child; there is no limit on the number of chapters or pages. Node IDs must be unique across the whole plan and must not reuse plan_id. Root IDs and titles must exactly match chapters in order.",
                    "minItems": 1,
                    "items": planNodeSchema(depth: 1),
                ],
            ],
            "required": [
                "plan_id",
                "revision",
                "structure_version",
                "title",
                "summary",
                "outcome",
                "starting_point",
                "focus_gap",
                "estimated_duration",
                "chapters",
                "learning_path",
            ],
        ]
    }

    /// Plan levels spelled out as full schemas. Deeper levels share one
    /// opaque node schema: hosted model providers reject tool schemas nested
    /// more than 10 levels, and four fully typed levels reach 11. The plan
    /// shape is unchanged; `CoursePlanHierarchyPolicy` validates every level
    /// when the plan is presented.
    static let typedPlanSchemaLevels = 2

    /// Levels below `typedPlanSchemaLevels`: same fields as their parent,
    /// described instead of nested.
    private static func nestedPlanNodeSchema(depth: Int) -> [String: Any] {
        [
            "type": "object",
            "description": "A level-\(depth) page with the same fields as its parent: id (globally unique stable ID), title (no ordinal prefix), role, and children (always present, an empty array for pages). Role is one of subchapter, lesson, module, or explainer; only a subchapter has children, at least one. At most \(CoursePlanHierarchyPolicy.maximumDepth) levels in total, so level-\(CoursePlanHierarchyPolicy.maximumDepth) pages are lesson, module, or explainer with children [].",
        ]
    }

    private static func planNodeSchema(depth: Int) -> [String: Any] {
        let children: [String: Any]
        if depth < CoursePlanHierarchyPolicy.maximumDepth {
            children = [
                "type": "array",
                "minItems": depth == 1 ? 1 : 0,
                "items": depth < typedPlanSchemaLevels
                    ? planNodeSchema(depth: depth + 1)
                    : nestedPlanNodeSchema(depth: depth + 1),
            ]
        } else {
            children = [
                "type": "array",
                "minItems": 0,
                "maxItems": 0,
                "items": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
            ]
        }
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "id": [
                    "type": "string",
                    "description": "Globally unique stable node ID.",
                    "minLength": 2,
                    "maxLength": 128,
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$",
                ],
                "title": [
                    "type": "string",
                    "description": "Exact learner-facing page title without an ordinal prefix.",
                    "minLength": 1,
                    "maxLength": CoursePlanHierarchyPolicy.maximumNodeTitleLength,
                ],
                "role": [
                    "type": "string",
                    "description": depth == 1
                        ? "Chapter root role."
                        : "Typed native page role. Only subchapter may contain children.",
                    "enum": depth == 1
                        ? ["chapter"]
                        : depth < CoursePlanHierarchyPolicy.maximumDepth
                            ? ["subchapter", "lesson", "module", "explainer"]
                            : ["lesson", "module", "explainer"],
                ],
                "children": children,
            ],
            "required": ["id", "title", "role", "children"],
        ].merging(
            depth > 1 && depth < CoursePlanHierarchyPolicy.maximumDepth
                ? [
                    "allOf": [
                        [
                            "if": [
                                "properties": ["role": ["const": "subchapter"]],
                                "required": ["role"],
                            ],
                            "then": [
                                "properties": ["children": ["minItems": 1]],
                            ],
                        ],
                        [
                            "if": [
                                "properties": [
                                    "role": [
                                        "enum": ["lesson", "module", "explainer"],
                                    ],
                                ],
                                "required": ["role"],
                            ],
                            "then": [
                                "properties": ["children": ["maxItems": 0]],
                            ],
                        ],
                    ],
                ]
                : [:]
        ) { current, _ in current }
    }

    // Immutable schema is passed to Foundation as an untyped dictionary.
    nonisolated(unsafe) private static let courseBashSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script": [
                "type": "string",
                "description": "Shell script to run from /workspace.",
                "minLength": 1,
                "maxLength": CourseBashTool.maximumScriptBytes,
            ],
            "timeout_seconds": [
                "type": "integer",
                "description": "Optional execution deadline from 1 through 120 seconds.",
                "minimum": 1,
                "maximum": CourseBashTool.maximumTimeoutSeconds,
            ],
        ],
        "required": ["script"],
        "additionalProperties": false,
    ]
}
