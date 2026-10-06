import SwiftUI

// Row views for `ChatScreen`. Text rendering reuses the app's existing
// renderers (`StreamingAssistantBubble` for prose, `FormattedText` and the
// glass bubble for learner messages, `CourseChatQuestionOptionsView` for
// options) so the new screen reads exactly like today's chat.

/// The learner's message. Matches `UserBubble`, but exposes the bubble shape
/// itself so it can fly in from the composer.
struct ChatUserBubble: View {
    let text: String
    var imageDataURIs: [String] = []
    /// The source has not accepted the message yet.
    var isPending = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            if !text.isEmpty {
                FormattedText(text: text)
                    .litterFont(size: LitterFont.conversationBodyPointSize)
                    .foregroundColor(LitterTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .modifier(GlassRectModifier(cornerRadius: 20, tint: LitterTheme.accent.opacity(0.3)))
            }
        }
        .opacity(isPending ? 0.75 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-user-bubble")
        .accessibilityValue(isPending ? "sending" : "sent")
    }

    private var images: [UIImage] {
        imageDataURIs.compactMap { uri in
            guard let comma = uri.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
            return UIImage(data: data)
        }
    }
}

/// Agent prose. Reads the row's `LiveTextBuffer`, so a token redraws this
/// row and nothing else.
struct ChatAnswerRow: View {
    let rowID: String
    let buffer: LiveTextBuffer
    let isStreaming: Bool

    var body: some View {
        StreamingAssistantBubble(
            itemId: ChatScreenModel.rendererItemID(for: rowID),
            text: buffer.text,
            isStreaming: isStreaming
        )
        // A replaced (not extended) text restarts the streaming renderer.
        .id(buffer.generation)
        .accessibilityIdentifier("chat-answer-\(rowID)")
    }
}

/// Tools, commands, searches and reasoning. Shows one line (the running or
/// latest entry) and expands to every entry.
struct ChatWorkRow: View {
    var summary: String = ""
    let entries: [ChatWorkEntry]
    var isLive = false
    var startsExpanded = false
    @State private var isExpanded: Bool?

    private var expanded: Bool { isExpanded ?? startsExpanded }

    private var summaryEntry: ChatWorkEntry? {
        entries.last(where: { $0.status.isRunning }) ?? entries.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                ForEach(entries) { entry in
                    ChatWorkEntryRow(entry: entry)
                }
            } else if let summaryEntry {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded = true }
                } label: {
                    ChatWorkEntryLine(entry: summaryEntry, showsChevron: entries.count > 1 || summaryEntry.detail != nil)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows every step")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat-work-row")
    }
}

private struct ChatWorkEntryRow: View {
    let entry: ChatWorkEntry
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard entry.detail != nil else { return }
                withAnimation(.snappy(duration: 0.22)) { showsDetail.toggle() }
            } label: {
                ChatWorkEntryLine(
                    entry: entry,
                    showsChevron: entry.detail != nil,
                    chevronExpanded: showsDetail
                )
            }
            .buttonStyle(.plain)

            if showsDetail, let detail = entry.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }
}

private struct ChatWorkEntryLine: View {
    let entry: ChatWorkEntry
    var showsChevron = false
    var chevronExpanded = false

    private var symbol: String {
        switch entry.kind {
        case .tool, .widget, .agent: "wrench.and.screwdriver"
        case .command: "terminal"
        case .search: "magnifyingglass"
        case .fileChange: "doc.text"
        case .reasoning: "sparkles"
        case .image: "photo"
        case .todo: "checklist"
        case .other: "circle.dashed"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch entry.status {
                case .completed:
                    Image(systemName: "checkmark").foregroundStyle(LitterTheme.success)
                case .failed, .declined:
                    Image(systemName: "xmark").foregroundStyle(Color(uiColor: .systemRed))
                case .unknown, .pending, .inProgress:
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.semibold))
            .frame(width: 18)

            if entry.status.isRunning {
                ChatShimmerText(text: entry.title)
            } else {
                Text(entry.title)
                    .foregroundStyle(.secondary)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(chevronExpanded ? 90 : 0))
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "Worked for 9s ›" or "You stopped after 4s ›". Toggles the turn's work.
struct ChatFoldRow: View {
    let label: String
    let isExpanded: Bool
    let isInteractive: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(label)
                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .accessibilityIdentifier("chat-fold")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}

/// A question with tappable answers. Uses the course chat's option chips.
struct ChatQuestionRow: View {
    /// `nil` when the reply above already asks the question.
    let text: String?
    let options: [String]
    let isEnabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let text {
                Text(text)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CourseChatQuestionOptionsView(
                question: CourseChatQuestion(prompt: text ?? "", options: options),
                isEnabled: isEnabled,
                onSelect: onSelect
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatPlanRow: View {
    let rowID: String
    var plan: ChatPlan?
    var markdown: String?
    var invalidReason: String?
    var isStreaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.map { $0.title.isEmpty ? "Plan" : $0.title } ?? "Plan", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let plan {
                if !plan.summary.isEmpty {
                    Text(plan.summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(plan.chapters.enumerated()), id: \.offset) { index, chapter in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(chapter.title)
                            .font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if let markdown, !markdown.isEmpty {
                StreamingAssistantBubble(
                    itemId: ChatScreenModel.rendererItemID(for: rowID),
                    text: markdown
                )
            } else if isStreaming {
                ChatShimmerText(text: "Writing the plan…")
                    .font(.subheadline)
            }
            if let invalidReason {
                Label(invalidReason, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .systemOrange))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-plan-row")
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

struct ChatNoticeRow: View {
    let tone: ChatNoticeTone
    let title: String
    var message: String?

    private var symbol: String {
        switch tone {
        case .info: "info.circle"
        case .divider: "minus"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch tone {
        case .info, .divider: .secondary
        case .error: Color(uiColor: .systemRed)
        }
    }

    var body: some View {
        if tone == .divider {
            HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.footnote.weight(message == nil ? .regular : .semibold))
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .padding(.leading, 26)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chat-notice")
        }
    }
}

extension AppOperationStatus {
    var isRunning: Bool {
        switch self {
        case .unknown, .pending, .inProgress: true
        case .completed, .failed, .declined: false
        }
    }
}
