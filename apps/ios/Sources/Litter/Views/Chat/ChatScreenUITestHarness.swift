#if DEBUG
import SwiftUI

/// Shows `ChatScreen` driven by `FixtureChatSource`, with no server or
/// provider behind it.
///
/// Launch arguments:
/// - `--chat-screen-harness` enables the harness. It deliberately avoids the
///   `--ui-test-` prefix, which the strict checkpoint parser claims.
/// - `--chat-scenario <happy|interrupt|failure|reconnect|brief>` picks the script.
/// - `--chat-history` starts with one settled exchange.
/// - `--chat-autosend` types a message and sends it after a second.
/// - `--chat-draft <text>` replaces the auto-sent message.
/// - `--chat-reserve-guide` hatches the live turn's reserved space.
/// - `--chat-debug-metrics` prints viewport and scroll numbers.
/// - `--chat-time-scale <number>` slows down (>1) or speeds up the script.
/// - `--chat-staging-delay <seconds>` holds a sent message in the local
///   preview before the source stages it, like a hosted agent.
struct ChatScreenUITestHarness: View {
    static let argument = "--chat-screen-harness"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static let autoSendDraft = "It picks up electrical spikes from neurons? Hard because the brain is noisy and soft."

    @State private var model: ChatScreenModel
    private let showsReserveGuide: Bool
    private let showsDebugMetrics: Bool
    private let autoSend: Bool
    private let draft: String

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(after flag: String) -> String? {
            if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            return arguments
                .first { $0.hasPrefix(flag + "=") }
                .map { String($0.dropFirst(flag.count + 1)) }
        }

        let scenario = value(after: "--chat-scenario")
            .flatMap(FixtureChatSource.Scenario.init(rawValue:)) ?? .happy
        let timeScale = value(after: "--chat-time-scale").flatMap(Double.init) ?? 1
        let source = FixtureChatSource(
            scenario: scenario,
            timeScale: timeScale,
            stagingDelay: value(after: "--chat-staging-delay").flatMap(Double.init) ?? 0,
            initialRows: arguments.contains("--chat-history") ? FixtureChatSource.historyRows : []
        )
        let model = ChatScreenModel(source: source)
        // The interrupt scenario stops through the same path as the button.
        source.onAutoStop = { [weak model] in model?.stop() }
        _model = State(initialValue: model)
        showsReserveGuide = arguments.contains("--chat-reserve-guide")
        showsDebugMetrics = arguments.contains("--chat-debug-metrics")
        autoSend = arguments.contains("--chat-autosend")
        draft = value(after: "--chat-draft") ?? Self.autoSendDraft
    }

    var body: some View {
        NavigationStack {
            ChatScreen(
                model: model,
                showsReserveGuide: showsReserveGuide,
                showsDebugMetrics: showsDebugMetrics,
                exposesStateProbe: true,
                autoSend: autoSend ? (draft, .seconds(3.5)) : nil
            )
            .navigationTitle("New Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {} label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                        )
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("chat-harness-hide-keyboard")
                }
            }
        }
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}
#endif
