import Foundation
import Observation

/// The live text of one answer row.
///
/// Each answer row gets its own buffer, so a token invalidates only the view
/// that reads that buffer. The turn list, the other rows and the screen do
/// not redraw while text streams.
@Observable
@MainActor
final class LiveTextBuffer {
    let rowID: String
    private(set) var text: String
    /// Bumps when the text is replaced rather than extended, so a streaming
    /// renderer that has already consumed a prefix knows to start over.
    private(set) var generation = 0

    init(rowID: String, text: String = "") {
        self.rowID = rowID
        self.text = text
    }

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        text += delta
    }

    enum Sync: Equatable {
        case unchanged
        case appended(String)
        case replaced
    }

    /// Adopts authoritative text from a snapshot or row update. Extends in
    /// place when the new text continues the current one; otherwise replaces
    /// it.
    @discardableResult
    func sync(to authoritative: String) -> Sync {
        if authoritative == text { return .unchanged }
        if authoritative.hasPrefix(text) {
            let delta = String(authoritative.dropFirst(text.count))
            text = authoritative
            return .appended(delta)
        }
        if text.hasPrefix(authoritative) {
            // A stale copy that is behind what has already streamed. Keep the
            // newer text; the source will catch up.
            return .unchanged
        }
        text = authoritative
        generation += 1
        return .replaced
    }
}
