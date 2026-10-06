import SwiftUI

/// One learner message and the agent's reply.
///
/// Equatable on its value inputs only, so streaming in one turn, or a phase
/// change, never re-evaluates the other turns.
struct TurnSection: View, Equatable {
    let turn: ChatTurn
    /// Non-nil only for the live turn.
    let livePhase: ChatTurnPhase?
    let progressLabel: String?
    /// The answer row streaming right now. Non-nil only in the live turn.
    let streamingRowID: String?
    /// The question whose options can be tapped, if it is in this turn.
    let answerableQuestionRowID: String?
    /// The reserved height for the live turn, `nil` for every other turn.
    let minHeight: CGFloat?
    let showsReserveGuide: Bool
    let bubbleNamespace: Namespace.ID
    /// Only used to look up `LiveTextBuffer`s, which are not observed state,
    /// so reading them doesn't subscribe this view to the model.
    let model: ChatScreenModel
    /// Reports the live turn's natural content height (without reserve).
    let onContentHeightChange: ((CGFloat) -> Void)?
    /// A tapped question option and the question row's id.
    let onChoose: (_ option: String, _ rowID: String) -> Void
    /// Hides error notices and the failed-phase caption because the host
    /// already shows this failure.
    var hidesErrorNotices = false
    /// Content after the rows of the newest turn. A turn with trailing
    /// content always re-evaluates, since `AnyView` can't be compared.
    var trailing: AnyView?

    @State private var showsFoldedWork = false
    @State private var contentHeight: CGFloat = 0

    static func == (lhs: TurnSection, rhs: TurnSection) -> Bool {
        lhs.trailing == nil && rhs.trailing == nil
            && lhs.turn == rhs.turn
            && lhs.livePhase == rhs.livePhase
            && lhs.progressLabel == rhs.progressLabel
            && lhs.streamingRowID == rhs.streamingRowID
            && lhs.answerableQuestionRowID == rhs.answerableQuestionRowID
            && lhs.hidesErrorNotices == rhs.hidesErrorNotices
            && lhs.minHeight == rhs.minHeight
            && lhs.showsReserveGuide == rhs.showsReserveGuide
            && lhs.bubbleNamespace == rhs.bubbleNamespace
            && lhs.model === rhs.model
            && (lhs.onContentHeightChange == nil) == (rhs.onContentHeightChange == nil)
    }

    private var isLive: Bool { livePhase != nil }

    /// Agents usually ask the question in prose too; don't print it twice.
    private func promptAlreadyShown(_ prompt: String, before rowID: String) -> Bool {
        let needle = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let index = turn.rows.firstIndex(where: { $0.id == rowID }) else { return false }
        for row in turn.rows[..<index].reversed() {
            guard case .answer(let text, _, _) = row.kind else { continue }
            let shown = model.buffer(for: row.id)?.text ?? text
            return shown.contains(needle)
        }
        return false
    }

    private var hasErrorNotice: Bool {
        turn.rows.contains { row in
            if case .notice(.error, _, _) = row.kind { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = turn.user, case .user(let text, let images, let delivery) = user.kind {
                ChatUserBubble(text: text, imageDataURIs: images, isPending: delivery == .pending)
                    // Position only: borrowing the composer's width would make
                    // the row wider than the screen mid-flight and push the
                    // whole scroll view sideways.
                    .matchedGeometryEffect(id: turn.viewID, in: bubbleNamespace, properties: .position)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)),
                        removal: .opacity
                    ))
                    .padding(.leading, 48)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ForEach(displayRows) { row in
                rowView(row)
                    .transition(.opacity)
            }

            if let livePhase {
                let presentation = ChatPhasePresentation.make(phase: livePhase, progress: progressLabel)
                // Rust already shows a failed turn as an error notice row.
                if presentation.style != .none,
                   !(presentation.style == .error && (hasErrorNotice || hidesErrorNotices)) {
                    ChatPhaseIndicator(presentation: presentation)
                        .frame(maxWidth: .infinity, alignment: presentation.trailing ? .trailing : .leading)
                        .transition(.opacity)
                }
            }

