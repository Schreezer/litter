import StoreKit
import SwiftUI

/// Pure copy for the paywall, kept out of the view so it can be tested.
enum SubscriptionPaywallCopy {
    static func headline(for required: LearnfoldPlan) -> String {
        switch required {
        case .plus: "Plus unlocks your own runtime"
        case .hosted: "Hosted needs a Learnfold Hosted plan"
        }
    }

    static func reason(for required: LearnfoldPlan) -> String {
        switch required {
        case .plus:
            "Using Codex, Hermes, or your own API key and endpoint with Learnfold takes a Plus or Hosted plan. Apple's on-device and Private Cloud Compute agents stay free."
        case .hosted:
            "Learnfold's Hosted agent runs in the cloud and takes a Hosted plan. Apple's on-device and Private Cloud Compute agents stay free."
        }
    }

    /// App Review requires the renewal terms near the purchase buttons.
    static let renewalTerms = "Payment is charged to your Apple ID account at confirmation of purchase. The subscription renews automatically each month unless you cancel at least 24 hours before the end of the current period. Your account is charged for renewal within 24 hours before the end of the period. You can manage or cancel your subscription any time in your Apple ID account settings after purchase. Plus and Hosted are in one subscription group, so changing plans replaces your current one."

    static func priceLine(for offer: PlanOffer) -> String {
        offer.periodDescription.isEmpty ? offer.displayPrice : "\(offer.displayPrice) / \(offer.periodDescription)"
    }
}

struct SubscriptionPaywallView: View {
    let requiredPlan: LearnfoldPlan?

    @Environment(\.dismiss) private var dismiss
    @State private var subscriptions = SubscriptionStore.shared
    @State private var showsManageSubscriptions = false

