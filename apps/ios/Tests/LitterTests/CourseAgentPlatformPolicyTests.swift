import XCTest
@testable import Litter

final class CourseAgentPlatformPolicyTests: XCTestCase {
    func testDirectDistributionMacPrefersInstalledCodexOverHostedAndApple() {
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(
                in: allAvailableProviders,
                prefersInstalledMacCodex: true
            ),
            CourseAgentProvider.codex
        )
    }

    func testIPhoneKeepsHostedDefaultAndAppleFallbackOrder() {
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(
                in: allAvailableProviders,
                prefersInstalledMacCodex: false
            ),
            CourseAgentProvider.hosted
        )
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(
                in: allAvailableProviders.filter { $0.id != CourseAgentProvider.hosted },
                prefersInstalledMacCodex: false
            ),
            CourseAgentProvider.applePrivateCloud
        )
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(
                in: allAvailableProviders.filter {
                    $0.id != CourseAgentProvider.hosted && $0.id != CourseAgentProvider.applePrivateCloud
                },
                prefersInstalledMacCodex: false
            ),
            CourseAgentProvider.appleOnDevice
        )
    }

    func testMacDefaultKeepsCodexSetupVisibleWhenStartupNeedsRecovery() {
        let options = [
            CourseAgentOption(id: CourseAgentProvider.codex, title: "Mac Codex", available: false),
            CourseAgentOption(id: CourseAgentProvider.hosted, title: "Hosted", available: true),
        ]
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(in: options, prefersInstalledMacCodex: true),
            CourseAgentProvider.codex
        )
        XCTAssertEqual(
            CourseAgentProvider.preferredDefault(in: options, prefersInstalledMacCodex: false),
            CourseAgentProvider.hosted
        )
    }

    func testSavedHostedSelectionRemainsExplicitOnMac() {
        let selection = CourseAgentSetupSelectionPolicy.initialSelection(
            savedAgentID: CourseAgentProvider.hosted,
            options: allAvailableProviders,
            preferredAgentID: CourseAgentProvider.codex,
            preservesUnavailableSavedSelection: true
        )
        XCTAssertEqual(selection.agentID, CourseAgentProvider.hosted)
        XCTAssertFalse(selection.isAutomatic)
        XCTAssertEqual(
            CourseAgentSetupSelectionPolicy.reconciledSelection(
                currentAgentID: selection.agentID,
                automaticAgentIDBeforeRefresh: nil,
                hasExplicitUserSelection: false,
                preferredAgentID: CourseAgentProvider.codex
            ),
            CourseAgentProvider.hosted
        )
    }

    func testUnavailableSavedMacCodexRemainsSelectedForRecovery() {
        let options = [
            CourseAgentOption(id: CourseAgentProvider.codex, title: "Mac Codex", available: false),
            CourseAgentOption(id: CourseAgentProvider.hosted, title: "Hosted", available: true),
        ]
        let macSelection = CourseAgentSetupSelectionPolicy.initialSelection(
            savedAgentID: CourseAgentProvider.codex,
            options: options,
            preferredAgentID: CourseAgentProvider.hosted,
            preservesUnavailableSavedSelection: true
        )
        XCTAssertEqual(macSelection.agentID, CourseAgentProvider.codex)
        XCTAssertFalse(macSelection.isAutomatic)

        let iPhoneSelection = CourseAgentSetupSelectionPolicy.initialSelection(
            savedAgentID: CourseAgentProvider.codex,
            options: options,
            preferredAgentID: CourseAgentProvider.hosted,
            preservesUnavailableSavedSelection: false
        )
        XCTAssertEqual(iPhoneSelection.agentID, CourseAgentProvider.hosted)
        XCTAssertTrue(iPhoneSelection.isAutomatic)
    }

    func testBackAndForwardRestoreFullReadingPath() {
        var history = CourseNavigationHistory<String>()
        let readingPath = ["course", "lesson"]
        history.record(path: readingPath)
        XCTAssertEqual(history.back(), [])
        history.record(path: [])
        XCTAssertEqual(history.forward(), readingPath)
        history.record(path: readingPath)
        XCTAssertEqual(history.back(), [])
        history.record(path: [])
        XCTAssertNil(history.back())
    }

    func testOpeningAnotherCourseAfterBackDiscardsForwardHistory() {
        var history = CourseNavigationHistory<String>()
        history.record(path: ["first-course", "lesson"])
        XCTAssertEqual(history.back(), [])
        history.record(path: [])
        history.record(path: ["second-course"])
        XCTAssertNil(history.forward())
        XCTAssertEqual(history.back(), [])
    }

    private var allAvailableProviders: [CourseAgentOption] {
        [
            CourseAgentOption(id: CourseAgentProvider.hosted, title: "Hosted", available: true),
            CourseAgentOption(id: CourseAgentProvider.applePrivateCloud, title: "Private Cloud Compute", available: true),
            CourseAgentOption(id: CourseAgentProvider.appleOnDevice, title: "On-Device", available: true),
            CourseAgentOption(id: CourseAgentProvider.codex, title: "Codex", available: true),
        ]
    }
}
