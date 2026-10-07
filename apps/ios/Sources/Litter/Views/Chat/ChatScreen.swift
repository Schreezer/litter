import Combine
import SwiftUI

/// The chat screen: a turn-grouped timeline over a composer.
///
/// Scroll policy, in full:
/// - On send, the new turn is scrolled so its top meets the viewport top, and
///   it reserves the visible viewport height. The previous turn gives up its
///   reserve in the same transaction.
/// - The reply streams into the reserve. Content size doesn't change while
///   reserve > 0, so nothing scrolls.
/// - Once the reply outgrows the reserve, and only if the learner hasn't
///   dragged, the view follows the bottom.
/// - When the turn settles, its reserve stays until the next send.
/// - The keyboard leaves the newest turn where it is. Its reserve never
///   shrinks while it is live, so the keyboard opening doesn't pull content
///   out from under the reader; when the reader is at the turn's end, the
///   end rides up with the keyboard instead of going behind it.
struct ChatScreen: View {
    let model: ChatScreenModel
    var placeholder = "Message your course agent"
    /// Hatches the live turn's reserved space. Harness only.
    var showsReserveGuide = false
    /// Prints scroll metrics over the composer. Harness only.
    var showsDebugMetrics = false
    /// Exposes scroll state as an accessibility element for UI tests.
    /// Harness only: VoiceOver would otherwise read it to learners.
    var exposesStateProbe = false
    /// Types this draft and sends it after `delay`. Harness only.
    var autoSend: (draft: String, delay: Duration)?
    /// Content above the first turn (intro or context cards).
    var header: AnyView?
    /// Content at the end of the newest turn (plan approval, error cards).
    /// It sits inside the live turn's reserved space, so it appearing never
    /// moves the reader.
    var trailing: AnyView?
    /// Replaces the built-in composer (the course chat has its own, with
    /// attachments). Sends through it must go through the same source and
    /// call `ChatScreenModel.noteLocalSend`.
    var composer: AnyView?
    /// The host already shows the newest turn's failure (the course error
    /// card), so the turn's own error notice and failed-phase caption stay
    /// hidden instead of repeating it.
    var hidesNewestTurnErrors = false
    /// Sends a tapped option that isn't answering a pending request through
    /// the host (the course composer path, with its readiness guards and
    /// queueing). `nil` sends through the model's source.
    var sendOption: ((String) -> Bool)?
    /// Whether question options can be tapped at all, on top of the model's
    /// own rule. The course chat greys them out while the agent is not
    /// ready to take a message.
    var optionsEnabled = true

