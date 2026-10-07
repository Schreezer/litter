import Foundation

/// The two paid plans. They share one App Store subscription group, so a
/// subscriber holds at most one of them and can move between them freely.
enum LearnfoldPlan: String, CaseIterable, Identifiable, Sendable {
    /// Bring-your-own runtime: Codex, Hermes, custom provider endpoints.
    case plus
    /// Learnfold's own Hosted agent. Includes everything in Plus.
    case hosted

    static let plusProductID = "com.chirag.learnfold.plus.monthly"
    static let hostedProductID = "com.chirag.learnfold.hosted.monthly"

    var id: String { rawValue }

    var productID: String {
        switch self {
        case .plus: Self.plusProductID
        case .hosted: Self.hostedProductID
        }
    }

    var title: String {
        switch self {
        case .plus: "Learnfold Plus"
        case .hosted: "Learnfold Hosted"
        }
    }

    var summary: String {
        switch self {
        case .plus:
            "Bring your own runtime: Codex, Hermes, or your own API key and endpoint."
        case .hosted:
            "Learnfold's Hosted agent. Nothing to set up. Includes everything in Plus."
        }
    }

    static var productIDs: [String] { allCases.map(\.productID) }

    static func plan(forProductID productID: String) -> LearnfoldPlan? {
        allCases.first { $0.productID == productID }
    }

    /// Hosted is the higher tier and includes Plus.
    func includes(_ other: LearnfoldPlan) -> Bool {
        self == other || (self == .hosted && other == .plus)
    }

    /// The best of several held plans, if any.
    static func highest(of plans: some Sequence<LearnfoldPlan>) -> LearnfoldPlan? {
        plans.contains(.hosted) ? .hosted : plans.contains(.plus) ? .plus : nil
    }
}

/// Which agents need which plan. This is a thin client-side gate. For Hosted
/// the Worker is authoritative (it verifies the signed transaction); Plus
/// covers runtimes that never touch Learnfold servers, so it can only be
/// enforced here.
enum AgentAccessPolicy {
    /// `nil` means the agent is free. Apple's on-device and Private Cloud
    /// Compute models stay free; every non-Hosted app-server runtime is BYO.
    static func requiredPlan(forRuntimeID runtimeID: String) -> LearnfoldPlan? {
        if runtimeID == CourseAgentProvider.hosted { return .hosted }
        if CourseAgentProvider.isApple(runtimeID) { return nil }
        return .plus
    }
}

/// What the course store needs from the subscription layer.
@MainActor
protocol EntitlementProviding: AnyObject {
    func hasAccess(to plan: LearnfoldPlan) -> Bool
    /// The freshest StoreKit signed transaction (JWS) for a Hosted
    /// subscription, if the user holds one. The Worker verifies it.
    func hostedSignedTransaction() async -> String?
}

struct PaywallRequest: Identifiable, Equatable {
    let id = UUID()
    /// The plan the learner needs for what they just tried to do.
    let requiredPlan: LearnfoldPlan
}

/// Decides whether the paid-tier gate applies to this build.
enum SubscriptionConfiguration {
    static let environmentKey = "LEARNFOLD_SUBSCRIPTIONS_ENFORCED"
    static let bundleKey = "LearnfoldSubscriptionsEnforced"

    /// The environment variable wins (UI tests, local StoreKit testing). The
    /// Info.plist key is set per build configuration in project.yml. The
    /// notarized direct-distribution Mac build is outside the App Store.
    static func isEnforced(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        isDirectDistMac: Bool = LitterPlatform.isDirectDistMac
    ) -> Bool {
        if isDirectDistMac { return false }
        if let override = environment[environmentKey] { return parse(override) }
        if let flag = bundle.object(forInfoDictionaryKey: bundleKey) as? Bool { return flag }
        if let text = bundle.object(forInfoDictionaryKey: bundleKey) as? String { return parse(text) }
        return false
    }

    private static func parse(_ text: String) -> Bool {
        ["1", "yes", "true"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

enum SubscriptionLinks {
    static let terms = URL(string: "https://learnfold.pages.dev/terms")!
    static let privacy = URL(string: "https://learnfold.pages.dev/privacy")!
    static let appleSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let support = URL(string: "mailto:chirag@fitsnap.fun")!
}
