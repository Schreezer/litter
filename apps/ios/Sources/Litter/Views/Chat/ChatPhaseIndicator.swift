import SwiftUI

/// What the live turn shows for each phase. This is the only place phase maps
/// to UI, and it never looks at the provider.
struct ChatPhasePresentation: Equatable {
    enum Style: Equatable {
        /// Nothing extra; the rows themselves carry the state.
        case none
        /// A quiet caption, such as "Sending…".
        case caption
        /// A shimmering label for work the learner can't see yet.
        case shimmer
        case error
    }

    let style: Style
    let label: String?
    let subtitle: String?
    /// Sits under the learner's bubble instead of in the reply column.
    var trailing = false

    static let hidden = ChatPhasePresentation(style: .none, label: nil, subtitle: nil)

    static func make(phase: ChatTurnPhase, progress: String?) -> ChatPhasePresentation {
        switch phase {
        case .idle:
            return .hidden
        case .queued:
            return ChatPhasePresentation(style: .caption, label: "Sending…", subtitle: nil, trailing: true)
        case .accepted, .thinking:
            return ChatPhasePresentation(style: .shimmer, label: "Thinking", subtitle: progress)
        case .acting, .streaming:
            if let progress {
                return ChatPhasePresentation(style: .caption, label: progress, subtitle: nil)
            }
            // The live tool row or the growing text is the indicator.
            return .hidden
        case .awaitingInput:
            return ChatPhasePresentation(style: .caption, label: "Waiting for your answer", subtitle: nil)
        case .stopping:
            return ChatPhasePresentation(style: .shimmer, label: "Stopping…", subtitle: nil)
        case .settled(.completed), .settled(.interrupted):
            // The fold row and question options take over.
            return .hidden
        case .settled(.failed(let message)):
            return ChatPhasePresentation(style: .error, label: message, subtitle: nil)
        }
    }
}

/// Transport state, shown on its own so it never reads as agent activity.
struct ChatConnectionPresentation: Equatable {
    let label: String
    let systemImage: String

    static func make(_ connection: ChatConnectionPhase) -> ChatConnectionPresentation? {
        switch connection {
        case .live:
            nil
        case .syncing:
            ChatConnectionPresentation(label: "Syncing…", systemImage: "arrow.triangle.2.circlepath")
        case .reconnecting:
            ChatConnectionPresentation(label: "Reconnecting…", systemImage: "wifi.exclamationmark")
        case .offline:
            ChatConnectionPresentation(label: "Offline", systemImage: "wifi.slash")
        }
    }
}

struct ChatPhaseIndicator: View {
    let presentation: ChatPhasePresentation

    var body: some View {
        switch presentation.style {
        case .none:
            EmptyView()
        case .caption:
            if let label = presentation.label {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat-phase-caption")
            }
        case .shimmer:
            VStack(alignment: .leading, spacing: 3) {
                if let label = presentation.label {
                    ChatShimmerText(text: label)
                        .font(.subheadline.weight(.medium))
                }
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-phase-shimmer")
        case .error:
            if let label = presentation.label {
                Label {
                    Text(label)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .systemRed))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .systemRed).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityIdentifier("chat-phase-error")
            }
        }
    }
}

/// Text with a light band sweeping across it. Static under Reduce Motion.
struct ChatShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(.secondary)
        } else {
            TimelineView(.animation) { context in
                let period = 1.6
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                Text(text)
                    .foregroundStyle(.secondary)
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .primary.opacity(0.9), location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                            endPoint: UnitPoint(x: phase * 2, y: 0.5)
                        )
                        .mask { Text(text) }
                    }
            }
        }
    }
}
