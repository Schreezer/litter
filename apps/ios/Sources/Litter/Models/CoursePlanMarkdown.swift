import Foundation

/// A course plan a course agent proposes in chat.
///
/// Like `CourseChatQuestion`, agents write the plan as a fenced block inside
/// an ordinary reply instead of calling a tool. The chat hides the fence and
/// Learnfold turns it into the native plan card. Learnfold derives every
/// identifier, role, and revision itself, so the agent only writes titles,
/// prose, and nesting.
///
/// Canonical form:
///
/// ```learnfold-plan
/// # Treasury Market Analysis
/// Summary: Analyst-level Treasury valuation, risk, and curve analysis.
/// Outcome: Price Treasuries, measure rate risk, and explain curve moves.
/// Starting point: Knows that bond prices fall when yields rise.
/// Focus: Rigorous duration, convexity, and curve math.
/// Duration: 12 hours
///
/// ## Valuation and yield
/// Objective: Price Treasury securities from cash flows and yields.
/// - Pricing a Treasury note
/// - Yield measures
///   - Worked example: a 10-year note
///   - Yield conventions (explainer)
/// ```
struct CoursePlanMarkdown: Equatable, Sendable {
    static let fenceLanguage = "learnfold-plan"
    static let defaultEstimatedDuration = "Adaptive"

    struct Node: Equatable, Sendable {
        var title: String
        var role: CourseLearningNode.Role?
        var children: [Node] = []
    }

    struct Chapter: Equatable, Sendable {
        var title: String
        var objective: String
        var children: [Node]
    }

    var title: String
    var summary: String
    var outcome: String
    var startingPoint: String
    var focusGap: String
    var estimatedDuration: String
    var chapters: [Chapter]

    /// One closed plan fence found in a message, in message order.
    enum Block: Equatable, Sendable {
        case plan(CoursePlanMarkdown)
        case invalid(String)
    }

    struct Extraction: Equatable, Sendable {
        /// The message with every plan fence removed.
        let text: String
        let blocks: [Block]
        /// True while a plan fence is open but not yet closed (mid-stream).
        let isIncomplete: Bool
    }

    // MARK: - Extraction

    static func containsFence(_ markdown: String) -> Bool {
        markdown.range(of: fenceLanguage, options: .caseInsensitive) != nil
    }

