import XCTest
@testable import Litter

#if DEBUG
final class ServerLifecycleCheckpointParserTests: XCTestCase {
    private let enabledEnvironment = ["LEARNFOLD_UI_TESTING": "1"]

    func testEveryExactRouteAndAdjacentStatePairIsAccepted() {
        for scenario in ServerLifecycleCheckpointScenario.allCases {
            XCTAssertEqual(
                parse([scenario.route, scenario.rawValue]),
                .scenario(scenario),
                "Rejected exact checkpoint pair for \(scenario.rawValue)"
            )
        }
    }

    func testRecognizedRouteIsRejectedWithoutTestingEnvironment() {
        XCTAssertEqual(
            parse(
                ["--ui-test-server-lifecycle", "server-lifecycle-connected"],
                environment: [:]
            ),
            .invalid(.testingEnvironmentRequired)
        )
    }

    func testRouteWithoutAdjacentStateIsRejected() {
        XCTAssertEqual(
            parse(["--ui-test-server-lifecycle"]),
            .invalid(.missingState)
        )
    }

    func testUnknownAdjacentStateIsRejected() {
        XCTAssertEqual(
            parse(["--ui-test-server-lifecycle", "server-lifecycle-unknown"]),
            .invalid(.unknownState)
        )
    }

    func testKnownStateWithoutRouteIsRejected() {
        XCTAssertEqual(
            parse(["ssh-login-empty"]),
            .invalid(.missingRoute)
        )
    }

    func testStateFromAnotherRouteIsRejected() {
        XCTAssertEqual(
            parse(["--ui-test-server-lifecycle", "ssh-login-empty"]),
            .invalid(.routeStateMismatch)
        )
    }

    func testDuplicateIdenticalRouteIsRejected() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
            ]),
            .invalid(.duplicateRoute)
        )
    }

    func testMultipleDifferentRoutesAreRejected() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
                "--ui-test-ssh-login", "ssh-login-empty",
            ]),
            .invalid(.multipleRoutes)
        )
    }

    func testMalformedThenValidDuplicateRouteIsRejectedFailClosed() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle", "not-a-state",
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
            ]),
            .invalid(.duplicateRoute)
        )
    }

    func testExtraCheckpointStateIsRejectedEvenWhenAdjacentPairIsValid() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
                "ssh-login-empty",
            ]),
            .invalid(.multipleStates)
        )
    }

    func testExtraMalformedCheckpointStateIsRejectedEvenWhenAdjacentPairIsValid() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle", "server-lifecycle-connected",
                "ssh-login-not-a-state",
            ]),
            .invalid(.multipleStates)
        )
    }

    func testUnrelatedLaunchArgumentsLeaveHarnessDisabled() {
        XCTAssertEqual(
            parse(["--some-unrelated-argument"]),
            .disabled
        )
    }

    private func parse(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> ServerLifecycleCheckpointLaunchConfiguration {
        ServerLifecycleCheckpointParser.parse(
            arguments: ["Litter"] + arguments,
            environment: environment ?? enabledEnvironment
        )
    }
}

@MainActor
final class StrictUITestLaunchConfigurationTests: XCTestCase {
    private let enabledEnvironment = ["LEARNFOLD_UI_TESTING": "1"]

    func testEveryRegisteredScenarioProducesItsTypedFixture() {
        for scenario in CourseRecoveryCheckpointUITestScenario.allCases {
            XCTAssertEqual(
                parse([
                    CourseRecoveryCheckpointUITestScenario.launchArgument,
                    scenario.rawValue,
                ]),
                .valid(.courseRecovery(scenario))
            )
        }
        for scenario in ServerLifecycleCheckpointScenario.allCases {
            XCTAssertEqual(
                parse([scenario.route, scenario.rawValue]),
                .valid(.serverLifecycle(scenario))
            )
        }
        for scenario in ProviderSettingsSourceCheckpointScenario.allCases {
            XCTAssertEqual(
                parse([
                    ProviderSettingsSourceCheckpointScenario.launchArgument,
                    scenario.rawValue,
                ]),
                .valid(.providerSettingsSource(scenario))
            )
        }
        for scenario in CourseGenerationCheckpointScenario.allCases {
            XCTAssertEqual(
                parse([scenario.route, scenario.rawValue]),
                .valid(.courseGeneration(scenario))
            )
            XCTAssertEqual(
                LearnfoldStrictHarnessPolicy.strictHarnessRoot(
                    arguments: ["Litter", scenario.route, scenario.rawValue],
                    environment: enabledEnvironment
                ),
                .courseGeneration
            )
        }
        for scenario in CourseEditorCheckpointUITestScenario.allCases {
            let configuration = CourseEditorCheckpointUITestConfiguration(
                scenario: scenario,
                runToken: canonicalRunToken
            )
            XCTAssertEqual(
                parse([
                    CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                    scenario.rawValue,
                    CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                    canonicalRunToken,
                ]),
                .valid(.courseEditor(configuration))
            )
        }
        for scenario in HermesLinkCheckpointScenario.allCases {
            XCTAssertEqual(
                parse([HermesLinkCheckpointScenario.argument, scenario.rawValue]),
                .valid(.hermesLink(scenario))
            )
        }
        for scenario in CourseRouteFallbackUITestScenario.allCases {
            XCTAssertEqual(
                parse([CourseRouteFallbackUITestScenario.argument, scenario.rawValue]),
                .valid(.courseRouteFallback(scenario))
            )
        }
    }