            if let trailing {
                trailing
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            // Only the harness guide reads this; writing it otherwise would
            // re-evaluate the turn on every wrapped line.
            if showsReserveGuide { contentHeight = height }
            onContentHeightChange?(height)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .top)
        .background(alignment: .bottom) {
            if showsReserveGuide, let minHeight {
                ChatReserveGuide(height: max(0, minHeight - contentHeight))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isLive ? "chat-live-turn" : "chat-turn")
    }

    /// Rows in display order. Rust places a settled turn's fold before the
    /// first row it folds; while collapsed, `foldedRowIds` stay hidden.
    private var displayRows: [ChatTimelineRow] {
        Self.displayRows(
            turn.rows,
            showsFoldedWork: showsFoldedWork,
            hidesErrorNotices: hidesErrorNotices
        )
    }

    static func displayRows(
        _ rows: [ChatTimelineRow],
        showsFoldedWork: Bool,
        hidesErrorNotices: Bool
    ) -> [ChatTimelineRow] {
        var hidden = Set<String>()
        if !showsFoldedWork {
            for row in rows {
                if case .fold(_, _, let folded) = row.kind {
                    hidden.formUnion(folded)
                }
            }
        }
        if hidesErrorNotices {
            for row in rows {
                if case .notice(.error, _, _) = row.kind {
                    hidden.insert(row.id)
                }
            }
        }
        guard !hidden.isEmpty else { return rows }
        return rows.filter { !hidden.contains($0.id) }
    }

    @ViewBuilder
    private func rowView(_ row: ChatTimelineRow) -> some View {
        switch row.kind {
        case .user(let text, let images, let delivery):
            // A second learner row can't start a turn (grouping prevents it),
            // but render it rather than drop it.
            ChatUserBubble(text: text, imageDataURIs: images, isPending: delivery == .pending)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .answer:
            if let buffer = model.buffer(for: row.id) {
                ChatAnswerRow(
                    rowID: row.id,
                    buffer: buffer,
                    isStreaming: row.id == streamingRowID
                )
            }
        case .work(let summary, let entries, let isLive, _):
            ChatWorkRow(summary: summary, entries: entries, isLive: isLive, startsExpanded: turn.hasFold)
        case .question(let prompt, let options, _, _, _, _, _):
            let rowID = row.id
            ChatQuestionRow(
                text: promptAlreadyShown(prompt, before: row.id) ? nil : prompt,
                options: options,
                isEnabled: row.id == answerableQuestionRowID,
                onSelect: { option in onChoose(option, rowID) }
            )
            .padding(.top, 4)
        case .plan(_, _, let plan, let invalidReason, let markdown, let isStreaming):
            ChatPlanRow(
                rowID: row.id,
                plan: plan,
                markdown: markdown,
                invalidReason: invalidReason,
                isStreaming: isStreaming
            )
        case .notice(let tone, let title, let message):
            ChatNoticeRow(tone: tone, title: title, message: message)
        case .fold(let label, _, let folded):
            ChatFoldRow(
                label: label,
                isExpanded: showsFoldedWork,
                isInteractive: !folded.isEmpty
            ) {
                withAnimation(.snappy(duration: 0.28)) {
                    showsFoldedWork.toggle()
                }
            }
        }
    }
}

/// Debug overlay that hatches the live turn's reserved space. Harness only.
struct ChatReserveGuide: View {
    let height: CGFloat

    var body: some View {
        if height > 1 {
            ZStack {
                Canvas { context, size in
                    let spacing: CGFloat = 12
                    var path = Path()
                    var x: CGFloat = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += spacing
                    }
                    context.stroke(path, with: .color(.blue.opacity(0.14)), lineWidth: 5)
                }
                if height > 34 {
                    Text("reserved · \(Int(height.rounded())) pt")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