    static func extract(from markdown: String) -> Extraction {
        guard containsFence(markdown) else {
            return Extraction(text: markdown, blocks: [], isIncomplete: false)
        }
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var output: [String] = []
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard isOpeningFence(line) else {
                output.append(line)
                index += 1
                continue
            }
            guard let closingIndex = lines[(index + 1)...].firstIndex(where: isClosingFence) else {
                return Extraction(text: cleaned(output), blocks: blocks, isIncomplete: true)
            }
            let body = Array(lines[(index + 1)..<closingIndex])
            switch parse(body) {
            case .success(let plan): blocks.append(.plan(plan))
            case .failure(let issue): blocks.append(.invalid(issue.message))
            }
            index = closingIndex + 1
        }
        return Extraction(text: cleaned(output), blocks: blocks, isIncomplete: false)
    }

    /// Removes plan fences, including a still-streaming one, for display.
    static func strippingFences(from markdown: String) -> String {
        guard containsFence(markdown) else { return markdown }
        return extract(from: markdown).text
    }

    private static func isOpeningFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return language.caseInsensitiveCompare(fenceLanguage) == .orderedSame
        }
        return false
    }

    private static func isClosingFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "```" || trimmed == "~~~"
    }

    private static func cleaned(_ lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    struct Issue: Error, Equatable, Sendable {
        let message: String
    }

    static func parse(_ body: [String]) -> Result<CoursePlanMarkdown, Issue> {
        var title = ""
        var fields: [String: String] = [:]
        var chapters: [Chapter] = []
        // Bullet stack for the current chapter: (indent, path of child indexes).
        var stack: [(indent: Int, path: [Int])] = []
        var subchapterIndent: Int?

        func appendNode(_ node: Node, at path: [Int]) {
            guard !chapters.isEmpty else { return }
            let chapterIndex = chapters.count - 1
            func insert(into nodes: inout [Node], remaining: ArraySlice<Int>) {
                guard let first = remaining.first else {
                    nodes.append(node)
                    return
                }
                insert(into: &nodes[first].children, remaining: remaining.dropFirst())
            }
            insert(into: &chapters[chapterIndex].children, remaining: path[...])
        }

        func childCount(at path: [Int]) -> Int {
            guard !chapters.isEmpty else { return 0 }
            var nodes = chapters[chapters.count - 1].children
            for index in path {
                nodes = nodes[index].children
            }
            return nodes.count
        }

        for rawLine in body {
            let expanded = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = expanded.prefix(while: { $0 == " " }).count

            if let heading = heading(trimmed) {
                let text = cleanTitle(heading.text)
                switch heading.level {
                case 1:
                    if title.isEmpty { title = text }
                case 2:
                    chapters.append(Chapter(title: text, objective: "", children: []))
                    stack = []
                    subchapterIndent = nil
                default:
                    guard !chapters.isEmpty else { continue }
                    let (nodeTitle, _) = titleAndRole(text)
                    appendNode(Node(title: nodeTitle, role: .subchapter), at: [])
                    stack = [(indent: -1, path: [childCount(at: []) - 1])]
                    subchapterIndent = -1
                }
                continue
            }

            if let item = listItem(trimmed) {
                guard !chapters.isEmpty else { continue }
                while let last = stack.last, last.indent >= indent, last.indent != subchapterIndent {
                    stack.removeLast()
                }
                let parentPath = stack.last?.path ?? []
                let (nodeTitle, role) = titleAndRole(cleanTitle(item))
                appendNode(Node(title: nodeTitle, role: role), at: parentPath)
                stack.append((indent: indent, path: parentPath + [childCount(at: parentPath) - 1]))
                continue
            }

            if let field = keyValue(trimmed) {
                if chapters.isEmpty {
                    if field.key == "title" {
                        if title.isEmpty { title = cleanTitle(field.value) }
                    } else if fields[field.key] == nil {
                        fields[field.key] = field.value
                    }
                } else if field.key == "objective", chapters[chapters.count - 1].objective.isEmpty {
                    chapters[chapters.count - 1].objective = field.value
                }
                continue
            }

            // A plain prose line directly under a chapter heading reads as its
            // objective when the agent omitted the label.
            if let lastIndex = chapters.indices.last,
               chapters[lastIndex].objective.isEmpty,
               chapters[lastIndex].children.isEmpty {
                chapters[lastIndex].objective = trimmed
            }
        }

        var missing: [String] = []
        if title.isEmpty { missing.append("a `# Title` line") }
        for (key, label) in [
            ("summary", "Summary"),
            ("outcome", "Outcome"),
            ("starting_point", "Starting point"),
            ("focus_gap", "Focus"),
        ] where (fields[key] ?? "").isEmpty {
            missing.append("`\(label):`")
        }
        if chapters.isEmpty { missing.append("at least one `## Chapter` heading") }
        guard missing.isEmpty else {
            return .failure(Issue(message: "The plan is missing \(missing.joined(separator: ", "))."))
        }

        return .success(CoursePlanMarkdown(
            title: title,
            summary: fields["summary"] ?? "",
            outcome: fields["outcome"] ?? "",
            startingPoint: fields["starting_point"] ?? "",
            focusGap: fields["focus_gap"] ?? "",
            estimatedDuration: fields["estimated_duration"] ?? defaultEstimatedDuration,
            chapters: chapters
        ))
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func listItem(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where trimmed.hasPrefix(marker) {
            let text = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        var rest = Substring(trimmed)
        var digits = 0
        while let first = rest.first, first.isNumber, digits < 3 {
            rest = rest.dropFirst()
            digits += 1
        }
        guard digits > 0, let separator = rest.first, separator == "." || separator == ")" else {
            return nil
        }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static let fieldAliases: [String: String] = [
        "title": "title",
        "course title": "title",
        "summary": "summary",
        "outcome": "outcome",
        "outcomes": "outcome",
        "goal": "outcome",
        "starting point": "starting_point",
        "starting_point": "starting_point",
        "start": "starting_point",
        "focus": "focus_gap",
        "focus gap": "focus_gap",
        "focus_gap": "focus_gap",
        "gap": "focus_gap",
        "duration": "estimated_duration",
        "estimated duration": "estimated_duration",
        "estimated_duration": "estimated_duration",
        "objective": "objective",
        "goal of chapter": "objective",
    ]

    private static func keyValue(_ trimmed: String) -> (key: String, value: String)? {
        let unbolded = trimmed.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        guard let colon = unbolded.firstIndex(of: ":") else { return nil }
        let rawKey = unbolded[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard let key = fieldAliases[rawKey] else { return nil }
        let value = unbolded[unbolded.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : (key, value)
    }

    /// Strips Markdown emphasis and ordinal prefixes such as "Chapter 2:",
    /// "1.3", or "Lesson 4 -" so titles match the native pages.
    private static func cleanTitle(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
        let prefixes = [
            /^(?i:(?:chapter|part|unit|section|lesson|module)\s+\d+(?:\.\d+)*)\s*[.):\-–—]?\s*/,
            /^\d{1,2}(?:\.\d{1,2})+\.?\s+/,
            /^\d{1,2}[.)]\s+/,
        ]
        for prefix in prefixes {
            if let match = text.prefixMatch(of: prefix), match.output.count < text.count {
                text = String(text[match.range.upperBound...])
                break
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func titleAndRole(_ text: String) -> (String, CourseLearningNode.Role?) {
        let roles: [(String, CourseLearningNode.Role)] = [
            ("explainer", .explainer),
            ("module", .module),
            ("lesson", .lesson),
        ]
        let lowered = text.lowercased()
        for (name, role) in roles {
            for suffix in [" (\(name))", " [\(name)]"] where lowered.hasSuffix(suffix) {
                return (String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces), role)
            }
            let label = "\(name):"
            if lowered.hasPrefix(label), text.count > label.count {
                return (String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces), role)
            }
        }
        return (text, nil)
    }

    // MARK: - Brief

    /// A stable plan ID derived from the course title.
    static func planID(forTitle title: String) -> String {
        var id = slug(title, maximumLength: 64)
        if CoursePlanHierarchyPolicy.reservedContextNodeIDs.contains(id) {
            id += "-course"
        }
        return id
    }

    /// Builds the typed plan Learnfold persists and approves. Returns a
    /// learner- and agent-readable issue when the plan cannot fit the native
    /// course limits.
    func brief(planID: String, revision: Int) -> Result<CourseBrief, Issue> {
        typealias Policy = CoursePlanHierarchyPolicy
        var usedIDs = Policy.reservedContextNodeIDs.union([planID])
        func uniqueID(for title: String) -> String {
            let base = Self.slug(title, maximumLength: 96)
            var candidate = base
            var suffix = 2
            while !usedIDs.insert(candidate).inserted {
                candidate = "\(base)-\(suffix)"
                suffix += 1
            }
            return candidate
        }
        func clipped(_ value: String, _ limit: Int) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > limit else { return trimmed }
            return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        func typed(_ node: Node) -> CourseLearningNode {
            let children = node.children.map(typed)
            let role: CourseLearningNode.Role = children.isEmpty
                ? (node.role.flatMap { $0.isFolder ? nil : $0 } ?? .lesson)
                : .subchapter
            let title = clipped(node.title, Policy.maximumNodeTitleLength)
            return CourseLearningNode(
                id: uniqueID(for: title),
                title: title,
                kind: role.isFolder ? .folder : .markdown,
                status: .pendingGeneration,
                role: role,
                children: children
            )
        }

        var courseChapters: [CourseChapter] = []
        var learningPath: [CourseLearningNode] = []
        for chapter in chapters {
            let title = clipped(chapter.title, Policy.maximumNodeTitleLength)
            let id = uniqueID(for: title)
            var children = chapter.children.map(typed)
            if children.isEmpty {
                children = [typed(Node(title: title, role: .lesson))]
            }
            let objective = chapter.objective.isEmpty
                ? "Build a working understanding of \(title)."
                : clipped(chapter.objective, Policy.maximumChapterObjectiveLength)
            courseChapters.append(CourseChapter(
                id: id,
                title: title,
                objective: objective,
                deliverables: children.map {
                    clipped($0.title, Policy.maximumDeliverableLength)
                }
            ))
            learningPath.append(CourseLearningNode(
                id: id,
                title: title,
                kind: .folder,
                status: .pendingGeneration,
                role: .chapter,
                children: children
            ))
        }

        let brief = CourseBrief(
            planID: planID,
            revision: revision,
            title: clipped(title, Policy.maximumPlanTitleLength),
            summary: clipped(summary, Policy.maximumNarrativeFieldLength),
            outcome: clipped(outcome, Policy.maximumNarrativeFieldLength),
            startingPoint: clipped(startingPoint, Policy.maximumNarrativeFieldLength),
            focusGap: clipped(focusGap, Policy.maximumNarrativeFieldLength),
            estimatedDuration: clipped(estimatedDuration, Policy.maximumEstimatedDurationLength),
            structureVersion: Policy.currentStructureVersion,
            learningPath: learningPath,
            chapters: courseChapters
        )
        if let issue = Self.structureIssue(in: learningPath)
            ?? AppleCoursePlanValidator.issue(in: brief, requiresTypedHierarchy: true) {
            return .failure(Issue(message: "The plan can’t be used: \(issue)."))
        }
        return .success(brief)
    }

    /// Names the offending section when nesting exceeds the native depth,
    /// so a corrected plan can target the right place.
    private static func structureIssue(in roots: [CourseLearningNode]) -> String? {
        typealias Policy = CoursePlanHierarchyPolicy
        func visit(_ node: CourseLearningNode, depth: Int) -> String? {
            if depth > Policy.maximumDepth {
                return "“\(node.title)” is nested \(depth) levels deep; use at most \(Policy.maximumDepth) levels"
            }
            for child in node.children {
                if let issue = visit(child, depth: depth + 1) { return issue }
            }
            return nil
        }
        for root in roots {
            if let issue = visit(root, depth: 1) { return issue }
        }
        return nil
    }

    static func slug(_ text: String, maximumLength: Int) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        var result = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
            if result.count >= maximumLength { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count < 2 { result = "node-\(result.isEmpty ? "x" : result)" }
        return result
    }
}

/// Instructions every app-server course agent receives for proposing plans.
enum CoursePlanMarkdownPromptPolicy {
    static let exampleBlock = """
    ```\(CoursePlanMarkdown.fenceLanguage)
    # Treasury Market Analysis
    Summary: Analyst-level Treasury valuation, rate risk, and yield-curve analysis.
    Outcome: Price Treasuries, measure duration and convexity, and explain curve moves.
    Starting point: Knows that bond prices fall when yields rise.
    Focus: Rigorous duration, convexity, and curve math.
    Duration: 12 hours

    ## Valuation and yield
    Objective: Price Treasury securities from cash flows and quoted yields.
    - Pricing a Treasury note
    - Yield measures
      - Worked example: a 10-year note
      - Day-count and yield conventions (explainer)

    ## Duration and convexity
    Objective: Measure and hedge interest-rate risk.
    - Macaulay and modified duration
    - Convexity and large rate moves
    ```
    """

    static let instructions = """
    When you have enough evidence, briefly introduce the proposal in one or two sentences, then end the reply with a fenced block tagged `\(CoursePlanMarkdown.fenceLanguage)`. Learnfold renders it as the native plan card the learner approves. It is literal text in your reply, not a tool call. Inside the block write, in order: `# Course title`; the lines `Summary:`, `Outcome:`, `Starting point:`, `Focus:`, and `Duration:`, where the starting point and focus reflect your evidence about the learner; then one `## Chapter title` per chapter, each followed by an `Objective:` line and a bulleted list of its lessons. Indent bullets two spaces to group lessons under a section. Append `(explainer)` or `(module)` to a lesson title for those page types. Use as many chapters and lessons as the course needs; nesting goes at most \(CoursePlanHierarchyPolicy.maximumDepth) levels including the chapter. Titles have no numbering. Put nothing after the closing fence, and never describe the plan as a table or JSON outside the block.

    If Learnfold reports that a plan block can’t be used, send a corrected complete block. If the learner requests changes, discuss them and send a new complete block; Learnfold keeps the plan identity and increments the revision itself. Never tell the learner a plan card is ready unless the reply contains the block. Example:

    \(exampleBlock)
    """
}