    func testBaseOnlyAndScenarioOnlySignalsAreRequestedButInvalid() {
        XCTAssertEqual(
            parse([CourseRecoveryCheckpointUITestScenario.launchArgument]),
            invalid(.missingState, suite: .courseRecovery)
        )
        XCTAssertEqual(
            parse(["--ui-test-server-lifecycle"]),
            invalid(.missingState, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse([CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue]),
            invalid(.missingRoute, suite: .courseRecovery)
        )
        XCTAssertEqual(
            parse([ServerLifecycleCheckpointScenario.sshLoginEmpty.rawValue]),
            invalid(.missingRoute, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse([ProviderSettingsSourceCheckpointScenario.launchArgument]),
            invalid(.missingState, suite: .providerSettingsSource)
        )
        XCTAssertEqual(
            parse([ProviderSettingsSourceCheckpointScenario.lf27Checking.rawValue]),
            invalid(.missingRoute, suite: .providerSettingsSource)
        )
        XCTAssertEqual(
            parse([CourseGenerationCheckpointScenario.lf39Route]),
            invalid(.missingState, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([CourseGenerationCheckpointScenario.lf44Pending.rawValue]),
            invalid(.missingRoute, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([CourseEditorCheckpointUITestConfigurationParser.baseFlag]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.missingScenario)
            )
        )
        XCTAssertEqual(
            parse([CourseEditorCheckpointUITestScenario.lf48Editable.rawValue]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.missingBaseFlag)
            )
        )
        XCTAssertEqual(
            parse([CourseRouteFallbackUITestScenario.argument]),
            invalid(.missingState, suite: .courseRouteFallback)
        )
        XCTAssertEqual(
            parse([CourseRouteFallbackUITestScenario.stalePage.rawValue]),
            invalid(.missingRoute, suite: .courseRouteFallback)
        )
        XCTAssertEqual(
            parse([HermesLinkCheckpointScenario.argument]),
            invalid(
                .suiteConfiguration,
                suite: .hermesLink,
                detail: .hermesLinkConfiguration
            )
        )
        XCTAssertEqual(
            parse([HermesLinkCheckpointScenario.waiting.rawValue]),
            .disabled,
            "Generic Link state words are not global launch signals without the Link route"
        )
    }

    func testDuplicateRouteAndStateSignalsFailClosed() {
        let recoveryBase = CourseRecoveryCheckpointUITestScenario.launchArgument
        let recoveryState = CourseRecoveryCheckpointUITestScenario.lf35Provenance.rawValue
        XCTAssertEqual(
            parse([recoveryBase, recoveryState, recoveryBase]),
            invalid(.duplicateRoute, suite: .courseRecovery)
        )
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle",
                "server-lifecycle-connected",
                "server-lifecycle-connected",
            ]),
            invalid(.multipleStates, suite: .serverLifecycle)
        )
    }

    func testGenerationRoutesAndScenarioCollisionsFailClosed() {
        let lf39 = CourseGenerationCheckpointScenario.lf39Milestone1
        let lf40 = CourseGenerationCheckpointScenario.lf40GenerationError
        let lf44 = CourseGenerationCheckpointScenario.lf44Pending

        XCTAssertEqual(
            parse([lf39.route, lf40.rawValue]),
            invalid(.routeStateMismatch, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([lf39.route, lf39.rawValue, lf40.rawValue]),
            invalid(.multipleStates, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([lf39.route, lf39.rawValue, lf39.route]),
            invalid(.duplicateRoute, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([
                lf39.route,
                lf39.rawValue,
                lf44.route,
                lf44.rawValue,
            ]),
            invalid(.multipleRoutes, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse([lf39.route, "--ui-test-lf39-unknown"]),
            invalid(.unknownState, suite: .courseGeneration)
        )
        XCTAssertEqual(
            parse(["\(lf39.route)-malformed", lf39.rawValue]),
            invalid(.missingRoute, suite: .courseGeneration)
        )
    }

    func testGenerationErrorsSelectTheCentralConfigurationErrorRoot() {
        let malformedArguments = [
            [CourseGenerationCheckpointScenario.lf39Route],
            [CourseGenerationCheckpointScenario.lf40ReturnedAgent.rawValue],
            [
                CourseGenerationCheckpointScenario.lf44Route,
                "--ui-test-lf44-unknown",
            ],
        ]

        for arguments in malformedArguments {
            let configuration = parse(arguments)
            XCTAssertTrue(configuration.isRequested)
            XCTAssertEqual(configuration.suiteHint, .courseGeneration)
            XCTAssertEqual(configuration.root, .configurationError)
            XCTAssertEqual(
                LearnfoldStrictHarnessPolicy.strictHarnessRoot(
                    arguments: ["Litter"] + arguments,
                    environment: enabledEnvironment
                ),
                .configurationError
            )
        }
    }

    func testEditorTypedConfigurationAndAuxiliarySignalsFailClosed() {
        let base = CourseEditorCheckpointUITestConfigurationParser.baseFlag
        let scenario = CourseEditorCheckpointUITestScenario.lf50Modified.rawValue
        let tokenFlag = CourseEditorCheckpointUITestConfigurationParser.runTokenFlag

        XCTAssertEqual(
            parse([base, scenario]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.missingRunToken)
            )
        )
        XCTAssertEqual(
            parse([base, scenario, tokenFlag, "not-a-uuid"]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.invalidRunToken("not-a-uuid"))
            )
        )
        XCTAssertEqual(
            parse([
                base,
                scenario,
                tokenFlag,
                canonicalRunToken,
                tokenFlag,
                canonicalRunToken,
            ]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.duplicateRunToken)
            )
        )
        XCTAssertEqual(
            parse([tokenFlag, canonicalRunToken]),
            invalid(
                .suiteConfiguration,
                suite: .courseEditor,
                detail: .courseEditor(.missingBaseFlag)
            )
        )
        XCTAssertEqual(
            parse([
                base,
                scenario,
                tokenFlag,
                canonicalRunToken,
                "--checkpoint-lf50-unknown",
            ]),
            invalid(.multipleStates, suite: .courseEditor)
        )
    }

    func testLinkTypedConfigurationRejectsMalformedAndExtraArguments() {
        XCTAssertEqual(
            parse(["--ui-test-hermes-link-checkpoin", "waiting"]),
            invalid(
                .suiteConfiguration,
                suite: .hermesLink,
                detail: .hermesLinkConfiguration
            )
        )
        XCTAssertEqual(
            parse([
                HermesLinkCheckpointScenario.argument,
                HermesLinkCheckpointScenario.waiting.rawValue,
                "bare-extra",
            ]),
            invalid(
                .suiteConfiguration,
                suite: .hermesLink,
                detail: .hermesLinkConfiguration
            )
        )
        XCTAssertEqual(
            parse([
                "--unrelated",
                HermesLinkCheckpointScenario.argument,
                HermesLinkCheckpointScenario.waiting.rawValue,
            ]),
            invalid(
                .suiteConfiguration,
                suite: .hermesLink,
                detail: .hermesLinkConfiguration
            )
        )
    }

    func testMalformedRouteAndExtraMalformedStateFailClosed() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle-malformed",
                "server-lifecycle-connected",
            ]),
            invalid(.missingRoute, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle",
                "server-lifecycle-connected",
                "server-lifecycle-malformed",
            ]),
            invalid(.multipleStates, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse([
                ProviderSettingsSourceCheckpointScenario.launchArgument,
                "--ui-test-lf27-unknown",
            ]),
            invalid(.unknownState, suite: .providerSettingsSource)
        )
        XCTAssertEqual(
            parse(["--ui-test-lf30-not-a-state"]),
            invalid(.missingRoute, suite: .providerSettingsSource)
        )
        for malformedLF03State in [
            "--ui-test-lf03-",
            "--ui-test-lf03-unknown",
        ] {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forArgument: malformedLF03State
                ),
                .registeredStrict,
                malformedLF03State
            )
            XCTAssertEqual(
                parse([malformedLF03State]),
                invalid(.missingRoute, suite: .providerSettingsSource),
                malformedLF03State
            )
            XCTAssertEqual(
                parse([
                    ProviderSettingsSourceCheckpointScenario.launchArgument,
                    malformedLF03State,
                ]),
                invalid(.unknownState, suite: .providerSettingsSource),
                malformedLF03State
            )
        }
        XCTAssertEqual(
            parse([
                CourseRouteFallbackUITestScenario.argument,
                "unknown-route-fallback-state",
            ]),
            invalid(.unknownState, suite: .courseRouteFallback)
        )
    }

    func testCrossSuiteAndUnregisteredCheckpointSignalsAreQuarantined() {
        XCTAssertEqual(
            parse([
                "--ui-test-server-lifecycle",
                "server-lifecycle-connected",
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse(["--ui-test-unregistered-checkpoint"]),
            invalid(.unregisteredCheckpoint, suite: nil)
        )
        XCTAssertEqual(
            parse(["--checkpoint-lf99-unknown"]),
            invalid(.unregisteredCheckpoint, suite: nil)
        )
        for unknownAuthoritySignal in [
            "--ui-test-lf99-unknown",
            "--ui-test-lf03",
            "--ui-test-provider-settings-source-checkpoin",
            "--ui-test-unrelated",
        ] {
            XCTAssertNil(
                DebugLaunchSignalAuthorityInventory.category(
                    forArgument: unknownAuthoritySignal
                ),
                unknownAuthoritySignal
            )
            XCTAssertEqual(
                parse([unknownAuthoritySignal]),
                invalid(.unregisteredCheckpoint, suite: nil),
                unknownAuthoritySignal
            )
            XCTAssertEqual(
                parse([unknownAuthoritySignal], environment: [:]),
                invalid(.testingEnvironmentRequired, suite: nil),
                unknownAuthoritySignal
            )
        }
        XCTAssertEqual(
            parse([
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                ProviderSettingsSourceCheckpointScenario.launchArgument,
                ProviderSettingsSourceCheckpointScenario.lf27Checking.rawValue,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse([
                CourseGenerationCheckpointScenario.lf39Route,
                CourseGenerationCheckpointScenario.lf39Milestone1.rawValue,
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse([
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                canonicalRunToken,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse([
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                HermesLinkCheckpointScenario.argument,
                HermesLinkCheckpointScenario.waiting.rawValue,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse([
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                CourseRouteFallbackUITestScenario.argument,
            ]),
            invalid(.multipleSuites, suite: nil)
        )
        XCTAssertEqual(
            parse([
                CourseRecoveryCheckpointUITestScenario.launchArgument,
                CourseRecoveryCheckpointUITestScenario.lf34Preparing.rawValue,
                "--ui-test-unregistered-checkpoint",
            ]),
            invalid(.unregisteredCheckpoint, suite: .courseRecovery)
        )
        XCTAssertEqual(
            parse([
                CourseGenerationCheckpointScenario.lf40Route,
                CourseGenerationCheckpointScenario.lf40GenerationError.rawValue,
                "--ui-test-unregistered-checkpoint",
            ]),
            invalid(.unregisteredCheckpoint, suite: .courseGeneration)
        )
    }

    func testEnvironmentAbsentValidAndMalformedSignalsRemainRequested() {
        XCTAssertEqual(
            parse(
                ["--ui-test-server-lifecycle", "server-lifecycle-connected"],
                environment: [:]
            ),
            invalid(.testingEnvironmentRequired, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse(
                [
                    "--ui-test-server-lifecycle-malformed",
                    "server-lifecycle-connected",
                ],
                environment: [:]
            ),
            invalid(.testingEnvironmentRequired, suite: .serverLifecycle)
        )
        XCTAssertEqual(
            parse(
                ["--ui-test-lf44-unknown"],
                environment: [:]
            ),
            invalid(.testingEnvironmentRequired, suite: .courseGeneration)
        )
        let cases: [(arguments: [String], suite: StrictUITestSuiteID)] = [
            (
                [
                    ProviderSettingsSourceCheckpointScenario.launchArgument,
                    ProviderSettingsSourceCheckpointScenario.lf05Saving.rawValue,
                ],
                .providerSettingsSource
            ),
            (
                [
                    CourseEditorCheckpointUITestConfigurationParser.baseFlag,
                    CourseEditorCheckpointUITestScenario.lf45Loaded.rawValue,
                    CourseEditorCheckpointUITestConfigurationParser.runTokenFlag,
                    canonicalRunToken,
                ],
                .courseEditor
            ),
            (
                [
                    CourseGenerationCheckpointScenario.lf44Route,
                    CourseGenerationCheckpointScenario.lf44PartialGenerated.rawValue,
                ],
                .courseGeneration
            ),
            (
                [
                    HermesLinkCheckpointScenario.argument,
                    HermesLinkCheckpointScenario.waiting.rawValue,
                ],
                .hermesLink
            ),
            (
                [
                    CourseRouteFallbackUITestScenario.argument,
                    CourseRouteFallbackUITestScenario.staleFile.rawValue,
                ],
                .courseRouteFallback
            ),
        ]
        for testCase in cases {
            XCTAssertEqual(
                parse(testCase.arguments, environment: [:]),
                invalid(.testingEnvironmentRequired, suite: testCase.suite)
            )
        }
    }

    func testEveryRegisteredArgumentHasStrictAuthority() {
        for suite in StrictUITestSuiteDescriptor.registered {
            for route in suite.routes.keys {
                XCTAssertEqual(
                    DebugLaunchSignalAuthorityInventory.category(
                        forArgument: route
                    ),
                    .registeredStrict,
                    route
                )
            }
            for scenario in suite.allScenarioArguments {
                XCTAssertEqual(
                    DebugLaunchSignalAuthorityInventory.category(
                        forArgument: scenario
                    ),
                    .registeredStrict,
                    scenario
                )
            }
            for auxiliary in suite.auxiliaryCheckpointArguments {
                XCTAssertEqual(
                    DebugLaunchSignalAuthorityInventory.category(
                        forArgument: auxiliary
                    ),
                    .registeredStrict,
                    auxiliary
                )
            }
            for prefix in suite.scenarioShapePrefixes
                + suite.suiteSignalPrefixes {
                let malformedSignal = "\(prefix)authority-probe"
                XCTAssertEqual(
                    DebugLaunchSignalAuthorityInventory.category(
                        forArgument: malformedSignal
                    ),
                    .registeredStrict,
                    malformedSignal
                )
            }
        }
    }

    func testNonStrictAuthorityInventoryMatchesEveryKnownControl() {
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.legacyPrimaryArguments,
            [
                "--ui-test-course-draft-recovery",
                "--ui-test-course-reading",
                "--ui-test-course-submission-recovery",
                "--ui-test-starter-course",
                "--ui-test-course-generation-control",
                "--ui-test-course-learning-path",
                "--ui-test-visualization-gallery",
                "--ui-test-course-retry",
                "--ui-test-course-save-recovery",
                "--ui-test-course-chat-continuity",
                "--ui-test-course-chat-question",
                "--ui-test-conversation-display",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.legacyModifierArguments,
            [
                "--ui-test-dynamic-type-default",
                "--ui-test-dynamic-type-ax3xl",
                "--ui-test-learning-path-in-exploration",
                "--ui-test-generation-recovery-acceptance-unknown",
                "--ui-test-generation-recovery-accepted-reply-incomplete",
                "--ui-test-open-settings",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.liveOnlyArguments,
            [
                "--lf-01-splash-freeze-hook",
                "--lf-05-live-acceptance-hook",
                "--lf-05-live-saving",
                "--lf-05-live-error",
                "--lf-06-live-acceptance-hook",
                "--lf-06-live-connecting",
                "--lf-06-live-failed",
                "--ui-test-lf32-optimistic",
                "--ui-test-lf41-completion",
                "--ui-test-lf52-answer",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.legacyControllingEnvironmentKeys,
            [
                "LEARNFOLD_MARKETING_SCREEN",
                "SNAPPY_RESET_ONBOARDING",
                "SNAPPY_APPLE_ON_DEVICE_AVAILABLE",
                "SNAPPY_APPLE_PRIVATE_CLOUD_AVAILABLE",
                "CODEXIOS_UI_TEST_REASONING_MODE",
                "CODEXIOS_UI_TEST_COMMAND_MODE",
                "CODEXIOS_UI_TEST_TOOL_MODE",
                "CODEXIOS_SIM_AUTO_SSH",
                "CODEXIOS_SIM_AUTO_SSH_HOST",
                "CODEXIOS_SIM_AUTO_SSH_USER",
                "CODEXIOS_SIM_AUTO_SSH_PASS",
                "CODEXIOS_SIM_AUTO_SSH_KEY_PATH",
                "CODEXIOS_SIM_AUTO_SSH_PASSPHRASE",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.strictAuxiliaryEnvironmentKeys,
            [
                "LEARNFOLD_UI_TESTING",
                "SNAPPY_SKIP_AGENT_SETUP",
                "CODEXIOS_UI_TEST_FORCE_DISCOVERY",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.liveOnlyEvidenceMarkers,
            [
                "course-request-lifecycle",
                "course-building-state",
                "course-building-open-course",
                "course-detail-root",
                "focused-qa-state",
                "focused-qa-open-reader",
                "focused-qa-reader",
                "course-chat-resolve",
            ]
        )
        XCTAssertEqual(
            DebugLaunchSignalAuthorityInventory.retiredWaiverCheckpoints,
            ["LF-08", "LF-10"]
        )
    }

    func testSplashAcceptanceFreezeRequiresItsExactDebugArgument() {
        XCTAssertFalse(LearnfoldSplashAcceptanceFreezePolicy.isEnabled(arguments: []))
        XCTAssertFalse(
            LearnfoldSplashAcceptanceFreezePolicy.isEnabled(
                arguments: ["lf-01-splash-freeze-hook"]
            )
        )
        XCTAssertTrue(
            LearnfoldSplashAcceptanceFreezePolicy.isEnabled(
                arguments: ["--lf-01-splash-freeze-hook"]
            )
        )
    }

    func testLF05LiveAcceptanceControlRequiresExactlyOneKnownArgument() {
        XCTAssertNil(LF05LiveAcceptanceControl.current(arguments: []))
        XCTAssertEqual(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-saving",
                ]
            ),
            .saving
        )
        XCTAssertEqual(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-error",
                ]
            ),
            .error
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: ["--lf-05-live-saving"]
            )
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-saving",
                    "--lf-05-live-error",
                ]
            )
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-saving",
                    "--lf-05-live-saving",
                ]
            )
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-saving",
                ]
            )
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-unknown",
                ]
            )
        )
        XCTAssertNil(
            LF05LiveAcceptanceControl.current(
                arguments: [
                    "--lf-05-live-acceptance-hook",
                    "--lf-05-live-saving",
                    "--lf-05-live-unknown",
                ]
            )
        )
        XCTAssertEqual(
            LF05LiveAcceptanceControl.savingDelayNanoseconds,
            15_000_000_000
        )
        XCTAssertEqual(
            LF05LiveAcceptanceControl.forcedErrorDescription,
            "Controlled acceptance failure before provider settings were changed."
        )
    }

    func testLF06LiveAcceptanceControlRequiresExactlyOneKnownArgument() {
        XCTAssertNil(LF06LiveAcceptanceControl.current(arguments: []))
        XCTAssertEqual(
            LF06LiveAcceptanceControl.current(
                arguments: [
                    "--lf-06-live-acceptance-hook",
                    "--lf-06-live-connecting",
                ]
            ),
            .connecting
        )
        XCTAssertEqual(
            LF06LiveAcceptanceControl.current(
                arguments: [
                    "--lf-06-live-acceptance-hook",
                    "--lf-06-live-failed",
                ]
            ),
            .failed
        )
        XCTAssertNil(
            LF06LiveAcceptanceControl.current(
                arguments: ["--lf-06-live-connecting"]
            )
        )
        XCTAssertNil(
            LF06LiveAcceptanceControl.current(
                arguments: [
                    "--lf-06-live-acceptance-hook",
                    "--lf-06-live-connecting",
                    "--lf-06-live-failed",
                ]
            )
        )
        XCTAssertNil(
            LF06LiveAcceptanceControl.current(
                arguments: [
                    "--lf-06-live-acceptance-hook",
                    "--lf-06-live-connecting",
                    "--lf-06-live-unknown",
                ]
            )
        )
        XCTAssertEqual(
            LF06LiveAcceptanceControl.connectingDelayNanoseconds,
            15_000_000_000
        )
        XCTAssertEqual(
            LF06LiveAcceptanceControl.forcedFailureDescription,
            "Controlled acceptance failure before course-agent setup was changed."
        )
    }

    func testEveryNonStrictControlHasItsExplicitAuthorityCategory() {
        for argument in DebugLaunchSignalAuthorityInventory.legacyPrimaryArguments
            .union(DebugLaunchSignalAuthorityInventory.legacyModifierArguments) {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forArgument: argument
                ),
                .explicitlyQuarantined,
                argument
            )
        }
        for argument in DebugLaunchSignalAuthorityInventory.liveOnlyArguments {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forArgument: argument
                ),
                .liveOnly,
                argument
            )
        }
        for key in DebugLaunchSignalAuthorityInventory
            .legacyControllingEnvironmentKeys {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forEnvironmentKey: key
                ),
                .explicitlyQuarantined,
                key
            )
        }
        for key in DebugLaunchSignalAuthorityInventory
            .strictAuxiliaryEnvironmentKeys {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forEnvironmentKey: key
                ),
                .strictAuxiliary,
                key
            )
        }
        for marker in DebugLaunchSignalAuthorityInventory
            .liveOnlyEvidenceMarkers {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forEvidenceMarker: marker
                ),
                .liveOnly,
                marker
            )
        }
        for checkpoint in DebugLaunchSignalAuthorityInventory
            .retiredWaiverCheckpoints {
            XCTAssertEqual(
                DebugLaunchSignalAuthorityInventory.category(
                    forCheckpoint: checkpoint
                ),
                .retiredWaiver,
                checkpoint
            )
        }
    }

    func testLegacyRegressionsRemainDisabledWhenLaunchedAlone() {
        let legacyArguments = DebugLaunchSignalAuthorityInventory
            .legacyPrimaryArguments
            .union(DebugLaunchSignalAuthorityInventory.legacyModifierArguments)
            .union(DebugLaunchSignalAuthorityInventory.liveOnlyArguments)
        for argument in legacyArguments {
            XCTAssertEqual(parse([argument]), .disabled, argument)
        }
        for key in DebugLaunchSignalAuthorityInventory
            .legacyControllingEnvironmentKeys {
            var environment = enabledEnvironment
            environment[key] = "1"
            XCTAssertEqual(parse([], environment: environment), .disabled, key)
        }
        XCTAssertEqual(parse(["--some-unrelated-argument"]), .disabled)
    }

    func testNormalSystemAndXCTestArgumentsDoNotRequestStrictHarness() {
        XCTAssertEqual(
            parse([
                "-AppleLanguages", "(en)",
                "-AppleLocale", "en_US",
                "-NSTreatUnknownArgumentsAsOpen", "NO",
                "-XCTestBundlePath", "/tmp/LitterTests.xctest",
            ]),
            .disabled
        )
    }

    func testEveryLegacyOrLiveOnlyControlRejectsMixedStrictLaunch() {
        let scenario = CourseGenerationCheckpointScenario.lf39Milestone1
        let strictArguments = [scenario.route, scenario.rawValue]
        let conflictingArguments = DebugLaunchSignalAuthorityInventory
            .legacyPrimaryArguments
            .union(DebugLaunchSignalAuthorityInventory.legacyModifierArguments)
            .union(DebugLaunchSignalAuthorityInventory.liveOnlyArguments)

        for argument in conflictingArguments {
            XCTAssertEqual(
                parse(strictArguments + [argument]),
                invalid(.mixedLaunchAuthorities, suite: .courseGeneration),
                argument
            )
        }
        for key in DebugLaunchSignalAuthorityInventory
            .legacyControllingEnvironmentKeys {
            var environment = enabledEnvironment
            environment[key] = "1"
            XCTAssertEqual(
                parse(strictArguments, environment: environment),
                invalid(.mixedLaunchAuthorities, suite: .courseGeneration),
                key
            )
        }
    }

    func testStrictAuxiliaryEnvironmentRemainsCompatibleWithStrictRoutes() {
        let scenario = CourseGenerationCheckpointScenario.lf39Milestone1
        for key in DebugLaunchSignalAuthorityInventory
            .strictAuxiliaryEnvironmentKeys {
            var environment = enabledEnvironment
            environment[key] = "1"
            XCTAssertEqual(
                parse(
                    [scenario.route, scenario.rawValue],
                    environment: environment
                ),
                .valid(.courseGeneration(scenario)),
                key
            )
        }
    }

    func testSentinelTripwireIsNonVacuousForExplicitStrictArguments() {
        let arguments = [
            "--ui-test-server-lifecycle",
            "server-lifecycle-connected",
        ]
        LearnfoldStrictHarnessSentinel.resetForTesting()
        LearnfoldStrictHarnessSentinel.recordForbiddenEntry(
            "synthetic",
            arguments: arguments,
            environment: enabledEnvironment
        )
        XCTAssertEqual(
            LearnfoldStrictHarnessSentinel.forbiddenEvents(
                arguments: arguments,
                environment: enabledEnvironment
            ),
            ["synthetic"]
        )
        LearnfoldStrictHarnessSentinel.resetForTesting()
    }

    func testInertP2DependenciesContainNoLiveRuntimeObjects() {
        let discoveryDependencies = DiscoveryViewRuntimeDependencies.inertCheckpoint
        XCTAssertNil(discoveryDependencies.appModel)
        XCTAssertNil(discoveryDependencies.appState)
        XCTAssertTrue(discoveryDependencies.isInertCheckpoint)

        let agentPickerDependencies = SSHAgentPickerRuntimeDependencies.inertCheckpoint
        XCTAssertNil(agentPickerDependencies.appModel)
        XCTAssertTrue(agentPickerDependencies.isInertCheckpoint)

        let discovery = NetworkDiscovery(runtimeMode: .inertCheckpoint)
        XCTAssertEqual(discovery.runtimeMode, .inertCheckpoint)
    }

    func testEveryCentralSuiteHasAVisibleSentinelContract() {
        let presentations: [(String, LearnfoldStrictHarnessSentinelPresentation)] = [
            ("courseRecoveryCheckpoint.strictRoot", .courseRecovery),
            ("serverCheckpoint.strictRoot", .serverLifecycle),
            ("providerSettingsSourceCheckpoint.strictRoot", .providerSettingsSource),
            ("courseGenerationCheckpoint.strictRoot", .courseGeneration),
            ("courseEditorCheckpoint.strictRoot", .courseEditor),
            ("hermesLinkCheckpoint.strictRoot", .hermesLink),
            ("courseRouteFallbackCheckpoint.strictRoot", .courseRouteFallback),
        ]

        XCTAssertEqual(
            Set(presentations.map { $0.1.rootIdentifier }).count,
            presentations.count
        )
        XCTAssertEqual(
            Set(presentations.map { $0.1.eventIdentifier }).count,
            presentations.count
        )
        for (rootIdentifier, presentation) in presentations {
            XCTAssertEqual(presentation.rootIdentifier, rootIdentifier)
            XCTAssertTrue(presentation.eventIdentifier.hasSuffix("forbiddenSideEffects"))
            XCTAssertTrue(presentation.detailsIdentifier.hasSuffix("forbiddenSideEffectDetails"))
        }
    }

    func testInertDiscoveryAlternateSSHLoginDisablesCredentialStoreAccess() {
        let dependencies = DiscoveryViewRuntimeDependencies.inertCheckpoint
        let runtimeMode = dependencies.sshLoginRuntimeMode
        XCTAssertEqual(runtimeMode, .inertCheckpoint)
        XCTAssertFalse(runtimeMode.allowsCredentialStoreAccess)

        let server = DiscoveredServer(
            id: "alternate-navigation-redacted",
            name: "Redacted Test Host",
            hostname: "redacted.invalid",
            port: nil,
            codexPorts: [],
            sshPort: 22,
            source: .ssh,
            hasCodexServer: false,
            preferredConnectionMode: .ssh,
            os: "macOS"
        )
        let sheet = SSHLoginSheet(
            server: server,
            runtimeMode: runtimeMode,
            autoLoadSavedCredentials: true
        ) { _ in }
        XCTAssertEqual(sheet.debugRuntimeMode, .inertCheckpoint)
        XCTAssertFalse(sheet.debugAutoLoadsSavedCredentials)

        let arguments = [
            "Litter",
            ServerLifecycleCheckpointScenario.sshAgentPickerPopulated.route,
            ServerLifecycleCheckpointScenario.sshAgentPickerPopulated.rawValue,
        ]
        LearnfoldStrictHarnessSentinel.resetForTesting()
        XCTAssertEqual(
            LearnfoldStrictHarnessSentinel.forbiddenEvents(
                arguments: arguments,
                environment: enabledEnvironment
            ),
            []
        )
    }

    private func parse(
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> StrictUITestLaunchConfiguration {
        StrictUITestLaunchConfiguration.parse(
            arguments: ["Litter"] + arguments,
            environment: environment ?? enabledEnvironment
        )
    }

    private func invalid(
        _ code: StrictUITestLaunchErrorCode,
        suite: StrictUITestSuiteID?,
        detail: StrictUITestLaunchErrorDetail? = nil
    ) -> StrictUITestLaunchConfiguration {
        .invalid(StrictUITestLaunchError(
            code: code,
            suiteHint: suite,
            detail: detail
        ))
    }

    private var canonicalRunToken: String {
        "01234567-89ab-cdef-0123-456789abcdef"
    }
}
#endif

