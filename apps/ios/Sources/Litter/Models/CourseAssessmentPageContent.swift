import Foundation
import NativeBlockEditorCore

/// The native document remains the editable source. This read-only projection
/// replaces reserved assessment code blocks with controls in the reader footer.
struct CourseAssessmentPageContent {
    let assessments: [CourseAssessmentDefinition]
    let hiddenBlockIDs: Set<UUID>
    let invalidCheckCount: Int

    static func extract(from document: BlockDocument) -> CourseAssessmentPageContent {
        var hidden: Set<UUID> = []
        var parsed: [CourseAssessmentDefinition] = []
        var invalid = 0
        var reservedParagraphParts: [String] = []

        func validate(_ body: String) {
            let result = parseCourseAssessmentBlock(body: body)
            if let assessment = result.assessment {
                parsed.append(assessment)
            } else {
                invalid += 1
            }
        }

        func finishReservedParagraphs() {
            guard !reservedParagraphParts.isEmpty else { return }
            validate(reservedParagraphParts.joined(separator: "\n\n"))
            reservedParagraphParts = []
        }

        for entry in document.flattenedNodes() {
            let node = entry.node
            let text = node.delta?.plainText ?? ""
            if !reservedParagraphParts.isEmpty {
                hidden.insert(node.id)
                reservedParagraphParts.append(text)
                if containsClosingFence(text) { finishReservedParagraphs() }
                continue
            }

            if node.type == "code" {
                guard isCourseAssessmentLanguage(language: node.data["language"]?.stringValue ?? "") else {
                    continue
                }
                // Reserve the language before validation: invalid data can still
                // contain an answer, so it must never fall back to visible code.
                hidden.insert(node.id)
                validate(text)
                continue
            }

            guard let markerIndex = reservedMarkerLine(in: text) else { continue }
            // The Markdown importer handles only column-zero backtick fences.
            // Tilde and indented imports may be paragraph text, and inline
            // formatting can already have changed their payload. Keep the
            // native source intact, hide its fragments, and let Rust decide
            // whether the remaining text is still a valid complete definition.
            hidden.insert(node.id)
            reservedParagraphParts = [text]
            let followingLines = text.components(separatedBy: "\n").dropFirst(markerIndex + 1)
            if followingLines.contains(where: isClosingFenceLine)
                || containsCompleteInlineReservedFence(node) {
                finishReservedParagraphs()
            }
        }
        finishReservedParagraphs()
        hidden.formUnion(assessmentOnlyHeadingIDs(in: document))
        let counts = Dictionary(grouping: parsed, by: \.id).mapValues(\.count)
        let unique = parsed.filter { counts[$0.id] == 1 }
        invalid += parsed.count - unique.count
        let maximumChecks = 8
        invalid += max(0, unique.count - maximumChecks)
        return CourseAssessmentPageContent(
            assessments: Array(unique.prefix(maximumChecks)),
            hiddenBlockIDs: hidden,
            invalidCheckCount: invalid
        )
    }

    /// The footer already names the check. Remove only a redundant top-level
    /// heading whose entire native section contains reserved checks and blank
    /// spacers. Do not infer this from hidden IDs: an incomplete paragraph fence
    /// can reserve later prose while its malformed payload is being hidden.
    private static func assessmentOnlyHeadingIDs(in document: BlockDocument) -> Set<UUID> {
        let blocks = document.root.children
        let labels: Set<String> = ["exercise", "exercises", "test your understanding"]
        var hidden: Set<UUID> = []

        for (index, heading) in blocks.enumerated() {
            guard heading.type == "heading", heading.children.isEmpty else { continue }
            var label = (heading.delta?.plainText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if label.hasSuffix(":") {
                label.removeLast()
                label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard labels.contains(label) else { continue }
            let level = heading.data["level"]?.intValue ?? 1
            let start = index + 1
            let end = blocks[start...].firstIndex {
                $0.type == "heading" && ($0.data["level"]?.intValue ?? 1) <= level
            } ?? blocks.endIndex
            let section = blocks[start..<end]
            var containsCheck = false
            let onlyChecks = section.allSatisfy { node in
                guard node.children.isEmpty else { return false }
                if node.type == "code",
                   isCourseAssessmentLanguage(language: node.data["language"]?.stringValue ?? "") {
                    containsCheck = true
                    return true
                }
                return node.type == "paragraph"
                    && (node.delta?.plainText ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if onlyChecks && containsCheck { hidden.insert(heading.id) }
        }
        return hidden
    }

    private static func reservedMarkerLine(in text: String) -> Int? {
        text.components(separatedBy: "\n").firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let language = String(trimmed.drop(while: { $0 == "`" || $0 == "~" }))
            return isCourseAssessmentLanguage(language: language)
        }
    }

    private static func isClosingFenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let character = trimmed.first, character == "`" || character == "~" else { return false }
        // Inline import can reduce a three-character delimiter to one. This
        // only bounds which native blocks are hidden; Rust validates the fence.
        return trimmed.allSatisfy { $0 == character }
    }

    private static func containsClosingFence(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains(where: isClosingFenceLine)
    }

    private static func containsCompleteInlineReservedFence(_ node: BlockNode) -> Bool {
        node.delta?.operations.contains { operation in
            guard case let .insert(text, attributes) = operation,
                  attributes?["code"]?.boolValue == true else { return false }
            return reservedMarkerLine(in: text) != nil
        } == true
    }
}

enum CourseAssessmentWorkflowError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}
