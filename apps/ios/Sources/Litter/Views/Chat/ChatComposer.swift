import SwiftUI

/// The chat's message field. Styled like the course chat composer: a white
/// card on the grouped background with a round send/stop button.
struct ChatComposer: View {
    @Binding var text: String
    let placeholder: String
    let phase: ChatTurnPhase
    let canSend: Bool
    /// Identity the next learner bubble will fly in with.
    let pendingBubbleID: String
    let bubbleNamespace: Namespace.ID
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsStop: Bool {
        phase.isActive && phase != .awaitingInput
    }

    private var buttonDisabled: Bool {
        if phase == .stopping { return true }
        if showsStop { return !phase.canStop }
        return !(canSend && hasText)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                placeholder,
                text: $text,
                prompt: Text(placeholder).foregroundColor(Color(uiColor: .secondaryLabel)),
                axis: .vertical
            )
            .font(.body)
            .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 5))
            .focused(isFocused)
            .textFieldStyle(.plain)
            .frame(minHeight: 24, alignment: .topLeading)
            .padding(.leading, 10)
            .padding(.vertical, 10)
            .overlay(alignment: .topLeading) {
                // An invisible copy of the draft. On send it leaves as the new
                // bubble arrives with the same id, so the bubble appears to
                // lift out of the field.
                if hasText {
                    Text(text)
                        .font(.body)
                        .lineLimit(1...5)
                        .padding(.leading, 10)
                        .padding(.vertical, 10)
                        .matchedGeometryEffect(id: pendingBubbleID, in: bubbleNamespace, properties: .position, isSource: true)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onSubmit(onSendIfPossible)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier("chat-composer")

            Button(action: showsStop ? onStop : onSend) {
                Group {
                    if phase == .stopping {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .foregroundStyle(buttonDisabled && phase != .stopping ? Color.secondary : .white)
                .frame(width: 36, height: 36)
                .background(
                    buttonDisabled && phase != .stopping ? Color.primary.opacity(0.08) : Color.blue,
                    in: Circle()
                )
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(buttonDisabled)
            .accessibilityLabel(phase == .stopping ? "Stopping" : (showsStop ? "Stop" : "Send message"))
            .accessibilityIdentifier(showsStop || phase == .stopping ? "chat-stop" : "chat-send")
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            colorScheme == .dark ? Color(white: 0.13) : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer-container")
    }

    private func onSendIfPossible() {
        guard !showsStop, canSend, hasText else { return }
        onSend()
    }
}