final class SSHLoginSubmissionOutcomeTests: XCTestCase {
    func testRejectedSubmissionPreservesInputsAndSkipsPersistence() {
        let disposition = SSHLoginSubmissionOutcome
            .rejected(message: "Authentication failed")
            .disposition

        XCTAssertFalse(disposition.shouldPersistCredentials)
        XCTAssertFalse(disposition.shouldClearSensitiveInput)
        XCTAssertTrue(disposition.shouldKeepSheetPresented)
        XCTAssertEqual(disposition.errorMessage, "Authentication failed")
    }

    func testAcceptedSubmissionPersistsThenClearsAndDismisses() {
        let disposition = SSHLoginSubmissionOutcome.accepted.disposition

        XCTAssertTrue(disposition.shouldPersistCredentials)
        XCTAssertTrue(disposition.shouldClearSensitiveInput)
        XCTAssertFalse(disposition.shouldKeepSheetPresented)
        XCTAssertNil(disposition.errorMessage)
    }

    func testInProgressSubmissionKeepsInputsWithoutPersisting() {
        let disposition = SSHLoginSubmissionOutcome.inProgress.disposition

        XCTAssertFalse(disposition.shouldPersistCredentials)
        XCTAssertFalse(disposition.shouldClearSensitiveInput)
        XCTAssertTrue(disposition.shouldKeepSheetPresented)
        XCTAssertNil(disposition.errorMessage)
    }
}
