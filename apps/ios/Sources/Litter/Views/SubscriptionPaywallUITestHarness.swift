#if DEBUG
import SwiftUI

/// Hosts the real paywall on a bare screen so an XCUITest can verify it with
/// the local StoreKit configuration, without driving the whole course flow.
struct SubscriptionPaywallUITestHarness: View {
    static let argument = "--ui-test-subscription-paywall"
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LEARNFOLD_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.arguments.contains(argument)
    }

    @State private var showsPaywall = true

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .sheet(isPresented: $showsPaywall) {
                SubscriptionPaywallView(requiredPlan: .hosted)
            }
            .onAppear { SubscriptionStore.shared.start() }
    }
}
#endif