    @State private var draft = ""
    @State private var viewportHeight: CGFloat = 0
    @State private var liveContentHeight: CGFloat = 0
    /// The tallest the live turn has been. Its reserve never drops below
    /// this, so a fold collapsing can't shift the view.
    @State private var liveHeightFloor: CGFloat = 0
    /// The tallest viewport the live turn has reserved. SwiftUI applies the
    /// keyboard in several layout steps (the frame shrinks, then grows back
    /// as the bottom inset catches up). Content that shrinks in between no
    /// longer reaches the offset, so the scroll view clamps it and the turn
    /// drops below the composer. The reserve only grows until the next turn
    /// takes over.
    @State private var reserveFloor: CGFloat = 0
    @State private var userDragged = false
    @State private var isNearBottom = true
    /// Set by a send until the new turn has been laid out, so the insertion
    /// itself is bottom-pinned even if the phase hasn't moved yet.
    @State private var sendingTurnID: String?
    /// The model this screen last started, so a swapped-in model can
    /// release the old one.
    @State private var attachedModel: ChatScreenModel?
    /// A just-sent turn to scroll to because the reader was scrolled up.
    /// A turn's `viewID`.
    @State private var jumpTargetID: String?
    /// The live turn's `viewID`. A staged message keeps its preview's, which
    /// is how `adoptLiveTurn` tells it from a new turn.
    @State private var liveViewID: String?
    @State private var debugOffset: CGFloat = 0
    @State private var debugContentHeight: CGFloat = 0
    @State private var debugGeometry = ""
    @State private var debugStackWidth: CGFloat = 0
    /// Width the live turn's height floor was measured at.
    @State private var floorWidth: CGFloat = 0
    /// A send happened while the reader was scrolled up; jump to the new
    /// turn once it exists.
    @State private var jumpOnNextTurn = false
    /// Text editing just began, so the keyboard is about to open.
    @State private var keyboardOpening = false
    @State private var keyboardSettleTask: Task<Void, Never>?
    @Namespace private var bubbleNamespace
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let header {
                        header
                            .padding(.horizontal, 16)
                            .id("chat-header")
                    }
                    ForEach(model.turns, id: \.viewID) { turn in
                        turnSection(turn)
                            .padding(.horizontal, 16)
                            .id(turn.viewID)
                    }
                    if model.turns.isEmpty, let trailing {
                        trailing
                            .padding(.horizontal, 16)
                            .id("chat-trailing")
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if showsDebugMetrics { debugStackWidth = width }
                    // Text rewraps at a new width, so the tallest height the
                    // live turn reached no longer applies.
                    if abs(width - floorWidth) > 0.5 {
                        floorWidth = width
                        liveHeightFloor = liveContentHeight
                        reserveFloor = viewportHeight
                    }
                }
                // Bottom-pinning keeps the distance from the bottom, so it
                // only lands the new turn when the reader was already there.
                // From further up, jump to it explicitly.
                .onChange(of: jumpTargetID) { _, target in
                    guard let target else { return }
                    jumpTargetID = nil
                    withTransaction(sendTransaction) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        // The whole scroll policy. Growth is pinned to the bottom while a
        // turn is sending or following, and to the top otherwise:
        // - On send, the new turn (one viewport tall) is appended in an
        //   animated transaction; bottom-pinning carries its top to the
        //   viewport top, while the previous turn gives up its reserve in the
        //   same transaction.
        // - While reserve > 0 the content size doesn't change, so nothing
        //   moves. Once the reply outgrows the reserve the content grows and,
        //   still bottom-pinned, the view follows it.
        // - A drag, or the turn settling, switches to top-pinning, so growth
        //   (a late row, an expanded fold) never pulls the reader along.
        // - While the keyboard opens, a reader at the end of the newest turn
        //   stays there.
        .defaultScrollAnchor(pinsToBottom ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        // The visible height between the navigation bar and the composer:
        // the scroll view's bounds minus the bar insets. (`containerSize`
        // and a GeometryProxy's size are already inset on some layouts, so
        // derive it from `visibleRect`, which always spans the full bounds.)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.visibleRect.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        } action: { _, height in
            viewportHeight = max(0, height)
            reserveFloor = max(reserveFloor, viewportHeight)
        }
        .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.contentOffset.y, height: geometry.contentSize.height)
        } action: { _, value in
            guard showsDebugMetrics else { return }
            debugOffset = value.width
            debugContentHeight = value.height
        }
        .onScrollGeometryChange(for: String.self) { geometry in
            "container \(Int(geometry.containerSize.height)) insets \(Int(geometry.contentInsets.top))/\(Int(geometry.contentInsets.bottom)) visible \(Int(geometry.visibleRect.height))"
        } action: { _, value in
            if showsDebugMetrics { debugGeometry = value }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY <= 24
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        .onScrollPhaseChange { _, newPhase in
            switch newPhase {
            case .tracking, .interacting:
                userDragged = true
                // A drag ends the send hand-off even if the new turn never
                // laid out (it can sit off screen in the lazy stack).
                sendingTurnID = nil
            case .idle:
                // Coming to rest at the bottom re-arms following.
                if isNearBottom { userDragged = false }
            case .decelerating, .animating:
                break
            @unknown default:
                break
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .top) {
            connectionBanner
        }
        .courseBottomBar {
            if let composer {
                composer
            } else {
                ChatComposer(
                    text: $draft,
                    placeholder: placeholder,
                    phase: model.phase,
                    canSend: model.canSend,
                    pendingBubbleID: model.nextPreviewViewID,
                    bubbleNamespace: bubbleNamespace,
                    isFocused: $composerFocused,
                    onSend: { send(draft) },
                    onStop: { model.stop() }
                )
            }
        }
        .onChange(of: model.sendGeneration) { _, _ in
            beginSendHandOff()
        }
        .onChange(of: model.liveTurnID) { _, turnID in
            guard let turnID else { return }
            adoptLiveTurn(turnID)
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            // Text sizes changed, so the floor measured before is stale.
            liveHeightFloor = liveContentHeight
            reserveFloor = viewportHeight
        }
        .onReceive(editingBegan) { _ in keyboardWillOpen() }
        // The runtime may have reconnected while the app was away; catch up
        // on anything the subscription missed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resync() }
        }
        .litterFontFamily(.system)
        .environment(\.textScale, 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-screen")
        .background(alignment: .topLeading) {
            if exposesStateProbe { debugProbe }
        }
        .overlay(alignment: .bottomLeading) {
            if showsDebugMetrics {
                Text("\(debugGeometry) w \(Int(debugStackWidth))\nvp \(Int(viewportHeight)) live \(Int(liveContentHeight)) floor \(Int(liveHeightFloor)) off \(Int(debugOffset)) cs \(Int(debugContentHeight)) drag \(userDragged ? 1 : 0) pin \(pinsToBottom ? "bottom" : "top")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .allowsHitTesting(false)
            }
        }
        // Keyed by the model, so handing the screen another thread's model
        // starts it and releases the previous one.
        .task(id: ObjectIdentifier(model)) {
            attach(model)
            guard let autoSend else { return }
            draft = autoSend.draft
            try? await Task.sleep(for: autoSend.delay)
            guard !Task.isCancelled else { return }
            send(draft)
        }
        .onDisappear {
            model.tearDown()
        }
    }

    // MARK: - Turns

    @ViewBuilder
    private func turnSection(_ turn: ChatTurn) -> some View {
        let isLive = turn.id == model.liveTurnID
        let isLast = turn.id == model.turns.last?.id
        TurnSection(
            turn: turn,
            livePhase: isLive ? (turn.isLocalPreview ? .queued : model.phase) : nil,
            progressLabel: isLive ? model.progressLabel : nil,
            streamingRowID: isLive ? model.streamingRowID : nil,
            answerableQuestionRowID: isLast && optionsEnabled ? model.answerableQuestionRowID : nil,
            minHeight: isLive ? reservedHeight : nil,
            showsReserveGuide: showsReserveGuide && isLive,
            bubbleNamespace: bubbleNamespace,
            model: model,
            onContentHeightChange: isLive ? { height in
                liveContentHeight = height
                liveHeightFloor = max(liveHeightFloor, height)
                if sendingTurnID == turn.id { sendingTurnID = nil }
            } : nil,
            onChoose: { option, rowID in choose(option, rowID: rowID) },
            hidesErrorNotices: isLast && hidesNewestTurnErrors,
            trailing: isLast ? trailing : nil
        )
        .equatable()
    }

    /// The live turn's minimum height: the visible viewport, or more if the
    /// turn has already been taller than that or reserved a taller viewport.
    private var reservedHeight: CGFloat? {
        guard viewportHeight > 0 else { return nil }
        return max(viewportHeight, liveHeightFloor, reserveFloor)
    }

    // MARK: - Lifecycle

    private func attach(_ model: ChatScreenModel) {
        // The course chat's first message creates its thread, so the model
        // is swapped mid-send. The new model carries the same pending turn,
        // so the send keeps its scroll state and hand-off.
        let continuesSend = attachedModel.map {
            $0 !== model && model.localPreviewText != nil && model.previewViewID == $0.previewViewID
        } ?? false
        if let attachedModel, attachedModel !== model {
            attachedModel.tearDown()
        }
        if let attachedModel, attachedModel !== model, !continuesSend {
            // Scroll state belongs to the previous thread.
            draft = ""
            userDragged = false
            liveContentHeight = 0
            liveHeightFloor = 0
            reserveFloor = viewportHeight
            sendingTurnID = nil
            jumpTargetID = nil
            liveViewID = nil
        }
        attachedModel = model
        model.turnInsertionAnimation = reduceMotion ? nil : .smooth(duration: 0.5)
        if model.localPreviewText != nil, !continuesSend {
            // The model arrived mid-send, so the send's hand-off carries
            // over.
            beginSendHandOff()
        }
        model.start()
    }

    // MARK: - Intents

    private func send(_ text: String) {
        withTransaction(sendTransaction) {
            guard model.send(text) else { return }
            draft = ""
        }
    }

    private func choose(_ option: String, rowID: String) {
        withTransaction(sendTransaction) {
            _ = model.choose(option: option, rowID: rowID, sendMessage: sendOption)
        }
    }

    /// A learner send started (here or in an injected composer). Pin growth
    /// to the bottom until the new turn has laid out.
    private func beginSendHandOff() {
        if !isNearBottom { jumpOnNextTurn = true }
        userDragged = false
        sendingTurnID = model.liveTurnID ?? ChatTurn.localPreviewID
    }

    /// A new turn owns the reserve: the old turn gives it up in the same
    /// transaction, and the new one scrolls to the top.
    private func adoptLiveTurn(_ turnID: String) {
        let viewID = model.turns.first(where: { $0.id == turnID })?.viewID ?? turnID
        if viewID == liveViewID {
            // The source staged the message shown as the preview. It is the
            // same view, so it keeps its reserve and nothing moves.
            if sendingTurnID != nil { sendingTurnID = turnID }
            return
        }
        liveViewID = viewID
        liveContentHeight = 0
        liveHeightFloor = 0
        reserveFloor = viewportHeight
        if sendingTurnID != nil || model.phase.isActive {
            sendingTurnID = turnID
        }
        if jumpOnNextTurn {
            jumpOnNextTurn = false
            jumpTargetID = viewID
        }
    }

    private var sendTransaction: Transaction {
        Transaction(animation: reduceMotion ? nil : .smooth(duration: 0.5))
    }

    /// The only follow rule: pin growth to the bottom while the just-sent
    /// turn is settling into place, while the live turn is active and the
    /// learner hasn't dragged, and while the keyboard opens under a reader
    /// at the end of the newest turn. With reserve > 0 bottom-pinning moves
    /// nothing, because the content size doesn't change.
    private var pinsToBottom: Bool {
        if sendingTurnID != nil { return true }
        // The keyboard opening keeps the end of the newest turn in view. A
        // turn with blank reserve below it stays put instead, since the
        // reserve absorbs the keyboard.
        if keyboardOpening, readsNewestTurnEnd { return true }
        return model.liveTurnID != nil && model.phase.isWorking && !userDragged
    }

    // MARK: - Keyboard

    /// Text editing began, so the keyboard is about to open. SwiftUI resizes
    /// the scroll view inside its own keyboard notification, so the anchor
    /// has to be set before that, and editing begins first.
    private func keyboardWillOpen() {
        keyboardOpening = true
        keyboardSettleTask?.cancel()
        keyboardSettleTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            keyboardOpening = false
        }
    }

    /// The reader sees the end of the newest turn: they are at the bottom
    /// and the turn fills its reserve, so no blank space sits below it.
    private var readsNewestTurnEnd: Bool {
        guard isNearBottom, model.liveTurnID != nil, let reservedHeight else { return false }
        return liveContentHeight >= reservedHeight - 1
    }

    // MARK: - Chrome

    @ViewBuilder
    private var connectionBanner: some View {
        if let presentation = ChatConnectionPresentation.make(model.connection) {
            Label(presentation.label, systemImage: presentation.systemImage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("chat-connection-banner")
        }
    }

    /// Exposes the scroll state to UI tests and `idb ui describe-all`.
    private var debugProbe: some View {
        let reserve = max(0, (reservedHeight ?? 0) - liveContentHeight)
        let following = pinsToBottom && viewportHeight > 0 && liveContentHeight > viewportHeight
        let value: String = "phase=\(model.phase.debugName) reserve=\(Int(reserve)) following=\(following) dragged=\(userDragged)"
        return Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Chat state")
            .accessibilityIdentifier("chat-state-probe")
            .accessibilityValue(value)
    }
}

/// Text editing beginning anywhere in the app. SwiftUI's `TextField` posts
/// this from its backing `UITextField` or `UITextView` before the keyboard
/// notifications.
@MainActor
private var editingBegan: AnyPublisher<Notification, Never> {
    let center = NotificationCenter.default
    return center.publisher(for: UITextField.textDidBeginEditingNotification)
        .merge(with: center.publisher(for: UITextView.textDidBeginEditingNotification))
        .eraseToAnyPublisher()
}
