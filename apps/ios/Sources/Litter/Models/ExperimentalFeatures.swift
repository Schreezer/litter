import Foundation
import Observation

enum LitterFeature: String, CaseIterable, Identifiable {
    case realtimeVoice = "realtime_voice"
    case appleWatch = "apple_watch"
    case thinkingMinigame = "thinking_minigame"
    case terminal = "terminal"
    case classicCourseChat = "classic_course_chat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtimeVoice: return "Realtime"
        case .appleWatch: return "Apple Watch"
        case .thinkingMinigame: return "Thinking minigame"
        case .terminal: return "Terminal"
        case .classicCourseChat: return "Classic course chat"
        }
    }

    var description: String {
        switch self {
        case .realtimeVoice: return "Show the realtime voice launcher on the home screen."
        case .appleWatch: return "Push server, task, and approval state to a paired Apple Watch. Requires the Learnfold watch app to be installed."
        case .thinkingMinigame: return "Tap the Thinking shimmer while the assistant generates to play a tiny generated minigame."
        case .terminal: return "Show the local and remote terminal launcher on the home screen."
        case .classicCourseChat: return "Use the previous course chat transcript instead of the new shared timeline. Reopen the chat after switching."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .realtimeVoice: return true
        case .thinkingMinigame: return false
        case .terminal: return false
        case .classicCourseChat: return false
        case .appleWatch:
            // Default on now that the watch app is embedded again. The bridge
            // still no-ops when WatchConnectivity is unavailable.
            return true
        }
    }
}

@MainActor
@Observable
final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()

    @ObservationIgnored private let key = "litter.experimentalFeatures"
    private var overrides: [String: Bool]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private func persistOverrides() {
        UserDefaults.standard.set(overrides, forKey: key)
    }

    func isEnabled(_ feature: LitterFeature) -> Bool {
        overrides[feature.rawValue] ?? feature.defaultEnabled
    }

    func setEnabled(_ feature: LitterFeature, _ value: Bool) {
        var map = overrides
        if value == feature.defaultEnabled {
            map.removeValue(forKey: feature.rawValue)
        } else {
            map[feature.rawValue] = value
        }
        overrides = map
        persistOverrides()
    }

}
