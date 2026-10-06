#if os(iOS)
import Foundation

/// Resolves overlapping text annotations into drawable runs. Each run knows
/// every annotation that covers it, so stacked highlights never hide each
/// other and a tap can reach all of them.
public enum NativeBlockEditorAnnotationComposer {
    public enum Hue: Sendable, Equatable {
        case branch
        case discussion
    }

    public enum Fill: Sendable, Equatable {
        case none
        case branchNew
        case branch
        case discussion
    }

    public enum UnderlinePattern: Sendable, Equatable {
        case solid
        case dashed
    }

    /// How one run is drawn, before colors are resolved for the appearance.
    public struct Token: Sendable, Equatable {
        public var fill: Fill
        public var underlineHue: Hue
        public var underlinePattern: UnderlinePattern
        /// A written passage the learner has not opened, or a discussion.
        public var isUnderlineStrong: Bool
        /// More than one annotation starts here: drawn with a double line.
        public var isStacked: Bool
        /// Editing mode: a faint line that cannot be tapped.
        public var isInert: Bool
    }

    public struct Run: Sendable, Equatable {
        public var range: NSRange
        public var annotationIDs: [String]
        public var primaryID: String
        public var token: Token
    }

    /// Runs for every stretch of text covered by at least one annotation.
    /// Uncovered gaps, such as the space between two adjacent sentences, get none.
    public static func runs(
        for annotations: [NativeBlockEditorTextAnnotation],
        textLength: Int,
        isEditable: Bool
    ) -> [Run] {
        let valid = valid(annotations, textLength: textLength)
        guard !valid.isEmpty else { return [] }
        let boundaries = Set(valid.flatMap { [$0.range.location, NSMaxRange($0.range)] }).sorted()
        var runs: [Run] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let covering = valid.filter { $0.range.location <= start && start < NSMaxRange($0.range) }
            guard let primary = primary(of: covering) else { continue }
            runs.append(Run(
                range: NSRange(location: start, length: end - start),
                annotationIDs: covering.map(\.id),
                primaryID: primary.id,
                token: token(for: covering, isEditable: isEditable)
            ))
        }
        return runs
    }

    /// Every annotation whose range contains the character, in host order.
    public static func annotations(
        covering characterIndex: Int,
        in annotations: [NativeBlockEditorTextAnnotation],
        textLength: Int
    ) -> [NativeBlockEditorTextAnnotation] {
        valid(annotations, textLength: textLength).filter {
            $0.range.location <= characterIndex && characterIndex < NSMaxRange($0.range)
        }
    }

    /// The most specific passage: the shortest annotation, the latest on a tie.
    public static func primary(
        of covering: [NativeBlockEditorTextAnnotation]
    ) -> NativeBlockEditorTextAnnotation? {
        covering.reversed().min { $0.range.length < $1.range.length }
    }

    /// Groups of annotations whose ranges overlap, in text order. Each group is
    /// one place on the page a reader can act on.
    public static func clusters(
        _ annotations: [NativeBlockEditorTextAnnotation],
        textLength: Int
    ) -> [[NativeBlockEditorTextAnnotation]] {
        let sorted = valid(annotations, textLength: textLength).sorted {
            ($0.range.location, NSMaxRange($0.range)) < ($1.range.location, NSMaxRange($1.range))
        }
        var clusters: [[NativeBlockEditorTextAnnotation]] = []
        var clusterEnd = -1
        for annotation in sorted {
            if annotation.range.location < clusterEnd, !clusters.isEmpty {
                clusters[clusters.count - 1].append(annotation)
                clusterEnd = max(clusterEnd, NSMaxRange(annotation.range))
            } else {
                clusters.append([annotation])
                clusterEnd = NSMaxRange(annotation.range)
            }
        }
        return clusters
    }

    private static func valid(
        _ annotations: [NativeBlockEditorTextAnnotation],
        textLength: Int
    ) -> [NativeBlockEditorTextAnnotation] {
        annotations.filter {
            $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= textLength
        }
    }

    private static func token(
        for covering: [NativeBlockEditorTextAnnotation],
        isEditable: Bool
    ) -> Token {
        let styles = covering.map(\.style)
        let branches = styles.filter(\.isBranch)
        let hue: Hue = branches.isEmpty ? .discussion : .branch
        if isEditable {
            return Token(
                fill: .none, underlineHue: hue, underlinePattern: .solid,
                isUnderlineStrong: false, isStacked: false, isInert: true
            )
        }
        let fill: Fill = if styles.contains(.branchNew) {
            .branchNew
        } else if styles.contains(.discussion) {
            .discussion
        } else if styles.contains(.branch) {
            .branch
        } else {
            .none
        }
        let written = branches.contains(.branchNew) || branches.contains(.branch)
        let pattern: UnderlinePattern = branches.isEmpty || written ? .solid : .dashed
        let isStrong = branches.isEmpty || branches.contains(.branchNew)
        return Token(
            fill: fill,
            underlineHue: hue,
            underlinePattern: pattern,
            isUnderlineStrong: isStrong,
            isStacked: covering.count > 1,
            isInert: false
        )
    }
}
#endif