    init(requiredPlan: LearnfoldPlan? = nil) {
        self.requiredPlan = requiredPlan
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LitterTheme.backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        ForEach(LearnfoldPlan.allCases.reversed()) { plan in
                            planCard(plan)
                        }
                        if let message = subscriptions.actionError {
                            statusText(message, color: .red, identifier: "paywall.error")
                        } else if let notice = subscriptions.notice {
                            statusText(notice, color: LitterTheme.accent, identifier: "paywall.notice")
                        }
                        footerActions
                        Text(SubscriptionPaywallCopy.renewalTerms)
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("paywall.terms")
                        legalLinks
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Choose a plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Not now") { dismiss() }
                        .foregroundColor(LitterTheme.accent)
                        .accessibilityIdentifier("paywall.dismiss")
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        .task {
            await subscriptions.refreshEntitlements()
            if subscriptions.offers.isEmpty { await subscriptions.loadOffers() }
        }
        // Self-heals a paywall shown before entitlements finished loading, and
        // closes after a purchase or restore covers what was requested.
        .onChange(of: subscriptions.activePlan) { _, active in
            if let active, active.includes(requiredPlan ?? .plus) { dismiss() }
        }
        .accessibilityIdentifier("paywall.root")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(requiredPlan.map(SubscriptionPaywallCopy.headline) ?? "Learnfold plans")
                .litterFont(.title3, weight: .bold)
                .foregroundColor(LitterTheme.textPrimary)
                .accessibilityIdentifier("paywall.headline")
            Text(requiredPlan.map(SubscriptionPaywallCopy.reason) ?? "Pick the plan that matches how you want to run your course agent.")
                .litterFont(.subheadline)
                .foregroundColor(LitterTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planCard(_ plan: LearnfoldPlan) -> some View {
        let offer = subscriptions.offer(for: plan)
        let isCurrent = subscriptions.activePlan == plan
        let isRecommended = requiredPlan.map { plan == $0 } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(offer?.displayName ?? plan.title)
                    .litterFont(.headline, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer(minLength: 8)
                if isCurrent {
                    Text("Current plan")
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                } else if isRecommended {
                    Text("Needed for this")
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            Text(plan.summary)
                .litterFont(.footnote)
                .foregroundColor(LitterTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let offer {
                Text(SubscriptionPaywallCopy.priceLine(for: offer))
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundColor(LitterTheme.textPrimary)
                    .accessibilityIdentifier("paywall.price.\(plan.rawValue)")
            } else if subscriptions.isLoadingOffers {
                ProgressView().tint(LitterTheme.accent)
            }
            Button {
                Task { await subscriptions.purchase(plan) }
            } label: {
                Text(isCurrent ? "Subscribed" : "Subscribe")
                    .litterFont(.subheadline, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(.black)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LitterTheme.accent.opacity(offer == nil || isCurrent ? 0.35 : 1))
                    )
            }
            .buttonStyle(.plain)
            .disabled(offer == nil || isCurrent || subscriptions.isWorking)
            .accessibilityIdentifier("paywall.subscribe.\(plan.rawValue)")
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LitterTheme.surface.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isRecommended ? LitterTheme.accent : Color.clear, lineWidth: 1.5)
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.plan.\(plan.rawValue)")
    }

    @ViewBuilder
    private var footerActions: some View {
        if let error = subscriptions.offersError {
            VStack(alignment: .leading, spacing: 8) {
                statusText(error, color: LitterTheme.textSecondary, identifier: "paywall.offers-error")
                Button("Try again") { Task { await subscriptions.loadOffers() } }
                    .foregroundColor(LitterTheme.accent)
                    .accessibilityIdentifier("paywall.retry")
            }
        }
        HStack(spacing: 20) {
            Button("Restore Purchases") { Task { await subscriptions.restore() } }
                .disabled(subscriptions.isWorking)
                .accessibilityIdentifier("paywall.restore")
            Button("Manage Subscription") { showsManageSubscriptions = true }
                .accessibilityIdentifier("paywall.manage")
        }
        .litterFont(.footnote, weight: .semibold)
        .foregroundColor(LitterTheme.accent)
    }

    private var legalLinks: some View {
        HStack(spacing: 20) {
            Link("Terms of Use", destination: SubscriptionLinks.terms)
                .accessibilityIdentifier("paywall.terms-link")
            Link("Privacy Policy", destination: SubscriptionLinks.privacy)
                .accessibilityIdentifier("paywall.privacy-link")
        }
        .litterFont(.footnote)
        .foregroundColor(LitterTheme.accent)
    }

    private func statusText(_ text: String, color: Color, identifier: String) -> some View {
        Text(text)
            .litterFont(.footnote)
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

/// Settings > Plan: shows the current plan and how to change or cancel it.
struct PlanSettingsView: View {
    @State private var subscriptions = SubscriptionStore.shared
    @State private var showsPaywall = false
    @State private var showsManageSubscriptions = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subscriptions.activePlan?.title ?? "Free")
                        .litterFont(.headline, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)
                        .accessibilityIdentifier("plan.current")
                    Text(detail)
                        .litterFont(.footnote)
                        .foregroundColor(LitterTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            } header: {
                Text("Current plan").foregroundColor(LitterTheme.textSecondary)
            }
            Section {
                Button(subscriptions.activePlan == nil ? "See plans" : "Change plan") { showsPaywall = true }
                    .accessibilityIdentifier("plan.see-plans")
                Button("Manage Subscription") { showsManageSubscriptions = true }
                    .accessibilityIdentifier("plan.manage")
                Button("Restore Purchases") { Task { await subscriptions.restore() } }
                    .disabled(subscriptions.isWorking)
                    .accessibilityIdentifier("plan.restore")
                Link("Terms of Use", destination: SubscriptionLinks.terms)
                Link("Privacy Policy", destination: SubscriptionLinks.privacy)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = subscriptions.actionError ?? subscriptions.notice {
                        Text(message)
                    }
                    Text("Apple's on-device and Private Cloud Compute agents are free on every plan.")
                }
            }
            .foregroundColor(LitterTheme.accent)
            .listRowBackground(LitterTheme.surface.opacity(0.6))
        }
        .scrollContentBackground(.hidden)
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPaywall) { SubscriptionPaywallView() }
        .manageSubscriptionsSheet(isPresented: $showsManageSubscriptions)
        .task { await subscriptions.refreshEntitlements() }
    }

    private var detail: String {
        guard let entitlement = subscriptions.activeEntitlement else {
            return "You're on the free plan. Apple's on-device agents are included."
        }
        guard let date = entitlement.expirationDate else { return "Active." }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        if entitlement.willAutoRenew == false { return "Active until \(formatted). It won't renew." }
        return "Renews \(formatted)."
    }
}
