import Foundation

struct CodexCourseTranscriptMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case learner
        case agent
    }

    var role: Role
    var text: String
}

struct CodexCourseTranscript: Codable, Equatable, Sendable {
    /// Leading messages carried over from a thread this one replaced; they are
    /// not part of this thread's own app-server transcript.
    var carriedOverCount: Int
    /// Everything the learner has seen in this conversation, oldest first.
    var messages: [CodexCourseTranscriptMessage]

    var carriedOver: [CodexCourseTranscriptMessage] {
        Array(messages.prefix(carriedOverCount))
    }
}

/// The device's own copy of each Codex course conversation, keyed by thread.
///
/// The Codex rollout is the source of truth, but it can disappear (deleted,
/// corrupted, or a reset remote server). Without it `thread/resume` fails and
/// the course could never continue, so the course rebuilds the thread from
/// this copy instead.
struct CodexCourseTranscriptStore {
    let rootURL: URL

    func transcript(threadID: String) -> CodexCourseTranscript? {
        guard let data = try? Data(contentsOf: fileURL(threadID: threadID)) else { return nil }
        return try? JSONDecoder().decode(CodexCourseTranscript.self, from: data)
    }

    /// Saves the conversation visible in `items` behind any carried-over
    /// history. A reload that shows less than the saved copy (an empty or
    /// partial read) never shrinks it.
    @discardableResult
    func record(threadID: String, items: [HydratedConversationItem]) -> CodexCourseTranscript? {
        let saved = transcript(threadID: threadID)
        let carriedOver = saved?.carriedOver ?? []
        let next = CodexCourseTranscript(
            carriedOverCount: carriedOver.count,
            messages: carriedOver + Self.messages(from: items)
        )
        guard next.messages.count > (saved?.messages.count ?? 0) else { return saved }
        try? write(next, threadID: threadID)
        return next
    }

    /// Starts the copy of a thread rebuilt from `carriedOver`.
    func seed(threadID: String, carriedOver: [CodexCourseTranscriptMessage]) throws {
        try write(
            CodexCourseTranscript(carriedOverCount: carriedOver.count, messages: carriedOver),
            threadID: threadID
        )
    }

    static func messages(from items: [HydratedConversationItem]) -> [CodexCourseTranscriptMessage] {
        items.compactMap { item in
            switch item.content {
            case .user(let data):
                let text = learnerText(data.text)
                return text.isEmpty ? nil : CodexCourseTranscriptMessage(role: .learner, text: text)
            case .assistant(let data):
                let text = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : CodexCourseTranscriptMessage(role: .agent, text: text)
            default:
                return nil
            }
        }
    }

    /// Drops the source receipts a course appends to the learner's text.
    private static func learnerText(_ text: String) -> String {
        let visible = text.range(of: "\n\n<learnfold_source_ingestion>").map { String(text[..<$0.lowerBound]) } ?? text
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ transcript: CodexCourseTranscript, threadID: String) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: fileURL(threadID: threadID), options: .atomic)
    }

    private func fileURL(threadID: String) -> URL {
        let name = threadID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? threadID
        return rootURL.appendingPathComponent("\(name).json", isDirectory: false)
    }
}
