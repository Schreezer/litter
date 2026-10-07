import NativeEditorMCP
import SwiftUI

#if DEBUG
enum ProviderSettingsSourceCheckpointScenario: String, CaseIterable, Hashable {
    static let launchArgument =
        "--ui-test-provider-settings-source-checkpoint"
    static let lf03HookIdentifier = "lf-03-fixture-hook"

    case lf03PickerAvailable = "--ui-test-lf03-picker-available"
    case lf03PickerUnavailable = "--ui-test-lf03-picker-unavailable"

    case lf05Saving = "--ui-test-lf05-saving"
    case lf05SuccessReturn = "--ui-test-lf05-success-return"
    case lf05Error = "--ui-test-lf05-error"

    case lf06Connecting = "--ui-test-lf06-connecting"
    case lf06ConnectedTarget = "--ui-test-lf06-connected-target"
    case lf06Failed = "--ui-test-lf06-failed"

    case lf27ModelLoading = "--ui-test-lf27-model-loading"
    case lf27ModelEmpty = "--ui-test-lf27-model-empty"
    case lf27ModelDefault = "--ui-test-lf27-model-default"
    case lf27ModelPopulated = "--ui-test-lf27-model-populated"
    case lf27Checking = "--ui-test-lf27-checking"
    case lf27Cancel = "--ui-test-lf27-cancel"
    case lf27FailureRollback = "--ui-test-lf27-failure-rollback"
    case lf27AgentError = "--ui-test-lf27-agent-error"

    case lf28Synced = "--ui-test-lf28-synced"
    case lf28OnThisDevice = "--ui-test-lf28-on-this-device"
    case lf28SignInRequired = "--ui-test-lf28-sign-in-required"
    case lf28NeedsAttention = "--ui-test-lf28-needs-attention"
    case lf28Retry = "--ui-test-lf28-retry"

    case lf30SourceMenu = "--ui-test-lf30-source-menu"
    case lf30Preparing = "--ui-test-lf30-preparing"
    case lf30PassageContext = "--ui-test-lf30-passage-context"
    case lf30PermissionError = "--ui-test-lf30-permission-error"
    case lf30ParseError = "--ui-test-lf30-parse-error"
    case lf30PreparationError = "--ui-test-lf30-preparation-error"

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let stateArguments = arguments.filter {
            $0.hasPrefix("--ui-test-lf")
        }
        guard stateArguments.count == 1,
              let scenario = Self(rawValue: stateArguments[0]) else {
            return nil
        }
        return scenario
    }

    var checkpointID: String {
        switch self {
        case .lf03PickerAvailable, .lf03PickerUnavailable:
            "LF-03"
        case .lf05Saving, .lf05SuccessReturn, .lf05Error:
            "LF-05"
        case .lf06Connecting, .lf06ConnectedTarget, .lf06Failed:
            "LF-06"
        case .lf27ModelLoading, .lf27ModelEmpty, .lf27ModelDefault,
             .lf27ModelPopulated, .lf27Checking, .lf27Cancel,
             .lf27FailureRollback, .lf27AgentError:
            "LF-27"
        case .lf28Synced, .lf28OnThisDevice, .lf28SignInRequired,
             .lf28NeedsAttention, .lf28Retry:
            "LF-28"
        case .lf30SourceMenu, .lf30Preparing, .lf30PassageContext,
             .lf30PermissionError, .lf30ParseError, .lf30PreparationError:
            "LF-30"
        }
    }

    var substate: String {
        switch self {
        case .lf03PickerAvailable: "picker-available"
        case .lf03PickerUnavailable: "picker-unavailable"
        case .lf05Saving: "saving"
        case .lf05SuccessReturn: "success-return"
        case .lf05Error: "error"
        case .lf06Connecting: "connecting"
        case .lf06ConnectedTarget: "connected-target"
        case .lf06Failed: "failed"
        case .lf27ModelLoading: "model-loading"
        case .lf27ModelEmpty: "model-empty"
        case .lf27ModelDefault: "model-default"
        case .lf27ModelPopulated: "model-populated"
        case .lf27Checking: "checking"
        case .lf27Cancel: "cancel"
        case .lf27FailureRollback: "failure-rollback"
        case .lf27AgentError: "agent-error"
        case .lf28Synced: "synced"
        case .lf28OnThisDevice: "on-this-device"
        case .lf28SignInRequired: "sign-in-required"
        case .lf28NeedsAttention: "needs-attention"
        case .lf28Retry: "retry"
        case .lf30SourceMenu: "source-menu"
        case .lf30Preparing: "preparing"
        case .lf30PassageContext: "passage-context"
        case .lf30PermissionError: "permission-error"
        case .lf30ParseError: "parse-error"
        case .lf30PreparationError: "preparation-error"
        }
    }

    var nonLiveBoundary: String {
        switch checkpointID {
        case "LF-03":
            "NON-LIVE PICKER FIXTURE · LIVE-FROZEN PRODUCT COMPANION STILL REQUIRED"
        case "LF-05", "LF-06":
            "NON-LIVE COMPONENT CHECKPOINT · LIVE-CONTROLLED EVIDENCE STILL REQUIRED"
        case "LF-28":
            "NON-LIVE FIXTURE · USE ONLY WHEN LIVE ACCOUNT STATE IS UNAVAILABLE"
        default:
            "NON-LIVE FAULT CHECKPOINT · LIVE-PRODUCT COMPANION STILL REQUIRED"
        }
    }

    var isSourceCheckpoint: Bool {
        checkpointID == "LF-30"
    }

    var deterministicHookIdentifier: String? {
        checkpointID == "LF-03" ? Self.lf03HookIdentifier : nil
    }
}

enum CourseGenerationCheckpointScenario: String, CaseIterable, Hashable {
    static let lf39Route = "--ui-test-lf-39-fixture-hook"
    static let lf40Route = "--ui-test-lf-40-fault-hook"
    static let lf44Route = "--ui-test-lf-44-fault-hook"

    case lf39Milestone1 = "--ui-test-lf39-milestone-1"
    case lf39Milestone2 = "--ui-test-lf39-milestone-2"
    case lf39Milestone3 = "--ui-test-lf39-milestone-3"
    case lf39Milestone4 = "--ui-test-lf39-milestone-4"
    case lf39Milestone5 = "--ui-test-lf39-milestone-5"
    case lf40GenerationError = "--ui-test-lf40-generation-error"
    case lf40ReturnedAgent = "--ui-test-lf40-returned-agent"
    case lf44Pending = "--ui-test-lf44-pending"
    case lf44Generating = "--ui-test-lf44-generating"
    case lf44PartialGenerated = "--ui-test-lf44-partial-generated"
    case lf44Error = "--ui-test-lf44-error"

    var route: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            Self.lf39Route
        case .lf40GenerationError, .lf40ReturnedAgent:
            Self.lf40Route
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            Self.lf44Route
        }
    }

    var checkpointID: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            "LF-39"
        case .lf40GenerationError, .lf40ReturnedAgent:
            "LF-40"
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            "LF-44"
        }
    }

    var substate: String {
        switch self {
        case .lf39Milestone1: "milestone-1"
        case .lf39Milestone2: "milestone-2"
        case .lf39Milestone3: "milestone-3"
        case .lf39Milestone4: "milestone-4"
        case .lf39Milestone5: "milestone-5"
        case .lf40GenerationError: "generation-error"
        case .lf40ReturnedAgent: "returned-agent"
        case .lf44Pending: "pending"
        case .lf44Generating: "generating"
        case .lf44PartialGenerated: "partial-generated"
        case .lf44Error: "error"
        }
    }

    var hookIdentifier: String {
        switch self {
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5:
            "lf-39-fixture-hook"
        case .lf40GenerationError, .lf40ReturnedAgent:
            "lf-40-fault-hook"
        case .lf44Pending, .lf44Generating, .lf44PartialGenerated,
             .lf44Error:
            "lf-44-fault-hook"
        }
    }

    var nonLiveBoundary: String {
        switch checkpointID {
        case "LF-39":
            "NON-LIVE TRANSIENT CHECKPOINT · LIVE AI INFERENCE PROOF STILL REQUIRED"
        case "LF-44":
            "NON-LIVE GENERATION CHECKPOINT · LIVE AI COMPANION STILL REQUIRED"
        default:
            "NON-LIVE FAULT CHECKPOINT · DOES NOT PROVE A LIVE AGENT RETURN"
        }
    }
}

/// Debug-only controls for capturing the genuine LF-05 save lifecycle in the
/// live product. These do not select a fixture root: the user still navigates
/// the real setup sheet, enters valid settings, and presses its real Save
/// button. The saving control only lengthens the existing in-flight state; the
/// error control fails immediately before any credential or endpoint write.
enum LF05LiveAcceptanceControl: String, CaseIterable, Hashable {
    static let launchArgument = "--lf-05-live-acceptance-hook"

    case saving = "--lf-05-live-saving"
    case error = "--lf-05-live-error"

    static let savingDelayNanoseconds: UInt64 = 15_000_000_000
    static let forcedErrorDescription =
        "Controlled acceptance failure before provider settings were changed."

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let hookArguments = arguments.filter {
            $0.hasPrefix("--lf-05-live-") && $0 != launchArgument
        }
        let matches = arguments.compactMap(Self.init(rawValue:))
        guard matches.count == 1, hookArguments.count == 1 else { return nil }
        return matches[0]
    }
}

private struct LF05LiveAcceptanceError: LocalizedError {
    var errorDescription: String? {
        LF05LiveAcceptanceControl.forcedErrorDescription
    }
}

/// Debug-only controls for observing the genuine LF-06 setup connection
/// lifecycle. The connecting mode only lengthens the real in-flight state;
/// the failed mode returns through the real picker without persisting a
/// provider selection or marking setup complete.
enum LF06LiveAcceptanceControl: String, CaseIterable, Hashable {
    static let launchArgument = "--lf-06-live-acceptance-hook"

    case connecting = "--lf-06-live-connecting"
    case failed = "--lf-06-live-failed"

    static let connectingDelayNanoseconds: UInt64 = 15_000_000_000
    static let forcedFailureDescription =
        "Controlled acceptance failure before course-agent setup was changed."

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Self? {
        guard arguments.filter({ $0 == launchArgument }).count == 1 else {
            return nil
        }
        let hookArguments = arguments.filter {
            $0.hasPrefix("--lf-06-live-") && $0 != launchArgument
        }
        let matches = arguments.compactMap(Self.init(rawValue:))
        guard matches.count == 1, hookArguments.count == 1 else { return nil }
        return matches[0]
    }
}
#endif

enum CourseRouteUnavailableKind: String, Equatable {
    case course
    case page
    case file
}

enum CourseRouteRecoveryTarget: Equatable {
    case library
    case courseStructure
}

struct CourseRouteRecoveryAction: Equatable {
    let title: String
    let accessibilityIdentifier: String
    let target: CourseRouteRecoveryTarget
}

struct CourseRouteUnavailableContent: Equatable {
    let title: String
    let description: String
    let systemImage: String
    let primaryAction: CourseRouteRecoveryAction
    let secondaryAction: CourseRouteRecoveryAction?
}

enum CourseRouteFallbackPolicy {
    static func unavailableKind(
        for route: CourseRoute,
        courseExists: Bool,
        childExists: Bool? = nil
    ) -> CourseRouteUnavailableKind? {
        switch route {
        case .course:
            return courseExists ? nil : .course
        case .coursePage:
            guard courseExists else { return .course }
            return childExists == false ? .page : nil
        case .courseFile:
            guard courseExists else { return .course }
            return childExists == false ? .file : nil
        case .newCourse, .building:
            return nil
        }
    }

    static func content(
        for kind: CourseRouteUnavailableKind,
        courseTitle: String?,
        canOpenCourseStructure: Bool
    ) -> CourseRouteUnavailableContent {
        let library = CourseRouteRecoveryAction(
            title: "Return to Course Library",
            accessibilityIdentifier: "course-route-return-to-library",
            target: .library
        )
        let structure = CourseRouteRecoveryAction(
            title: "Open Course Structure",
            accessibilityIdentifier: "course-route-open-course-structure",
            target: .courseStructure
        )
        let resolvedTitle = courseTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let courseName = if let resolvedTitle, !resolvedTitle.isEmpty {
            resolvedTitle
        } else {
            "this course"
        }

        switch kind {
        case .course:
            return CourseRouteUnavailableContent(
                title: "Course unavailable",
                description: "This course is no longer available on this device. Return to your course library to continue.",
                systemImage: "book.closed",
                primaryAction: library,
                secondaryAction: nil
            )
        case .page:
            return CourseRouteUnavailableContent(
                title: "Page unavailable",
                description: canOpenCourseStructure
                    ? "This page is no longer available in \(courseName). Open the course structure to choose an available page."
                    : "This page is no longer available in \(courseName). Return to your course library to continue.",
                systemImage: "doc.questionmark",
                primaryAction: canOpenCourseStructure ? structure : library,
                secondaryAction: canOpenCourseStructure ? library : nil
            )
        case .file:
            return CourseRouteUnavailableContent(
                title: "File unavailable",
                description: canOpenCourseStructure
                    ? "This file is no longer available in \(courseName). Open the course structure to choose an available file."
                    : "This file is no longer available in \(courseName). Return to your course library to continue.",
                systemImage: "doc.questionmark",
                primaryAction: canOpenCourseStructure ? structure : library,
                secondaryAction: canOpenCourseStructure ? library : nil
            )
        }
    }

    static func pageIsUnavailable(after error: Error) -> Bool {
        guard let editorError = error as? NativeEditorMCPError else { return false }
        if case .pageNotFound = editorError { return true }
        return false
    }

    static func fileIsUnavailable(after error: Error) -> Bool {
        guard let workspaceError = error as? CourseWorkspaceError else { return false }
        switch workspaceError {
        case .unavailable, .invalidRelativePath, .fileNotFound:
            return true
        case .fileTooLarge, .unreadableText:
            return false
        }
    }
}

struct CourseRouteUnavailableView: View {
    let kind: CourseRouteUnavailableKind
    let courseTitle: String?
    let canOpenCourseStructure: Bool
    let onOpenCourseStructure: (() -> Void)?
    let onReturnToLibrary: () -> Void

    private var content: CourseRouteUnavailableContent {
        CourseRouteFallbackPolicy.content(
            for: kind,
            courseTitle: courseTitle,
            canOpenCourseStructure: canOpenCourseStructure
        )
    }

    var body: some View {
        ContentUnavailableView {
            Label(content.title, systemImage: content.systemImage)
                .accessibilityIdentifier("course-route-unavailable-title")
        } description: {
            Text(content.description)
                .accessibilityIdentifier("course-route-unavailable-description")
        } actions: {
            Button(content.primaryAction.title) {
                perform(content.primaryAction.target)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(content.primaryAction.title)
            .accessibilityIdentifier(content.primaryAction.accessibilityIdentifier)

            if let secondaryAction = content.secondaryAction {
                Button(secondaryAction.title) {
                    perform(secondaryAction.target)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(secondaryAction.title)
                .accessibilityIdentifier(secondaryAction.accessibilityIdentifier)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        // Keep the unavailable-route marker separate from its recovery
        // actions so their stable button identifiers survive in raw AX.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-route-unavailable-\(kind.rawValue)")
    }

    private func perform(_ target: CourseRouteRecoveryTarget) {
        switch target {
        case .library:
            onReturnToLibrary()
        case .courseStructure:
            onOpenCourseStructure?()
        }
    }
}

struct CourseExperienceRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    var onConnectRemoteAgent: () -> Void
    #if targetEnvironment(macCatalyst)
    @State private var navigationHistory = CourseNavigationHistory<CourseRoute>()
    @State private var showsCommandDraftReplacementConfirmation = false
    @State private var showsDesktopAgentSettings = false
    @State private var showsDesktopAppSettings = false
    #endif

    var body: some View {
        courseExperience
        .task {
            store.installDocumentToolRouterIfNeeded(appModel: appModel)
            await store.recoverReadyCourses()
            if store.setupComplete, store.connectionState != .connected {
                // Relaunch must never open a paywall; the first send does.
                await store.connectLocalAgent(
                    appModel: appModel,
                    agentID: store.selectedAgentID ?? "codex",
                    gatesEntitlement: false
                )
            }
        }
        .task(id: store.setupComplete) {
            guard store.setupComplete else { return }
            await store.installStarterCourseIfNeeded()
        }
        #if targetEnvironment(macCatalyst)
        .focusedSceneValue(\.learnfoldCourseStore, store)
        .sheet(isPresented: $showsDesktopAgentSettings) {
            CourseAgentSettingsView(store: store, onConnectRemoteAgent: onConnectRemoteAgent)
                .environment(appModel)
                .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 680)
        }
        .sheet(isPresented: $showsDesktopAppSettings) {
            SettingsView().environment(appModel).environment(appState)
                .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 680)
        }
        .onChange(of: store.navigationPath, initial: true) { _, path in
            navigationHistory.record(path: path)
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandNewCourse)) { notification in
            guard notification.object as? CourseExperienceStore === store,
                  store.setupComplete, store.hasCompletedIntro else { return }
            if store.requiresDraftReplacementConfirmation {
                showsCommandDraftReplacementConfirmation = true
            } else {
                store.beginNewCourse()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandShowLibrary)) { notification in
            guard notification.object as? CourseExperienceStore === store,
                  store.setupComplete else { return }
            store.navigationPath.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandShowAppSettings)) { notification in
            guard notification.object as? CourseExperienceStore === store else { return }
            showsDesktopAppSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandNavigateBack)) { notification in
            guard notification.object as? CourseExperienceStore === store else { return }
            navigationHistory.record(path: store.navigationPath)
            if let path = navigationHistory.back() {
                store.navigationPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandNavigateForward)) { notification in
            guard notification.object as? CourseExperienceStore === store else { return }
            navigationHistory.record(path: store.navigationPath)
            if let path = navigationHistory.forward() {
                store.navigationPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .learnfoldCommandSelectCourse)) { notification in
            guard notification.object as? CourseExperienceStore === store,
                  store.setupComplete,
                  let index = notification.userInfo?["index"] as? Int,
                  store.courses.indices.contains(index) else { return }
            store.navigationPath = [.course(store.courses[index].id)]
        }
        .alert("Start a new course?", isPresented: $showsCommandDraftReplacementConfirmation) {
            Button("Continue Draft") { store.resumeCourseDraft() }
            Button("Discard Draft and Start New", role: .destructive) { store.beginNewCourse() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You already have an unfinished course conversation. Starting a new course will remove that workspace and anything saved in it.")
        }
        #endif
    }

    @ViewBuilder
    private var courseExperience: some View {
        Group {
            if !store.hasCompletedIntro {
                LearnfoldIntroView {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        store.completeIntro()
                    }
                }
                .transition(.opacity)
            } else if store.setupComplete {
                #if targetEnvironment(macCatalyst)
                MacCourseWorkspaceView(
                    store: store,
                    onNewCourse: {
                        if store.requiresDraftReplacementConfirmation {
                            showsCommandDraftReplacementConfirmation = true
                        } else {
                            store.beginNewCourse()
                        }
                    },
                    onOpenAppSettings: { showsDesktopAppSettings = true },
                    onOpenAgentSettings: { showsDesktopAgentSettings = true }
                ) { courseNavigation }
                #else
                courseNavigation
                #endif
            } else {
                CourseAgentSetupView(
                    store: store,
                    onConnectRemoteAgent: onConnectRemoteAgent
                )
            }
        }
    }

    private var courseNavigation: some View {
        NavigationStack(path: $store.navigationPath) {
            CourseHomeView(store: store, onConnectRemoteAgent: onConnectRemoteAgent)
                .navigationDestination(for: CourseRoute.self) { route in
                    CourseRouteDestinationView(route: route, store: store)
                }
        }
        .tint(.blue)
    }
}

struct CourseRouteDestinationView: View {
    let route: CourseRoute
    @Bindable var store: CourseExperienceStore
    @State private var recoveredCourse: LearningCourse?

    var body: some View {
        Group {
            if let recoveredCourse {
                CourseDetailView(
                    course: recoveredCourse,
                    store: store,
                    initialSection: .structure
                )
            } else {
                routeDestination
            }
        }
    }

    @ViewBuilder
    private var routeDestination: some View {
        switch route {
        case .newCourse:
            #if targetEnvironment(macCatalyst)
            CourseChatView(store: store)
                .id(store.draftWorkspaceID(for: nil))
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            #else
            CourseChatView(store: store)
                .id(store.draftWorkspaceID(for: nil))
            #endif
        case .building:
            CourseBuildingView(store: store)
        case .course(let courseID):
            if let course = store.course(withID: courseID) {
                CourseDetailView(course: course, store: store)
            } else {
                missingCourseView
            }
        case .courseFile(let courseID, let relativePath):
            if let course = store.course(withID: courseID),
               let rootURL = store.courseDirectory(for: course) {
                CourseFileViewerView(
                    course: course,
                    relativePath: relativePath,
                    rootURL: rootURL,
                    store: store,
                    onOpenRelativePath: { linkedPath in
                        store.openCourseFile(courseID: courseID, relativePath: linkedPath)
                    },
                    onOpenCourseStructure: { recoveredCourse = course },
                    onReturnToLibrary: returnToLibrary
                )
            } else if let course = store.course(withID: courseID) {
                unavailableView(kind: .file, course: course)
            } else {
                missingCourseView
            }
        case .coursePage(let courseID, let pageID):
            if let course = store.course(withID: courseID), course.workspaceID != nil {
                CoursePageRouteView(
                    course: course,
                    pageID: pageID,
                    store: store,
                    onOpenCourseStructure: { recoveredCourse = course },
                    onReturnToLibrary: returnToLibrary
                )
                #if targetEnvironment(macCatalyst)
                .id(CoursePageRouteCheckID(
                    courseID: course.id,
                    workspaceID: course.workspaceID,
                    pageID: pageID
                ))
                #endif
            } else if let course = store.course(withID: courseID) {
                unavailableView(kind: .page, course: course)
            } else {
                missingCourseView
            }
        }
    }

    private var missingCourseView: some View {
        unavailableView(
            kind: CourseRouteFallbackPolicy.unavailableKind(
                for: route,
                courseExists: false
            ) ?? .course,
            course: nil
        )
    }

    private func unavailableView(
        kind: CourseRouteUnavailableKind,
        course: LearningCourse?
    ) -> some View {
        CourseRouteUnavailableView(
            kind: kind,
            courseTitle: course?.title,
            canOpenCourseStructure: course?.workspaceID != nil,
            onOpenCourseStructure: course.map { course in
                { recoveredCourse = course }
            },
            onReturnToLibrary: returnToLibrary
        )
    }

    private func returnToLibrary() {
        store.navigationPath.removeAll()
    }
}

private struct CoursePageRouteCheckID: Hashable {
    let courseID: String
    let workspaceID: String?
    let pageID: String
}

private struct CoursePageRouteView: View {
    private enum Availability {
        case checking
        case available
        case unavailable
    }

    let course: LearningCourse
    let pageID: String
    @Bindable var store: CourseExperienceStore
    let onOpenCourseStructure: () -> Void
    let onReturnToLibrary: () -> Void
    @State private var availability: Availability = .checking

    private var checkID: CoursePageRouteCheckID {
        CoursePageRouteCheckID(
            courseID: course.id,
            workspaceID: course.workspaceID,
            pageID: pageID
        )
    }

    var body: some View {
        Group {
            switch availability {
            case .checking:
                ProgressView("Checking course page…")
                    .accessibilityIdentifier("course-route-page-checking")
            case .available:
                CoursePageEditorView(course: course, pageID: pageID, store: store)
            case .unavailable:
                CourseRouteUnavailableView(
                    kind: .page,
                    courseTitle: course.title,
                    canOpenCourseStructure: true,
                    onOpenCourseStructure: onOpenCourseStructure,
                    onReturnToLibrary: onReturnToLibrary
                )
            }
        }
        .task(id: checkID) {
            await checkPageAvailability()
        }
    }

    private func checkPageAvailability() async {
        availability = .checking
        do {
            let repository = try await store.documentRepository(for: course)
            _ = try await repository.pageSnapshot(id: pageID)
            guard !Task.isCancelled else { return }
            availability = .available
        } catch {
            guard !Task.isCancelled else { return }
            availability = CourseRouteFallbackPolicy.pageIsUnavailable(after: error)
                ? .unavailable
                : .available
        }
    }
}

#if DEBUG
enum CourseRouteFallbackUITestScenario: String, CaseIterable {
    case missingCourse = "missing-course"
    case missingCoursePage = "missing-course-page"
    case missingCourseFile = "missing-course-file"
    case stalePage = "stale-page"
    case staleFile = "stale-file"

    static let argument = "--ui-test-course-route-fallback"
    static let validCourseID = "ui-route-recovery-course"
    static let workspaceID = "ui-route-recovery-workspace"

    var route: CourseRoute {
        switch self {
        case .missingCourse:
            .course("missing-course")
        case .missingCoursePage:
            .coursePage(courseID: "missing-course", pageID: "missing-page")
        case .missingCourseFile:
            .courseFile(courseID: "missing-course", relativePath: "missing-file.md")
        case .stalePage:
            .coursePage(courseID: Self.validCourseID, pageID: "stale-page")
        case .staleFile:
            .courseFile(courseID: Self.validCourseID, relativePath: "assets/stale-file.md")
        }
    }

    var hasExistingCourse: Bool {
        switch self {
        case .missingCourse, .missingCoursePage, .missingCourseFile:
            false
        case .stalePage, .staleFile:
            true
        }
    }
}

@MainActor
struct CourseRouteFallbackStrictCheckpointRoot: View {
    private enum Destination {
        case unavailable
        case library
        case courseStructure
    }

    let scenario: CourseRouteFallbackUITestScenario
    @State private var destination: Destination = .unavailable

    init(scenario: CourseRouteFallbackUITestScenario) {
        self.scenario = scenario
    }

    var body: some View {
        NavigationStack {
            destinationView
        }
        .tint(.blue)
        .preferredColorScheme(.light)
        .accessibilityIdentifier(
            "course-route-fallback-checkpoint-\(scenario.rawValue)"
        )
        .learnfoldStrictHarnessBoundary(.courseRouteFallback)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch destination {
        case .unavailable:
            CourseRouteUnavailableView(
                kind: unavailableKind,
                courseTitle: scenario.hasExistingCourse ? Self.course.title : nil,
                canOpenCourseStructure: scenario.hasExistingCourse,
                onOpenCourseStructure: scenario.hasExistingCourse
                    ? { destination = .courseStructure }
                    : nil,
                onReturnToLibrary: { destination = .library }
            )
        case .library:
            CourseLibraryContent(
                courses: [Self.course],
                selectedAgentID: "codex",
                resumableDraft: nil,
                onOpenAppSettings: {},
                onOpenAgentSettings: {},
                onOpenCourse: { _ in },
                onResumeDraft: {},
                onNewCourse: {}
            )
            .toolbar(.visible, for: .navigationBar)
        case .courseStructure:
            CourseDetailPresentation(
                course: Self.course,
                selectedSection: .constant(.structure),
                onTalkToCourseAgent: {},
                learnSection: { EmptyView() },
                structureSection: {
                    CourseDetailStructurePresentation(
                        structureError: nil,
                        documentOutline: Self.documentOutline,
                        workspaceSnapshot: nil,
                        onRetry: {},
                        onOpenPage: { _ in },
                        onOpenFile: { _ in }
                    )
                }
            )
        }
    }

    private var unavailableKind: CourseRouteUnavailableKind {
        CourseRouteFallbackPolicy.unavailableKind(
            for: scenario.route,
            courseExists: scenario.hasExistingCourse,
            childExists: false
        ) ?? .course
    }

    private static let course = LearningCourse(
        id: CourseRouteFallbackUITestScenario.validCourseID,
        title: "Route Recovery Course",
        subtitle: "Deterministic route recovery fixture",
        accentHex: "1F6FEB",
        progress: 0.5,
        lessonCount: 1,
        duration: "5 min",
        status: .ready,
        workspaceID: CourseRouteFallbackUITestScenario.workspaceID
    )

    private static let documentOutline: CourseDocumentOutline = {
        let lesson = CourseLearningNode(
            id: "route-recovery-lesson",
            title: "Choose a recovery destination",
            kind: .markdown,
            status: .generated,
            role: .lesson,
            pageID: "route-recovery-lesson"
        )
        let chapter = CourseLearningNode(
            id: "route-recovery-section",
            title: "Route Recovery",
            kind: .folder,
            status: .generated,
            role: .chapter,
            children: [lesson]
        )
        return CourseDocumentOutline(
            rootPageID: "route-recovery-root",
            bootstrapStatus: "ready_for_learning",
            allPages: [chapter],
            learningPages: [chapter]
        )
    }()
}
#endif

private struct CourseAgentCustomProviderButton: View {
    let hasCustomEndpoint: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        hasCustomEndpoint
                            ? "Your API key is configured"
                            : "Use your own API key"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    Text(
                        hasCustomEndpoint
                            ? "Change endpoint, key, or model"
                            : "Add a base URL, API key, and model ID"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("course-agent-custom-provider")
        .accessibilityValue(hasCustomEndpoint ? "connected" : "not-configured")
    }
}

private struct CourseAgentSetupConnectionControls: View {
    let agentID: String
    let connectionState: CourseExperienceStore.AgentConnectionState
    let isAgentAvailable: Bool
    let needsAuthentication: Bool
    let isSigningIn: Bool
    let onConnect: () -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onConnect) {
                HStack(spacing: 10) {
                    if connectionState == .connecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: LitterPlatform.isCatalyst ? "desktopcomputer" : "iphone.and.arrow.forward")
                    }
                    Text(
                        connectionState == .connecting
                            ? "Connecting…"
                            : agentID == CourseAgentProvider.hosted ? "Continue"
                            : agentID == CourseAgentProvider.codex && LitterPlatform.isDirectDistMac ? "Use Mac Codex"
                            : "Connect \(agentID.displayLabel)"
                    )
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("course-agent-connect")
            .disabled(connectionState == .connecting || !isAgentAvailable)

            if agentID == CourseAgentProvider.codex,
               needsAuthentication {
                Button(action: onSignIn) {
                    Label(
                        LitterPlatform.isDirectDistMac ? "Check Codex login again"
                            : isSigningIn ? "Opening ChatGPT sign-in…" : "Sign in again with ChatGPT",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isSigningIn || connectionState == .connecting)
                .accessibilityIdentifier("course-agent-sign-in-again")
            }

            if agentID == CourseAgentProvider.codex,
               needsAuthentication,
               LitterPlatform.isDirectDistMac {
                VStack(spacing: 6) {
                    Text("Sign in to Codex in Terminal, then check your login again.")
                    Text("codex login")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("course-agent-mac-login-instructions")
            }

            Label {
                Text(agentID == CourseAgentProvider.hosted
                    ? "No login needed. Your prompts and sources are sent to Learnfold’s cloud service and an AI model provider to write your course. Daily usage limits apply."
                    : agentID == CourseAgentProvider.codex && LitterPlatform.isDirectDistMac
                        ? "Uses your Mac’s Codex login, skills, and configured tools. Learnfold adds instructions for this course."
                        : "You can change your course agent later in Course Settings.")
                    .accessibilityIdentifier("course-agent-connection-lifecycle")
                    .accessibilityValue(statusValue)
            } icon: {
                Image(systemName: "lock.shield")
            }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if case .failed(let message) = connectionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("course-agent-connection-error")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusValue: String {
        switch connectionState {
        case .idle: "idle"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        }
    }
}

private struct CourseAgentSetupPickerContent: View {
    let agentOptions: [CourseAgentOption]
    let showsUnavailableOptions: Bool
    @Binding var selectedAgentID: String
    let hasCustomEndpoint: Bool
    let onSelectAgent: (String) -> Void
    let onAddServer: () -> Void
    let onOpenCustomProvider: () -> Void
    @State private var showsAgentChoices = false

    private var usesHostedDefault: Bool {
        selectedAgentID == CourseAgentProvider.hosted
            && agentOptions.contains { $0.id == CourseAgentProvider.hosted && $0.available }
    }

    private var showsAllAgents: Bool {
        LitterPlatform.isDirectDistMac || showsAgentChoices || !usesHostedDefault
    }

    private var usesMacCodex: Bool {
        LitterPlatform.isDirectDistMac && selectedAgentID == CourseAgentProvider.codex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 78, height: 78)
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(usesMacCodex ? "Use Codex on this Mac"
                    : usesHostedDefault && !showsAllAgents ? "Ready to start learning" : "Choose your course agent")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-1.1)
                    .accessibilityIdentifier("course-agent-setup-picker")
                    .accessibilityValue(availabilityValue)

                Text(usesMacCodex
                    ? "Learnfold uses your installed Codex with course instructions and editor tools. Choose another agent below if you prefer."
                    : usesHostedDefault && !showsAllAgents
                    ? "Your Hosted course agent is ready. Start with a topic, a question, or a link."
                    : "Choose the agent you'd like to use for your courses. You can change it later.")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(visibleAgentOptions) { choice in
                    CourseAgentChoiceRow(
                        id: choice.id,
                        title: choice.title,
                        subtitle: choice.subtitle,
                        available: choice.available,
                        selected: selectedAgentID == choice.id,
                        onSelect: {
                            selectedAgentID = choice.id
                            onSelectAgent(choice.id)
                        }
                    )
                }
            }

            if !showsAllAgents {
                Button("Change agent") { showsAgentChoices = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("course-agent-change")
            }

            if showsAllAgents {
                Button(action: onAddServer) {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .frame(width: 42, height: 42)
                            .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect Hermes on a server")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(LitterPlatform.isCatalyst
                                ? "Pair with Learnfold Link to use Hermes for your courses."
                                : "Pair with Learnfold Link. Connecting authorizes Hermes to use phone-side tools confined to this course. The shell is read-only until plan approval, read-write afterward, and has no outbound network access.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.07))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("course-agent-add-server")
            }

            if selectedAgentID == CourseAgentProvider.codex, !LitterPlatform.isCatalyst {
                CourseAgentCustomProviderButton(
                    hasCustomEndpoint: hasCustomEndpoint,
                    action: onOpenCustomProvider
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var visibleAgentOptions: [CourseAgentOption] {
        if !showsAllAgents {
            return agentOptions.filter { $0.id == CourseAgentProvider.hosted }
        }
        return showsUnavailableOptions
            ? agentOptions
            : agentOptions.filter(\.available)
    }

    private var availabilityValue: String {
        let availableCount = visibleAgentOptions.filter(\.available).count
        let unavailableCount = visibleAgentOptions.count - availableCount
        return "available=\(availableCount),unavailable=\(unavailableCount)"
    }
}

struct CourseAgentSetupSelectionResolution: Equatable {
    let agentID: String
    let isAutomatic: Bool
}

enum CourseAgentSetupSelectionPolicy {
    static func initialSelection(
        savedAgentID: String?,
        options: [CourseAgentOption],
        preferredAgentID: String,
        preservesUnavailableSavedSelection: Bool = LitterPlatform.isDirectDistMac
    ) -> CourseAgentSetupSelectionResolution {
        if let savedAgentID,
           let savedOption = options.first(where: { $0.id == savedAgentID }),
           savedOption.available || preservesUnavailableSavedSelection {
            return CourseAgentSetupSelectionResolution(
                agentID: savedAgentID,
                isAutomatic: false
            )
        }
        return CourseAgentSetupSelectionResolution(
            agentID: preferredAgentID,
            isAutomatic: true
        )
    }

    static func reconciledSelection(
        currentAgentID: String,
        automaticAgentIDBeforeRefresh: String?,
        hasExplicitUserSelection: Bool,
        preferredAgentID: String
    ) -> String {
        guard !hasExplicitUserSelection,
              currentAgentID == automaticAgentIDBeforeRefresh else {
            return currentAgentID
        }
        return preferredAgentID
    }
}

#if targetEnvironment(macCatalyst)
private struct MacCodexSetupStatusView: View {
    @Bindable private var bootstrap = LocalCodexBootstrap.shared
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if bootstrap.status == .starting {
                    ProgressView()
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                }
                Text(statusTitle)
                    .font(.headline)
            }
            Text(statusDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if bootstrap.status != .starting {
                Button(bootstrap.status == .ready ? "Refresh Mac Codex" : "Try Mac Codex again", action: onRetry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("course-agent-mac-codex-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-agent-mac-codex-status")
        .accessibilityValue(statusValue)
    }

    private var statusTitle: String {
        switch bootstrap.status {
        case .idle: "Checking your installed Codex"
        case .starting: "Starting Mac Codex…"
        case .ready: "Connected to Mac Codex"
        case .failed: "Mac Codex needs attention"
        }
    }

    private var statusDetail: String {
        switch bootstrap.status {
        case .idle, .starting:
            "Looking for Codex installed on this Mac and connecting to its local app-server."
        case .ready:
            "Learnfold uses the login and configuration from your Mac’s Codex installation."
        case .failed(let message):
            "\(message) Install Codex on this Mac and sign in with codex login, then try again."
        }
    }

    private var statusIcon: String {
        switch bootstrap.status {
        case .idle, .starting: "desktopcomputer"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch bootstrap.status {
        case .ready: .green
        case .failed: .orange
        case .idle, .starting: .secondary
        }
    }

    private var statusValue: String {
        switch bootstrap.status {
        case .idle: "idle"
        case .starting: "starting"
        case .ready: "connected"
        case .failed: "failed"
        }
    }
}
#endif

private struct CourseAgentSetupView: View {
    @Environment(AppModel.self) private var appModel
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModelID = ""
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var hasExplicitUserSelection = false
    @State private var isSigningIn = false
    @State private var signInTask: Task<Void, Never>?

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.preferredSetupAgentID)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    CourseAgentSetupPickerContent(
                        // Hermes is connected through the dedicated server CTA
                        // below, not selected as a local course agent here.
                        agentOptions: store.agentOptions.filter {
                            $0.id != "hermes"
                        },
                        showsUnavailableOptions: true,
                        selectedAgentID: $selectedAgent,
                        hasCustomEndpoint: hasCustomEndpoint,
                        onSelectAgent: { _ in
                            hasExplicitUserSelection = true
                        },
                        onAddServer: onConnectRemoteAgent,
                        onOpenCustomProvider: {
                            hasExplicitUserSelection = true
                            showsOpenAICompatibleSetup = true
                        }
                    )

                    #if targetEnvironment(macCatalyst)
                    if LitterPlatform.isDirectDistMac, selectedAgent == CourseAgentProvider.codex {
                        MacCodexSetupStatusView {
                            Task { await store.prepareLocalAgentCatalog(appModel: appModel) }
                        }
                    }
                    #endif

                    CourseAgentSetupConnectionControls(
                        agentID: selectedAgent,
                        connectionState: store.connectionState,
                        isAgentAvailable: store.agentOptions.first(where: {
                            $0.id == selectedAgent
                        })?.available == true,
                        needsAuthentication: store.agentNeedsAuthentication,
                        isSigningIn: isSigningIn,
                        onConnect: {
                            hasExplicitUserSelection = true
                            Task {
                                await store.connectLocalAgent(
                                    appModel: appModel,
                                    agentID: selectedAgent,
                                    modelID: selectedModelID.isEmpty ? nil : selectedModelID
                                )
                            }
                        },
                        onSignIn: signInAndConnectCodex
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 72)
            }
            .safeAreaPadding(.bottom, 16)
        }
        .task {
            // The Foundation Models availability seen during store construction
            // can be stale while the framework finishes initializing. Refresh it
            // before choosing the transient picker selection so the visible
            // default and its availability marker describe the same snapshot.
            store.refreshHostedAvailability()
            store.refreshAppleAvailability()
            selectedModelID = store.selectedModelID ?? ""
            let resolution = CourseAgentSetupSelectionPolicy.initialSelection(
                savedAgentID: store.selectedAgentID,
                options: store.agentOptions,
                preferredAgentID: store.preferredSetupAgentID
            )
            if !hasExplicitUserSelection {
                selectedAgent = resolution.agentID
            }
            let automaticAgentIDBeforeRefresh =
                resolution.isAutomatic && !hasExplicitUserSelection
                    ? selectedAgent
                    : nil
            if CourseAgentProvider.usesAppServer(selectedAgent) {
                await store.prepareLocalAgentCatalog(appModel: appModel)
                selectedAgent = CourseAgentSetupSelectionPolicy.reconciledSelection(
                    currentAgentID: selectedAgent,
                    automaticAgentIDBeforeRefresh: automaticAgentIDBeforeRefresh,
                    hasExplicitUserSelection: hasExplicitUserSelection,
                    preferredAgentID: store.preferredSetupAgentID
                )
            }
        }
        .onChange(of: selectedAgent) { _, agentID in
            guard CourseAgentProvider.usesAppServer(agentID) else { return }
            Task {
                await store.prepareLocalAgentCatalog(appModel: appModel)
            }
        }
        .onChange(of: store.selectedAgentID) { _, agentID in
            guard let agentID,
                  store.agentOptions.first(where: { $0.id == agentID })?.available == true else {
                return
            }
            selectedAgent = agentID
            selectedModelID = store.selectedModelID ?? ""
        }
        .sheet(isPresented: $showsOpenAICompatibleSetup) {
            OpenAICompatibleProviderSheet(initialModelID: selectedModelID) { modelID in
                selectedModelID = modelID
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
            }
            .environment(appModel)
        }
        .onDisappear {
            signInTask?.cancel()
            signInTask = nil
        }
    }

    @MainActor
    private func signInAndConnectCodex() {
        guard !isSigningIn, selectedAgent == CourseAgentProvider.codex else { return }
        if LitterPlatform.isDirectDistMac {
            Task {
                await store.connectLocalAgent(
                    appModel: appModel,
                    agentID: CourseAgentProvider.codex,
                    modelID: selectedModelID.isEmpty ? nil : selectedModelID
                )
            }
            return
        }
        isSigningIn = true
        signInTask = Task { @MainActor in
            defer {
                isSigningIn = false
                signInTask = nil
            }
            do {
                try await appModel.loginLocalChatGPTAccountOnThisDevice()
                guard !Task.isCancelled else { return }
                await store.connectLocalAgent(
                    appModel: appModel,
                    agentID: CourseAgentProvider.codex,
                    modelID: selectedModelID.isEmpty ? nil : selectedModelID
                )
            } catch ChatGPTOAuthError.cancelled {
                store.agentError = "ChatGPT sign-in was cancelled. Your course agent has not changed."
            } catch {
                store.agentError = "ChatGPT sign-in did not finish. Please try again."
            }
        }
    }
}

private struct CourseHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @Bindable var store: CourseExperienceStore
    var onConnectRemoteAgent: () -> Void
    @State private var showsCourseSettings = false
    @State private var showsAppSettings = false
    @State private var showsDraftReplacementConfirmation = false

    var body: some View {
        library
        .toolbar(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if let error = store.starterCourseInstallationError {
                HStack(spacing: 12) {
                    Text(error).font(.footnote)
                    Spacer()
                    Button("Retry") {
                        Task { await store.installStarterCourseIfNeeded() }
                    }
                    .disabled(store.isInstallingStarterCourse)
                }
                .padding()
                .background(.regularMaterial)
                .accessibilityIdentifier("starter-course-installation-retry")
            }
        }
        .sheet(isPresented: $showsCourseSettings) {
            CourseAgentSettingsView(
                store: store,
                onConnectRemoteAgent: onConnectRemoteAgent
            )
                .environment(appModel)
        }
        .sheet(isPresented: $showsAppSettings) {
            SettingsView()
                .environment(appModel)
                .environment(appState)
        }
        .alert(
            "Start a new course?",
            isPresented: $showsDraftReplacementConfirmation
        ) {
            Button("Continue Draft") {
                store.resumeCourseDraft()
            }
            Button("Discard Draft and Start New", role: .destructive) {
                store.beginNewCourse()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You already have an unfinished course conversation. Starting a new course will remove that workspace and anything saved in it."
            )
        }
    }

    @ViewBuilder
    private var library: some View {
        #if targetEnvironment(macCatalyst)
        MacCourseLibraryView(
            courses: store.courses,
            resumableDraft: store.resumableCourseDraft,
            onOpenCourse: { store.navigationPath.append(.course($0)) },
            onResumeDraft: { store.resumeCourseDraft() },
            onNewCourse: requestNewCourse
        )
        #else
        CourseLibraryContent(
            courses: store.courses,
            selectedAgentID: store.selectedAgentID ?? "codex",
            resumableDraft: store.resumableCourseDraft,
            onOpenAppSettings: { showsAppSettings = true },
            onOpenAgentSettings: { showsCourseSettings = true },
            onOpenCourse: { courseID in
                store.navigationPath.append(.course(courseID))
            },
            onResumeDraft: { store.resumeCourseDraft() },
            onNewCourse: requestNewCourse
        )
        #endif
    }

    private func requestNewCourse() {
        if store.requiresDraftReplacementConfirmation {
            showsDraftReplacementConfirmation = true
        } else {
            store.beginNewCourse()
        }
    }
}

private struct CourseLibraryContent: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let courses: [LearningCourse]
    let selectedAgentID: String
    let resumableDraft: CourseDraftResumePresentation?
    let onOpenAppSettings: () -> Void
    let onOpenAgentSettings: () -> Void
    let onOpenCourse: (String) -> Void
    let onResumeDraft: () -> Void
    let onNewCourse: () -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let resumableDraft {
                        CourseDraftResumeCard(
                            presentation: resumableDraft,
                            onResume: onResumeDraft
                        )
                    }

                    if let featured = courses.first {
                        CourseFeaturedCard(course: featured) {
                            onOpenCourse(featured.id)
                        }

                        if courses.count > 1 {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("More Courses")
                                        .font(.title3.weight(.bold))
                                    Spacer()
                                    Text("\(courses.count - 1)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }

                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(Array(courses.dropFirst())) { course in
                                        CourseGridCard(course: course) {
                                            onOpenCourse(course.id)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        CourseLibraryEmptyState()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }

        }
        .navigationTitle("My Courses")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("course-library-root")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("App Settings", systemImage: "gearshape", action: onOpenAppSettings)
                    .accessibilityIdentifier("course-home-app-settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenAgentSettings) {
                    AgentIconView(kind: selectedAgentID, size: 28)
                }
                .accessibilityLabel("Course agent menu")
                .accessibilityIdentifier("course-home-agent-settings")
            }
            ToolbarItem(placement: .bottomBar) {
                Button("New Course", systemImage: "plus", action: onNewCourse)
                    .accessibilityIdentifier("new-course-button")
            }
        }
    }
}

private struct CourseDraftResumeCard: View {
    let presentation: CourseDraftResumePresentation
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.blue.opacity(0.12))
                    Image(
                        systemName: presentation.isAgentWorking
                            ? "ellipsis.message.fill"
                            : "bubble.left.and.text.bubble.right.fill"
                    )
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue course draft")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let courseTitle = presentation.courseTitle {
                        Text(courseTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(presentation.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.blue.opacity(0.18))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continue-course-draft-button")
        .accessibilityValue(presentation.isAgentWorking ? "agent-working" : "saved")
    }
}

private struct CourseLibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 72, height: 72)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(spacing: 6) {
                Text("Your library is ready")
                    .font(.title3.weight(.bold))
                Text("Create a course with your agent. Your courses and learning progress can sync across your devices through iCloud.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 44)
        .background(.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.05))
        }
    }
}

struct CourseAgentSettingsDraft: Equatable {
    var agentID: String
    var modelID: String
    var effortID: String
}

enum CourseAgentSettingsDraftPolicy {
    static func afterSelection(
        proposed: CourseAgentSettingsDraft
    ) -> CourseAgentSettingsDraft {
        proposed
    }

    static func afterCatalogLoad(
        current: CourseAgentSettingsDraft,
        availableAgentIDs: Set<String>
    ) -> CourseAgentSettingsDraft {
        // An unavailable persisted provider is still the truthful saved value.
        // Never move the draft checkmark to an unvalidated fallback.
        current
    }

    @MainActor
    static func afterModelCatalogRefresh(
        current: CourseAgentSettingsDraft,
        models: [ModelInfo],
        usesCustomEndpoint: Bool
    ) -> CourseAgentSettingsDraft {
        guard !usesCustomEndpoint, !models.isEmpty else { return current }
        let selected = models.first {
            modelMatchesSelection($0, current.modelID, runtime: current.agentID)
        }
        guard let model = selected ?? models.first(where: \.isDefault) ?? models.first else {
            return current
        }
        return CourseAgentSettingsDraft(
            agentID: current.agentID,
            modelID: model.id,
            effortID: CourseExperienceStore.normalizedReasoningEffortID(
                current.effortID,
                for: model
            ) ?? model.defaultReasoningEffort.wireValue
        )
    }

    static func afterSave(
        current: CourseAgentSettingsDraft,
        persisted: CourseAgentSettingsDraft,
        didSave: Bool
    ) -> CourseAgentSettingsDraft {
        didSave ? current : persisted
    }
}

private struct CourseCloudSyncStatusSection: View {
    let availability: CourseCloudSyncAvailability
    let workspaceErrors: [String: String]
    let courseTitles: [String: String]
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        Section {
            LabeledContent {
                if isRetrying {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Retrying…")
                    }
                } else {
                    Text(workspaceErrors.isEmpty ? availability.label : "Some changes need attention")
                        .foregroundStyle(workspaceErrors.isEmpty ? availability.tint : .orange)
                }
            } label: {
                Label("Course iCloud Sync", systemImage: "icloud")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("course-cloud-sync-status")
            .accessibilityValue(isRetrying ? "retry" : availability.checkpointValue)

            if isRetrying {
                Text("Checking iCloud without changing local course data…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-cloud-sync-retrying")
            } else if availability.canRetry || !workspaceErrors.isEmpty {
                Button("Retry iCloud Connection", action: onRetry)
                    .accessibilityIdentifier("course-cloud-sync-retry")
            }
            ForEach(workspaceErrors.keys.sorted(), id: \.self) { workspaceID in
                VStack(alignment: .leading, spacing: 4) {
                    Text(courseTitles[workspaceID] ?? "Course waiting to sync")
                        .font(.subheadline.weight(.medium))
                    Text(workspaceErrors[workspaceID] ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("course-cloud-sync-workspace-error")
            }
        } footer: {
            Text(availability.explanation)
        }
    }
}

private struct CourseAgentModelSection: View {
    let agentID: String
    let models: [ModelInfo]
    let isLoading: Bool
    let selectedModel: String
    let refreshFailed: Bool
    let onRefresh: (() -> Void)?
    let onSelect: (ModelInfo) -> Void

    init(
        agentID: String,
        models: [ModelInfo],
        isLoading: Bool,
        selectedModel: String,
        refreshFailed: Bool = false,
        onRefresh: (() -> Void)? = nil,
        onSelect: @escaping (ModelInfo) -> Void
    ) {
        self.agentID = agentID
        self.models = models
        self.isLoading = isLoading
        self.selectedModel = selectedModel
        self.refreshFailed = refreshFailed
        self.onRefresh = onRefresh
        self.onSelect = onSelect
    }

    var body: some View {
        Section {
            if models.isEmpty {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading models…").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("course-settings-model-loading")
                } else {
                    Text("This agent will choose its default model.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("course-settings-model-empty")
                }
            } else {
                ForEach(models, id: \.id) { model in
                    let isSelected = modelMatchesSelection(
                        model,
                        selectedModel,
                        runtime: agentID
                    )
                    Button {
                        onSelect(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(modelPickerDisplayName(model))
                                        .foregroundStyle(.primary)
                                    if model.isDefault {
                                        Text("DEFAULT")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .accessibilityIdentifier(
                                                "course-settings-model-default-badge-\(model.id)"
                                            )
                                    }
                                }
                                if !model.description.isEmpty {
                                    Text(model.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .accessibilityIdentifier("course-settings-model-\(model.id)")
                    .accessibilityValue(isSelected ? "selected" : "not-selected")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            if isLoading && !models.isEmpty {
                HStack {
                    ProgressView()
                    Text("Refreshing models…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("course-settings-model-refreshing")
            }
            if refreshFailed && !isLoading {
                Text(models.isEmpty
                    ? "Couldn’t load the model list. Check the connection and try again."
                    : "Some models could not be refreshed. Choices may be out of date."
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("course-settings-model-refresh-failed")
            }
            if let onRefresh {
                Button(refreshFailed ? "Retry Model Refresh" : "Refresh Models", action: onRefresh)
                    .disabled(isLoading)
                    .accessibilityIdentifier("course-settings-model-refresh-retry")
            }
        } header: {
            Text("Model")
                .accessibilityIdentifier("course-settings-model-state")
                .accessibilityValue(checkpointValue)
        }
    }

    private var checkpointValue: String {
        if isLoading { return "model-loading" }
        if models.isEmpty { return "model-empty" }
        if models.count == 1, models[0].isDefault { return "model-default" }
        return "model-populated"
    }
}

private struct CourseAgentSettingsErrorSection: View {
    let message: String
    let showsCodexRecovery: Bool
    let showsChatGPTSignIn: Bool
    let hasCustomEndpoint: Bool
    let isSigningIn: Bool
    let onSignIn: () -> Void
    let onRetry: () -> Void
    let onOpenProvider: () -> Void

    var body: some View {
        Section {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(message)
                    .accessibilityIdentifier("course-settings-agent-error")
            }
            .foregroundStyle(.red)

            if showsCodexRecovery {
                if showsChatGPTSignIn {
                    Button(action: onSignIn) {
                        Label(
                            LitterPlatform.isDirectDistMac ? "Check Codex login again"
                                : isSigningIn ? "Opening ChatGPT sign-in…" : "Sign in again with ChatGPT",
                            systemImage: "person.crop.circle.badge.checkmark"
                        )
                    }
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("course-settings-codex-sign-in")

                    if LitterPlatform.isDirectDistMac {
                        Text("Sign in in Terminal with codex login, then check your login again.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !LitterPlatform.isCatalyst {
                    Button(action: onOpenProvider) {
                        Label(
                            hasCustomEndpoint ? "Edit your API key and endpoint" : "Use your own API key",
                            systemImage: "key.horizontal"
                        )
                    }
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("course-settings-codex-provider-recovery")
                }

                Button("Try Codex again", action: onRetry)
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("course-settings-codex-retry")
            }
        }
    }
}

private struct CourseAgentSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CourseExperienceStore
    let onConnectRemoteAgent: () -> Void
    @State private var selectedAgent: String
    @State private var selectedModel: String
    @State private var selectedEffort: String
    @State private var showsOpenAICompatibleSetup = false
    @State private var hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var hasStoredAPIKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var configuredProviderModelID = (try? OpenAIApiKeyStore.shared.loadModelID()) ?? ""
    @State private var pendingCodexDraft: CourseAgentSettingsDraft?
    @State private var isSigningIn = false
    @State private var signInTask: Task<Void, Never>?
    @State private var cloudSyncAvailability: CourseCloudSyncAvailability = .missingEntitlement
    @State private var cloudSyncWorkspaceErrors: [String: String] = [:]
    @State private var isRetryingCloudSync = false
    @State private var saveTask: Task<Void, Never>?

    init(
        store: CourseExperienceStore,
        onConnectRemoteAgent: @escaping () -> Void
    ) {
        self.store = store
        self.onConnectRemoteAgent = onConnectRemoteAgent
        _selectedAgent = State(initialValue: store.selectedAgentID ?? "codex")
        _selectedModel = State(initialValue: store.selectedModelID ?? "")
        _selectedEffort = State(initialValue: store.selectedReasoningEffortID ?? "")
    }

    private var models: [ModelInfo] {
        store.presentedModels(for: selectedAgent)
    }

    private var selectedModelInfo: ModelInfo? {
        models.first(where: { $0.id == selectedModel || $0.model == selectedModel })
    }

    private var usesCustomEndpoint: Bool {
        !LitterPlatform.isCatalyst && hasCustomEndpoint && !appModel.prefersLocalChatGPTAuth
    }

    private var connectedHermesServer: AppServerSnapshot? {
        let connectedServers = appModel.snapshot?.servers.filter { server in
            !server.isLocal
                && server.isConnected
                && server.agentRuntimes.contains {
                    $0.kind == "hermes" && $0.available
                }
        } ?? []
        if let selectedServerID = store.selectedAgentServerID,
           let selected = connectedServers.first(where: { $0.serverId == selectedServerID }) {
            return selected
        }
        return connectedServers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                CourseCloudSyncStatusSection(
                    availability: cloudSyncAvailability,
                    workspaceErrors: cloudSyncWorkspaceErrors,
                    courseTitles: Dictionary(store.courses.compactMap { course in
                        course.workspaceID.map { ($0, course.title) }
                    }, uniquingKeysWith: { first, _ in first }),
                    isRetrying: isRetryingCloudSync,
                    onRetry: retryCloudSync
                )

                Section {
                    ForEach(store.agentOptions.filter(\.available)) { option in
                        Button {
                            selectAgent(option)
                        } label: {
                            HStack(spacing: 14) {
                                AgentIconView(kind: option.id, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title).foregroundStyle(.primary)
                                    Text(store.subtitle(for: option))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedAgent == option.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                        .disabled(store.connectionState == .connecting)
                        .accessibilityIdentifier("course-settings-agent-\(option.id)")
                    }
                } header: {
                    Text("Course agent")
                } footer: {
                    Text("Only agents currently available through this device or the selected server are shown.")
                }

                if let error = store.agentError {
                    CourseAgentSettingsErrorSection(
                        message: error,
                        showsCodexRecovery: pendingCodexDraft != nil
                            || store.selectedAgentID == CourseAgentProvider.codex
                            || (store.agentNeedsAuthentication
                                && store.activeAgentID == CourseAgentProvider.codex),
                        showsChatGPTSignIn: store.agentNeedsAuthentication,
                        hasCustomEndpoint: hasCustomEndpoint,
                        isSigningIn: isSigningIn,
                        onSignIn: signInAndRetryCodex,
                        onRetry: retryCodexSelection,
                        onOpenProvider: { showsOpenAICompatibleSetup = true }
                    )
                }

                if !LitterPlatform.isCatalyst {
                    Section {
                        Button {
                            showsOpenAICompatibleSetup = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "key.horizontal")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hasStoredAPIKey ? "Manage your API key" : "Use your own API key")
                                        .foregroundStyle(.primary)
                                    Text(
                                        hasCustomEndpoint && !configuredProviderModelID.isEmpty
                                            ? "Configured for Codex · \(configuredProviderModelID)"
                                            : hasStoredAPIKey
                                                ? "OpenAI API key saved on this iPhone"
                                                : "API key; optional custom URL and model ID"
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityIdentifier("course-settings-byok")
                    } header: {
                        Text("Your provider")
                    } footer: {
                        Text("Uses Codex on this iPhone. Endpoint changes affect existing Codex conversations too.")
                    }
                } else if selectedAgent == CourseAgentProvider.codex {
                    Section("Mac Codex") {
                        Text("Uses the login, skills, tools, and provider configuration from your Mac’s installed Codex. Learnfold adds its own course instructions and editor tools to course conversations.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #if targetEnvironment(macCatalyst)
                        if LitterPlatform.isDirectDistMac {
                            MacCodexSetupStatusView {
                                Task { await store.prepareLocalAgentCatalog(appModel: appModel) }
                            }
                        }
                        #endif
                    }
                }

                if selectedAgent == CourseAgentProvider.codex, usesCustomEndpoint {
                    Section("Model") {
                        LabeledContent(
                            "Your model",
                            value: selectedModel.isEmpty ? "Choose a model ID" : selectedModel
                        )
                        Button("Change model or provider") {
                            showsOpenAICompatibleSetup = true
                        }
                        .accessibilityIdentifier("course-settings-custom-model")
                    }
                } else if CourseAgentProvider.usesAppServer(selectedAgent) {
                    CourseAgentModelSection(
                        agentID: selectedAgent,
                        models: models,
                        isLoading: store.isLoadingAgentCatalog,
                        selectedModel: selectedModel,
                        refreshFailed: store.agentCatalogRefreshFailed,
                        onRefresh: {
                            Task { await refreshPresentedCatalog() }
                        },
                        onSelect: { model in
                            selectedModel = model.id
                            selectedEffort = model.defaultReasoningEffort.wireValue
                        }
                    )
                }

                if !(selectedAgent == CourseAgentProvider.codex && usesCustomEndpoint),
                   let selectedModelInfo,
                   !selectedModelInfo.supportedReasoningEfforts.isEmpty {
                    Section("Reasoning") {
                        Picker("Effort", selection: $selectedEffort) {
                            ForEach(selectedModelInfo.supportedReasoningEfforts) { option in
                                Text(option.reasoningEffort.wireValue.capitalized)
                                    .tag(option.reasoningEffort.wireValue)
                            }
                        }
                    }
                }

                Section {
                    Text("This changes the default for new courses only. Existing courses stay with the agent that created their conversation, so a Hermes course continues with Hermes. An Apple course can switch between On‑Device and Private Cloud Compute from its chat.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if let connectedHermesServer {
                        LabeledContent {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Hermes")
                                Text(connectedHermesServer.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button {
                            cancelSaveAndDismiss()
                            Task { @MainActor in
                                await Task.yield()
                                onConnectRemoteAgent()
                            }
                        } label: {
                            Label("Connect Hermes", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("course-settings-add-server")
                    }
                } header: {
                    Text("Remote agent")
                } footer: {
                    Text(LitterPlatform.isCatalyst
                        ? "Connect a remote Hermes agent for your courses."
                        : "Connecting Hermes authorizes it to use Learnfold’s phone-side course tools for your course turns. The shell is confined to the active course folder, read-only until you approve the course plan and read-write afterward. It cannot access sibling courses or make outbound network connections.")
                }

            }
            .task {
                while !Task.isCancelled {
                    cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
                    cloudSyncWorkspaceErrors = await CourseCloudSyncEngine.shared.workspaceErrors
                    do {
                        try await Task.sleep(for: .seconds(3))
                    } catch {
                        break
                    }
                }
            }
            .navigationTitle("Course Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelSaveAndDismiss() }
                        .accessibilityIdentifier("course-settings-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.connectionState == .connecting ? "Checking…" : "Save") {
                        startSave()
                    }
                    .disabled(store.connectionState == .connecting || saveTask != nil)
                    .accessibilityIdentifier("course-settings-save")
                }
            }
            .task {
                await refreshPresentedCatalog()
                hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
                hasStoredAPIKey = OpenAIApiKeyStore.shared.hasStoredKey
                configuredProviderModelID = (try? OpenAIApiKeyStore.shared.loadModelID()) ?? ""
                if selectedAgent == CourseAgentProvider.codex,
                   usesCustomEndpoint,
                   !configuredProviderModelID.isEmpty {
                    selectedModel = configuredProviderModelID
                    selectedEffort = ""
                }
            }
            .sheet(isPresented: $showsOpenAICompatibleSetup) {
                OpenAICompatibleProviderSheet(
                    initialModelID: selectedAgent == CourseAgentProvider.codex ? selectedModel : ""
                ) { modelID in
                    hasCustomEndpoint = OpenAIApiKeyStore.shared.hasStoredBaseURL
                    hasStoredAPIKey = OpenAIApiKeyStore.shared.hasStoredKey
                    configuredProviderModelID = (try? OpenAIApiKeyStore.shared.loadModelID()) ?? ""
                    if hasStoredAPIKey {
                        selectedAgent = CourseAgentProvider.codex
                        selectedModel = modelID.isEmpty
                            ? store.presentedDefaultModelID(for: CourseAgentProvider.codex) ?? ""
                            : modelID
                        selectedEffort = ""
                    } else if selectedAgent == CourseAgentProvider.codex {
                        selectedModel = store.presentedDefaultModelID(for: CourseAgentProvider.codex) ?? ""
                    }
                    store.agentError = nil
                    pendingCodexDraft = nil
                }
                .environment(appModel)
            }
            .interactiveDismissDisabled(saveTask != nil)
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
                signInTask?.cancel()
                signInTask = nil
            }
        }
    }

    @MainActor
    private func refreshPresentedCatalog() async {
        await store.prepareLocalAgentCatalog(appModel: appModel)
        let availableOptions = store.agentOptions.filter(\.available)
        applyDraft(CourseAgentSettingsDraftPolicy.afterCatalogLoad(
            current: currentDraft,
            availableAgentIDs: Set(availableOptions.map(\.id))
        ))
        guard availableOptions.contains(where: { $0.id == selectedAgent }) else {
            return
        }
        applyDraft(CourseAgentSettingsDraftPolicy.afterModelCatalogRefresh(
            current: currentDraft,
            models: store.presentedModels(for: selectedAgent),
            usesCustomEndpoint: selectedAgent == CourseAgentProvider.codex && usesCustomEndpoint
        ))
    }

    @MainActor
    private func retryCloudSync() {
        guard !isRetryingCloudSync else { return }
        isRetryingCloudSync = true
        Task { @MainActor in
            await CourseCloudSyncEngine.shared.startIfAvailable()
            for workspaceID in cloudSyncWorkspaceErrors.keys {
                store.exportCourseContinuation(workspaceID: workspaceID)
            }
            cloudSyncAvailability = await CourseCloudSyncEngine.shared.availability
            cloudSyncWorkspaceErrors = await CourseCloudSyncEngine.shared.workspaceErrors
            isRetryingCloudSync = false
        }
    }

    @MainActor
    private func startSave() {
        guard saveTask == nil else { return }
        let draft = currentDraft
        pendingCodexDraft = draft.agentID == CourseAgentProvider.codex ? draft : nil
        saveTask = Task { @MainActor in
            let didSave = await store.connectLocalAgent(
                appModel: appModel,
                agentID: draft.agentID,
                modelID: draft.modelID.isEmpty ? nil : draft.modelID,
                reasoningEffortID: draft.effortID.isEmpty ? nil : draft.effortID
            )
            guard !Task.isCancelled else { return }
            saveTask = nil
            if didSave {
                dismiss()
            } else {
                restoreDraftFromPersistedSelection()
            }
        }
    }

    @MainActor
    private func cancelSaveAndDismiss() {
        saveTask?.cancel()
        saveTask = nil
        dismiss()
    }

    private func selectAgent(_ option: CourseAgentOption) {
        store.agentError = nil
        pendingCodexDraft = nil
        let optionModels = store.presentedModels(for: option.id)
        let defaultModel = optionModels.first(where: \.isDefault) ?? optionModels.first
        let proposed = CourseAgentSettingsDraft(
            agentID: option.id,
            modelID: defaultModel?.id ?? "",
            effortID: defaultModel?.defaultReasoningEffort.wireValue ?? ""
        )
        applyDraft(CourseAgentSettingsDraftPolicy.afterSelection(proposed: proposed))
    }

    @MainActor
    private func retryCodexSelection() {
        let draft = pendingCodexDraft ?? currentDraft
        if draft.agentID == CourseAgentProvider.codex {
            applyDraft(draft)
            startSave()
        } else if store.activeAgentID == CourseAgentProvider.codex {
            Task { await store.refreshAgentReadiness(appModel: appModel) }
        }
    }

    @MainActor
    private func signInAndRetryCodex() {
        let draft = pendingCodexDraft ?? currentDraft
        guard !isSigningIn,
              draft.agentID == CourseAgentProvider.codex
                || store.activeAgentID == CourseAgentProvider.codex else { return }
        if LitterPlatform.isDirectDistMac {
            retryCodexSelection()
            return
        }
        isSigningIn = true
        signInTask = Task { @MainActor in
            defer {
                isSigningIn = false
                signInTask = nil
            }
            do {
                try await appModel.loginLocalChatGPTAccountOnThisDevice()
                guard !Task.isCancelled else { return }
                store.agentError = nil
                if draft.agentID == CourseAgentProvider.codex {
                    applyDraft(draft)
                    startSave()
                } else {
                    await store.refreshAgentReadiness(appModel: appModel)
                }
            } catch ChatGPTOAuthError.cancelled {
                store.agentError = "ChatGPT sign-in was cancelled. Your course agent has not changed."
            } catch {
                store.agentError = "ChatGPT sign-in did not finish. Please try again."
            }
        }
    }

    @MainActor
    private func restoreDraftFromPersistedSelection() {
        applyDraft(CourseAgentSettingsDraftPolicy.afterSave(
            current: currentDraft,
            persisted: CourseAgentSettingsDraft(
                agentID: store.selectedAgentID ?? "codex",
                modelID: store.selectedModelID ?? "",
                effortID: store.selectedReasoningEffortID ?? ""
            ),
            didSave: false
        ))
    }

    private var currentDraft: CourseAgentSettingsDraft {
        CourseAgentSettingsDraft(
            agentID: selectedAgent,
            modelID: selectedModel,
            effortID: selectedEffort
        )
    }

    private func applyDraft(_ draft: CourseAgentSettingsDraft) {
        selectedAgent = draft.agentID
        selectedModel = draft.modelID
        selectedEffort = draft.effortID
    }
}

private extension CourseCloudSyncAvailability {
    var checkpointValue: String {
        switch self {
        case .available: "synced"
        case .missingEntitlement: "on-this-device"
        case .noAccount: "sign-in-required"
        case .failed: "needs-attention"
        }
    }

    var label: String {
        switch self {
        case .available: "Synced"
        case .missingEntitlement: "On This Device"
        case .noAccount: "Sign In Required"
        case .failed: "Needs Attention"
        }
    }

    var explanation: String {
        switch self {
        case .available:
            "Generated courses and later edits are synced through your private iCloud database."
        case .missingEntitlement:
            "Courses remain on this device because the Learnfold iCloud container is not enabled in this build."
        case .noAccount:
            "Sign in to iCloud in Settings to sync generated courses."
        case .failed(let message):
            "Course sync paused without changing local data. \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .available: .green
        case .missingEntitlement: .secondary
        case .noAccount, .failed: .orange
        }
    }

    var canRetry: Bool {
        switch self {
        case .noAccount, .failed: true
        case .available, .missingEntitlement: false
        }
    }
}

private struct OpenAICompatibleProviderForm: View {
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var modelID: String
    let hasStoredKey: Bool
    let hasStoredBaseURL: Bool
    let isSaving: Bool
    let errorMessage: String?
    let canSave: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onClearCustomEndpoint: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Base URL (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://provider.example/v1", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("custom-provider-base-url")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("API key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField(
                            hasStoredKey
                                ? "Saved — enter a new key to replace"
                                : "Enter API key",
                            text: $apiKey
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom-provider-api-key")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Model ID (for a custom URL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("For example gpt-oss-120b", text: $modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("custom-provider-model-id")
                    }
                } header: {
                    Text("Connection")
                        .accessibilityIdentifier("custom-provider-form")
                        .accessibilityValue(
                            isSaving ? "saving" : (errorMessage == nil ? "ready" : "error")
                        )
                } footer: {
                    Text("For OpenAI, enter only your API key. For another provider, add its base URL and model ID. These settings are saved on this iPhone.")
                }

                Section {
                    Label("Runs through the on-device Codex agent", systemImage: "iphone.gen3")
                    Label("Course files remain in the app’s local workspace", systemImage: "folder.badge.gearshape")
                    Label("Prompts and selected source content go to your endpoint", systemImage: "arrow.up.forward.app")
                } header: {
                    Text("How it works")
                } footer: {
                    Text("A custom endpoint needs the OpenAI Responses API, streaming, and tool calling. A chat-completions-only endpoint may not work with Codex. Changing the key or endpoint restarts local Codex and affects existing Codex conversations too.")
                }

                if isSaving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Saving provider settings…")
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Saving provider settings…")
                        .accessibilityIdentifier("custom-provider-saving")
                    }
                }

                if hasStoredBaseURL {
                    Section {
                        Button(
                            "Remove custom endpoint",
                            role: .destructive,
                            action: onClearCustomEndpoint
                        )
                        .disabled(isSaving)
                        .accessibilityIdentifier("custom-provider-use-default")
                    }
                }

                if let errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text(errorMessage)
                                .accessibilityIdentifier("custom-provider-error")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Custom Provider")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isSaving)
                        .accessibilityIdentifier("custom-provider-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: onSave)
                        .disabled(!canSave || isSaving)
                        .accessibilityIdentifier("custom-provider-save")
                }
            }
        }
    }
}

private struct OpenAICompatibleProviderSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (String) -> Void

    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var modelID: String
    @State private var hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
    @State private var hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
    @State private var isSaving = false
    @State private var errorMessage: String?

    private struct SavedConfiguration {
        let baseURL: String?
        let apiKey: String?
        let modelID: String?

        static func load() throws -> Self {
            let credentials = OpenAIApiKeyStore.shared
            return Self(
                baseURL: try credentials.loadBaseURL(),
                apiKey: try credentials.load(),
                modelID: try credentials.loadModelID()
            )
        }

        func restore() throws {
            let credentials = OpenAIApiKeyStore.shared
            if let apiKey {
                try credentials.save(apiKey)
            } else {
                try credentials.clear()
            }
            if let baseURL {
                try credentials.saveBaseURL(baseURL)
            } else {
                try credentials.clearBaseURL()
            }
            if let modelID {
                try credentials.saveModelID(modelID)
            } else {
                try credentials.clearModelID()
            }
        }
    }

    init(initialModelID: String, onSaved: @escaping (String) -> Void) {
        self.onSaved = onSaved
        let savedBaseURL = (try? OpenAIApiKeyStore.shared.loadBaseURL()) ?? ""
        _baseURL = State(initialValue: savedBaseURL)
        _modelID = State(
            initialValue: savedBaseURL.isEmpty
                ? ""
                : (try? OpenAIApiKeyStore.shared.loadModelID()) ?? initialModelID
        )
    }

    var body: some View {
        OpenAICompatibleProviderForm(
            baseURL: $baseURL,
            apiKey: $apiKey,
            modelID: $modelID,
            hasStoredKey: hasStoredKey,
            hasStoredBaseURL: hasStoredBaseURL,
            isSaving: isSaving,
            errorMessage: errorMessage,
            canSave: canSave,
            onCancel: { dismiss() },
            onSave: { Task { await save() } },
            onClearCustomEndpoint: {
                Task { await clearCustomEndpoint() }
            }
        )
    }

    private var canSave: Bool {
        let hasKey = hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBaseURL.isEmpty {
            return hasKey && trimmedModelID.isEmpty
        }
        return hasKey
            && OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL) != nil
            && OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) != nil
    }

    @MainActor
    private func save() async {
        let normalizedBaseURL: String?
        let normalizedModelID: String?
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Add a base URL for a custom model, or leave both fields blank for OpenAI."
                return
            }
            normalizedBaseURL = nil
            normalizedModelID = nil
        } else {
            guard let baseURL = OpenAICompatibleProviderConfiguration.normalizedBaseURL(baseURL),
                  let modelID = OpenAICompatibleProviderConfiguration.normalizedModelID(modelID) else {
                errorMessage = "Enter a valid http or https base URL and a model ID."
                return
            }
            normalizedBaseURL = baseURL
            normalizedModelID = modelID
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasStoredKey || !trimmedKey.isEmpty else {
            errorMessage = "Enter an API key. For a local endpoint that ignores authentication, use the placeholder key it recommends."
            return
        }

        isSaving = true
        defer { isSaving = false }
        var previousConfiguration: SavedConfiguration?
        let previousAuthPreference = appModel.localAuthPreference
        do {
            errorMessage = nil
            previousConfiguration = try SavedConfiguration.load()
            #if DEBUG
            switch LF05LiveAcceptanceControl.current() {
            case .saving:
                try await Task.sleep(
                    nanoseconds: LF05LiveAcceptanceControl
                        .savingDelayNanoseconds
                )
            case .error:
                throw LF05LiveAcceptanceError()
            case nil:
                break
            }
            #endif
            if !trimmedKey.isEmpty {
                try OpenAIApiKeyStore.shared.save(trimmedKey)
            }
            if let normalizedBaseURL {
                try OpenAIApiKeyStore.shared.saveBaseURL(normalizedBaseURL)
            } else {
                try OpenAIApiKeyStore.shared.clearBaseURL()
            }
            if let normalizedModelID {
                try OpenAIApiKeyStore.shared.saveModelID(normalizedModelID)
            } else {
                try OpenAIApiKeyStore.shared.clearModelID()
            }
            appModel.setLocalAuthPreference(.apiKey)
            try await appModel.restartLocalServer()
            hasStoredKey = OpenAIApiKeyStore.shared.hasStoredKey
            hasStoredBaseURL = OpenAIApiKeyStore.shared.hasStoredBaseURL
            onSaved(normalizedModelID ?? "")
            dismiss()
        } catch {
            if let previousConfiguration {
                do {
                    try previousConfiguration.restore()
                    appModel.setLocalAuthPreference(previousAuthPreference)
                    try await appModel.restartLocalServer()
                } catch {
                    errorMessage = "Provider settings could not be restored. Check the saved key and endpoint before retrying."
                    return
                }
            }
            errorMessage = "The provider could not be saved. Your previous settings were restored; try again."
        }
    }

    @MainActor
    private func clearCustomEndpoint() async {
        isSaving = true
        defer { isSaving = false }
        var previousConfiguration: SavedConfiguration?
        do {
            errorMessage = nil
            previousConfiguration = try SavedConfiguration.load()
            try OpenAIApiKeyStore.shared.clearBaseURL()
            try OpenAIApiKeyStore.shared.clearModelID()
            try await appModel.restartLocalServer()
            hasStoredBaseURL = false
            onSaved("")
            dismiss()
        } catch {
            if let previousConfiguration {
                do {
                    try previousConfiguration.restore()
                    try await appModel.restartLocalServer()
                } catch {
                    errorMessage = "The previous endpoint could not be restored. Check provider settings before retrying."
                    return
                }
            }
            errorMessage = "The custom endpoint could not be removed. Your previous settings were restored; try again."
        }
    }
}

private struct CourseFeaturedCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTINUE LEARNING")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.85))
                Text(course.title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    ProgressView(value: course.progress)
                        .tint(.white)
                        .frame(maxWidth: 130)
                    Text("\(Int(course.progress * 100))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 46, height: 46)
                        .background(.white, in: Circle())
                }
            }
            .padding(19)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .bottomLeading)
            .background {
                CourseArtwork(
                    course: course,
                    symbolAlignment: .topTrailing,
                    symbolPadding: 24
                )
                .overlay {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.88)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(course.title)
        .accessibilityValue("\(Int(course.progress * 100))% complete")
        .accessibilityHint("Opens this course")
    }
}

private struct CourseGridCard: View {
    let course: LearningCourse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                CourseArtwork(course: course)
                    .frame(maxWidth: .infinity)
                    .frame(height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(course.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(course.lessonCount == 1 ? "1 lesson" : "\(course.lessonCount) lessons", systemImage: "rectangle.stack")
                        if !course.duration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(course.duration)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }
}

private struct CourseArtwork: View {
    let title: String
    let accentHex: String
    let symbolAlignment: Alignment
    let symbolPadding: CGFloat

    init(
        course: LearningCourse,
        symbolAlignment: Alignment = .center,
        symbolPadding: CGFloat = 0
    ) {
        title = course.title
        accentHex = course.accentHex
        self.symbolAlignment = symbolAlignment
        self.symbolPadding = symbolPadding
    }

    init(
        title: String,
        accentHex: String,
        symbolAlignment: Alignment = .center,
        symbolPadding: CGFloat = 0
    ) {
        self.title = title
        self.accentHex = accentHex
        self.symbolAlignment = symbolAlignment
        self.symbolPadding = symbolPadding
    }

    var body: some View {
        let accent = Color(hex: accentHex)
        LinearGradient(
            colors: [accent.opacity(0.72), accent, .black.opacity(0.86)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 190, height: 190)
                    .blur(radius: 2)
                    .offset(x: 95, y: -60)

                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 1)
                    .frame(width: 118, height: 118)
                    .offset(x: 82, y: -45)
            }
        }
        .overlay(alignment: symbolAlignment) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                .padding(symbolPadding)
        }
        .accessibilityHidden(true)
    }
}

private enum CourseDetailSection: String, CaseIterable, Identifiable {
    case learn = "Learn"
    case structure = "Structure"

    var id: String { rawValue }
}

private struct CourseDetailPresentation<LearnSection: View, StructureSection: View>: View {
    let course: LearningCourse
    @Binding private var selectedSection: CourseDetailSection
    let onTalkToCourseAgent: () -> Void
    private let progressSummary: String?
    private let readingAction: AnyView?
    private let learnSection: LearnSection
    private let structureSection: StructureSection

    init(
        course: LearningCourse,
        selectedSection: Binding<CourseDetailSection>,
        onTalkToCourseAgent: @escaping () -> Void,
        progressSummary: String? = nil,
        readingAction: AnyView? = nil,
        @ViewBuilder learnSection: () -> LearnSection,
        @ViewBuilder structureSection: () -> StructureSection
    ) {
        self.course = course
        _selectedSection = selectedSection
        self.onTalkToCourseAgent = onTalkToCourseAgent
        self.progressSummary = progressSummary
        self.readingAction = readingAction
        self.learnSection = learnSection()
        self.structureSection = structureSection()
    }

    var body: some View {
        #if targetEnvironment(macCatalyst)
        desktopBody
        #else
        mobileBody
        #endif
    }

    private var desktopBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 18) {
                    CourseArtwork(course: course)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(course.title)
                            .font(.largeTitle.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(progressSummary ?? course.subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("course-progress-summary")
                        HStack(spacing: 12) {
                            Label(course.lessonCount == 1 ? "1 lesson" : "\(course.lessonCount) lessons", systemImage: "doc.text")
                            Label(course.duration, systemImage: "clock")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                if course.workspaceID != nil {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) {
                            if let readingAction { readingAction.frame(maxWidth: 440, alignment: .leading) }
                            Spacer(minLength: 0)
                            desktopAgentButton
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            if let readingAction { readingAction }
                            desktopAgentButton
                        }
                    }

                    Divider()
                    Picker("Course view", selection: $selectedSection) {
                        ForEach(CourseDetailSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .accessibilityIdentifier("course-detail-section-picker")
                    .accessibilityValue(selectedSection.rawValue)
                }

                switch selectedSection {
                case .learn: learnSection
                case .structure: structureSection
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-detail-root")
    }

    private var desktopAgentButton: some View {
        Button(action: onTalkToCourseAgent) {
            Label("Course Discussion", systemImage: "bubble.left.and.bubble.right")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("talk-to-course-agent-button")
    }

    private var mobileBody: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    courseHeader

                    if course.workspaceID != nil {
                        Picker("Course view", selection: $selectedSection) {
                            ForEach(CourseDetailSection.allCases) { section in
                                Text(section.rawValue).tag(section)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("course-detail-section-picker")
                        .accessibilityValue(selectedSection.rawValue)
                    }

                    switch selectedSection {
                    case .learn:
                        learnSection
                    case .structure:
                        structureSection
                    }

                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
        .courseBottomBar {
            if course.workspaceID != nil {
                // Floating glass controls; the safe-area bar supplies the
                // system scroll-edge effect instead of an opaque bar.
                bottomActionBar
            }
        }
        .navigationTitle("Course")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-detail-root")
    }

    private var courseHeader: some View {
        HStack(spacing: 14) {
            CourseArtwork(course: course)
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(progressSummary ?? course.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("course-progress-summary")
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var bottomActionBar: some View {
        GlassMorphContainer(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if let readingAction {
                    readingAction
                } else {
                    Spacer(minLength: 0)
                }
                agentButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var agentButton: some View {
        let button = Button(action: onTalkToCourseAgent) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title3)
                .frame(width: 34, height: 34)
        }
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel("Talk to Course Agent")
        .accessibilityIdentifier("talk-to-course-agent-button")

        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

}

private struct CourseDetailStructurePresentation: View {
    let structureError: String?
    let documentOutline: CourseDocumentOutline?
    let workspaceSnapshot: CourseWorkspaceSnapshot?
    let onRetry: () -> Void
    let onOpenPage: (String) -> Void
    let onOpenFile: (CourseFileNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let structureError {
                CourseStructureLoadFailureView(
                    error: structureError,
                    onRetry: onRetry
                )
            }

            if let documentOutline {
                CoursePageStructureBrowser(
                    nodes: documentOutline.allPages,
                    onOpenPage: onOpenPage
                )
            }

            if let workspaceSnapshot,
               workspaceSnapshot.nodes.contains(where: {
                   $0.relativePath == "sources" || $0.relativePath == "assets"
               }) {
                if documentOutline != nil {
                    Divider()
                }
                CourseStructureBrowser(
                    snapshot: workspaceSnapshot,
                    recommendedFilePath: nil,
                    onOpenFile: onOpenFile
                )
            }

            if documentOutline == nil, workspaceSnapshot == nil, structureError == nil {
                ProgressView("Reading course structure…")
                    .accessibilityIdentifier("course-structure-loading")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 64)
            }
        }
    }
}

private struct CourseDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    @Bindable var store: CourseExperienceStore

    @State private var selectedSection: CourseDetailSection
    @State private var workspaceSnapshot: CourseWorkspaceSnapshot?
    @State private var documentOutline: CourseDocumentOutline?
    @State private var structureErrors = CourseStructureReloadErrors()
    @State private var structureReloadGeneration = 0
    @State private var displayedStructureCourseID: String?
    @State private var displayedStructureWorkspaceID: String?
    @State private var selectedChapterID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var courseAgentNavigationError: String?
    @State private var explorationLauncher = CourseExplorationLauncher()
    #if targetEnvironment(macCatalyst)
    @State private var desktopExpandedNodeIDs: Set<String> = []
    #endif

    init(
        course: LearningCourse,
        store: CourseExperienceStore,
        initialSection: CourseDetailSection = .learn
    ) {
        self.course = course
        self.store = store
        _selectedSection = State(initialValue: initialSection)
    }

    private var chapters: [CourseChapter] {
        if let loaded = store.courseBrief(for: course) {
            return loaded.chapters
        }
        return [
            CourseChapter(id: "visual-map", title: "A visual map of the idea", objective: "See the complete idea first.", deliverables: []),
            CourseChapter(id: "core-intuition", title: "Build the core intuition", objective: "Understand the central concept.", deliverables: []),
            CourseChapter(id: "worked-example", title: "Follow one worked example", objective: "Make the idea concrete.", deliverables: []),
            CourseChapter(id: "practice", title: "Try it yourself", objective: "Practice independently.", deliverables: []),
            CourseChapter(id: "review", title: "Review and extend", objective: "Consolidate and continue.", deliverables: []),
        ]
    }

    private var learningNodes: [CourseLearningNode] {
        let resolved: [CourseLearningNode]
        if let documentOutline, !documentOutline.learningPages.isEmpty {
            resolved = documentOutline.learningPages
        } else if let loaded = store.courseBrief(for: course) {
            resolved = CourseLearningPathResolver.resolve(brief: loaded, snapshot: workspaceSnapshot)
        } else {
            resolved = chapters.map {
                CourseLearningNode(
                    id: $0.id,
                    title: $0.title,
                    kind: .folder,
                    status: .pendingGeneration
                )
            }
        }
        var activeNodeIDs = store.activeExplorationNodeIDs(courseID: course.id)
        if store.backgroundGeneratingCourseID == course.id, let id = store.backgroundGeneratingNodeID {
            activeNodeIDs.insert(id)
        }
        return CourseLearningPathResolver.overlayGeneratingStatus(
            in: resolved,
            targetNodeIDs: activeNodeIDs
        )
    }

    private var isBackgroundGenerationActive: Bool {
        store.backgroundGeneratingCourseID == course.id && store.backgroundGeneratingNodeID != nil
    }

    private var structureReloadID: CourseStructureReloadID {
        CourseStructureReloadID(
            courseID: course.id,
            workspaceID: course.workspaceID,
            workspaceVersion: store.courseWorkspaceRefreshVersion,
            retryGeneration: structureReloadGeneration
        )
    }

    private var structureError: String? {
        structureErrors.combinedMessage
    }

    var body: some View {
        CourseDetailPresentation(
            course: course,
            selectedSection: $selectedSection,
            onTalkToCourseAgent: resumeCourseAgent,
            progressSummary: progressSummary,
            readingAction: readingAction,
            learnSection: { learnSection },
            structureSection: { structureSection }
        )
        .task(id: structureReloadID) {
            await reloadCourseStructure(requestID: structureReloadID)
        }
        .task(id: store.backgroundGeneratingNodeID) {
            guard isBackgroundGenerationActive else { return }
            while !Task.isCancelled, isBackgroundGenerationActive {
                refreshWorkspace()
                try? await Task.sleep(for: .milliseconds(500))
            }
            refreshWorkspace()
        }
        .alert(
            "Couldn’t Open Course Agent",
            isPresented: Binding(
                get: { courseAgentNavigationError != nil },
                set: { isPresented in
                    if !isPresented {
                        courseAgentNavigationError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                courseAgentNavigationError = nil
            }
        } message: {
            Text(courseAgentNavigationError ?? "The course agent is unavailable right now.")
        }
    }

    private var readingAction: AnyView? {
        guard let node = CourseReadingOrder.resume(
            in: learningNodes, bookmark: store.readingBookmark(for: course)
        ) else { return nil }
        let title = if store.readingBookmark(for: course) == nil {
            "Start course"
        } else if CourseExplorationMap.isExploration(node) {
            "Continue exploring"
        } else {
            "Continue course"
        }
        return AnyView(CourseLessonActionButton(
            course: course,
            node: node,
            store: store,
            title: title,
            usesGlass: !LitterPlatform.isCatalyst
        ))
    }

    private var resumeNode: CourseLearningNode? {
        CourseReadingOrder.resume(in: learningNodes, bookmark: store.readingBookmark(for: course))
    }

    private var progressSummary: String {
        let lessons = CourseReadingOrder.lessons(in: learningNodes)
        let ready = lessons.filter { $0.status == .generated }.count
        let explored = CourseExplorationMap.explorations(in: learningNodes).count
        var parts: [String] = []
        // Once the learner explores, the chapter count matters less than
        // how far they wandered; the chapter switcher still shows chapters.
        if explored == 0 {
            parts.append("\(learningNodes.count) \(learningNodes.count == 1 ? "chapter" : "chapters")")
        }
        if !lessons.isEmpty {
            parts.append("\(ready) of \(lessons.count) lessons ready")
        }
        if explored > 0 {
            parts.append("\(explored) explored")
        }
        return parts.joined(separator: " · ")
    }

    private var displayedChapter: (index: Int, node: CourseLearningNode)? {
        let nodes = learningNodes
        guard !nodes.isEmpty else { return nil }
        if let selectedChapterID,
           let index = nodes.firstIndex(where: { $0.id == selectedChapterID }) {
            return (index, nodes[index])
        }
        if let resumeID = resumeNode?.id,
           let index = nodes.firstIndex(where: { CourseLearningPathLayout.contains(resumeID, in: $0) }) {
            return (index, nodes[index])
        }
        return (0, nodes[0])
    }

    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            CourseExplorationOverview(
                nodes: learningNodes,
                resumeNode: resumeNode,
                progress: store.explorationProgress(for: course),
                launcher: explorationLauncher,
                stateOf: { node in
                    store.explorationState(
                        of: node, courseID: course.id, progress: store.explorationProgress(for: course)
                    )
                },
                onOpen: { node in
                    explorationLauncher.open(
                        node, course: course, store: store, appModel: appModel, appState: appState
                    )
                },
                onSynthesize: { anchor, titles in
                    guard let pageID = anchor.pageID else { return }
                    explorationLauncher.launch(
                        CourseExplorationRequest(
                            parentPageID: pageID,
                            parentTitle: anchor.title,
                            direction: .synthesis,
                            exploredTitles: titles
                        ),
                        course: course, store: store, appModel: appModel, appState: appState
                    )
                }
            )

            #if targetEnvironment(macCatalyst)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Course outline").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button(desktopExpandedNodeIDs.isEmpty ? "Expand all" : "Collapse all") {
                        desktopExpandedNodeIDs = desktopExpandedNodeIDs.isEmpty
                            ? Set(allExpandableIDs(in: learningNodes)) : []
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
                }
                CourseLearningTreeView(
                    nodes: learningNodes,
                    expandedNodeIDs: $desktopExpandedNodeIDs,
                    generationDisabled: store.isCourseNodeGenerationDisabled,
                    runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
                    onOpenMarkdown: { store.openCoursePage(courseID: course.id, pageID: $0) },
                    onGenerate: generate
                )
            }
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            #else
            if let chapter = displayedChapter {
                CourseChapterSwitcherCard(
                    chapters: learningNodes,
                    selectedIndex: chapter.index,
                    generationDisabled: store.isCourseNodeGenerationDisabled,
                    runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
                    onSelect: { id in
                        withAnimation(
                            reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.24)
                        ) { selectedChapterID = id }
                    },
                    onGenerate: generate
                )

                if let resume = resumeNode,
                   !CourseLearningPathLayout.contains(resume.id, in: chapter.node) {
                    Button {
                        withAnimation(
                            reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.24)
                        ) { selectedChapterID = nil }
                    } label: {
                        Label("Back to Up next", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Back to Up next, \(resume.title)")
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("course-path-back-to-up-next")
                }

                CourseLessonPathView(
                    chapter: chapter.node,
                    chapterNumber: chapter.index + 1,
                    currentNodeID: resumeNode?.id,
                    explorationProgress: store.explorationProgress(for: course),
                    generationDisabled: store.isCourseNodeGenerationDisabled,
                    runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
                    onOpenMarkdown: { pageID in
                        store.openCoursePage(courseID: course.id, pageID: pageID)
                    },
                    onGenerate: generate
                )
                .id(chapter.node.id)
                .transition(.opacity)
                .environment(\.courseExplorationState) { node in
                    store.explorationState(
                        of: node, courseID: course.id, progress: store.explorationProgress(for: course)
                    )
                }
            }
            #endif

            if store.backgroundGenerationErrorCourseID == course.id,
               let error = store.backgroundGenerationError {
                CourseNodeGenerationErrorView(
                    error: error,
                    onOpenCourseAgent: resumeCourseAgent
                )
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private func allExpandableIDs(in nodes: [CourseLearningNode]) -> [String] {
        nodes.flatMap { node in
            (node.children.isEmpty ? [] : [node.id]) + allExpandableIDs(in: node.children)
        }
    }
    #endif

    private func generate(_ node: CourseLearningNode) {
        // Explorations have their own writers: the course agent stays free,
        // and nothing opens when the page is written.
        if CourseExplorationMap.isExploration(node) {
            explorationLauncher.open(
                node, course: course, store: store, appModel: appModel, appState: appState
            )
            return
        }
        store.generateCourseNodeInBackground(
            for: course,
            node: node,
            appModel: appModel,
            appState: appState
        )
    }

    @ViewBuilder
    private var structureSection: some View {
        CourseDetailStructurePresentation(
            structureError: structureError,
            documentOutline: documentOutline,
            workspaceSnapshot: workspaceSnapshot,
            onRetry: {
                structureErrors = CourseStructureReloadErrors()
                structureReloadGeneration &+= 1
            },
            onOpenPage: { pageID in
                store.openCoursePage(courseID: course.id, pageID: pageID)
            },
            onOpenFile: { node in
                store.openCourseFile(courseID: course.id, relativePath: node.relativePath)
            }
        )
    }

    private func resumeCourseAgent() {
        courseAgentNavigationError = nil
        if case .blocked(let message) = store.resumeCourseAgent(for: course) {
            courseAgentNavigationError = message
        }
    }

    private func loadWorkspaceFiles() -> CourseStructureLoadResult<CourseWorkspaceSnapshot> {
        guard let rootURL = store.courseDirectory(for: course) else {
            return .failed(CourseWorkspaceError.unavailable.localizedDescription)
        }
        do {
            return .loaded(try CourseWorkspaceSnapshot.load(from: rootURL))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func loadDocumentPages() async -> CourseStructureLoadResult<CourseDocumentOutline> {
        do {
            let repository = try await store.documentRepository(for: course)
            return .loaded(try await repository.outline())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func reloadCourseStructure(requestID: CourseStructureReloadID) async {
        guard !Task.isCancelled, requestID == structureReloadID else { return }
        // Keep the current actions mounted during a generation refresh so an
        // in-flight Continue request can finish and open its confirmed page.
        if displayedStructureCourseID != course.id || displayedStructureWorkspaceID != course.workspaceID {
            workspaceSnapshot = nil
            documentOutline = nil
            displayedStructureCourseID = course.id
            displayedStructureWorkspaceID = course.workspaceID
        }
        structureErrors = CourseStructureReloadErrors()
        let result = await CourseStructureReloadCoordinator.reload(
            loadWorkspaceFiles: { loadWorkspaceFiles() },
            loadDocumentPages: { await loadDocumentPages() }
        )
        guard !Task.isCancelled, requestID == structureReloadID else { return }
        workspaceSnapshot = result.workspaceFiles.value
        documentOutline = result.documentPages.value
        structureErrors = result.errors
    }

    private func refreshWorkspace() {
        let result = loadWorkspaceFiles()
        workspaceSnapshot = result.value
        structureErrors.workspaceFiles = result.errorMessage
    }
}

struct CourseStructureReloadID: Hashable {
    let courseID: String
    let workspaceID: String?
    let workspaceVersion: Int
    let retryGeneration: Int
}

enum CourseStructureLoadResult<Value: Sendable>: Sendable {
    case loaded(Value)
    case failed(String)

    var value: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

struct CourseStructureReloadErrors: Equatable, Sendable {
    var workspaceFiles: String?
    var documentPages: String?

    var combinedMessage: String? {
        let messages = [
            workspaceFiles.map { "Source files: \($0)" },
            documentPages.map { "Course pages: \($0)" },
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

struct CourseStructureReloadResult<WorkspaceFiles: Sendable, DocumentPages: Sendable>: Sendable {
    let workspaceFiles: CourseStructureLoadResult<WorkspaceFiles>
    let documentPages: CourseStructureLoadResult<DocumentPages>

    var errors: CourseStructureReloadErrors {
        CourseStructureReloadErrors(
            workspaceFiles: workspaceFiles.errorMessage,
            documentPages: documentPages.errorMessage
        )
    }
}

enum CourseStructureReloadCoordinator {
    @MainActor
    static func reload<WorkspaceFiles: Sendable, DocumentPages: Sendable>(
        loadWorkspaceFiles: @escaping @MainActor @Sendable () async -> CourseStructureLoadResult<WorkspaceFiles>,
        loadDocumentPages: @escaping @MainActor @Sendable () async -> CourseStructureLoadResult<DocumentPages>
    ) async -> CourseStructureReloadResult<WorkspaceFiles, DocumentPages> {
        async let workspaceFiles = loadWorkspaceFiles()
        async let documentPages = loadDocumentPages()
        return await CourseStructureReloadResult(
            workspaceFiles: workspaceFiles,
            documentPages: documentPages
        )
    }
}

struct CourseStructureLoadFailureView: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                "Course structure unavailable",
                systemImage: "folder.badge.questionmark"
            )
        } description: {
            Text(error)
                .accessibilityIdentifier("course-structure-error-message")
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-structure-retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

private struct CourseCompletionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.blue)
            configuration.title
        }
    }
}

private struct CourseAgentChoiceRow: View {
    let id: String
    let title: String
    let subtitle: String
    let available: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button {
            guard available else { return }
            onSelect()
        } label: {
            HStack(spacing: 16) {
                AgentIconView(kind: id, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(available ? Color.primary : Color.secondary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailingStatus
            }
            .padding(16)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? Color.blue : Color.black.opacity(0.06), lineWidth: selected ? 2 : 1)
            }
            .opacity(available ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityIdentifier("course-agent-option-\(id)")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        guard available else { return "unavailable" }
        return selected ? "available-selected" : "available-not-selected"
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if available {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selected ? Color.blue : Color.secondary.opacity(0.5))
        } else {
            Text("Later")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

private struct CourseLearningTreeView: View {
    let nodes: [CourseLearningNode]
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                CourseLearningTreeNodeView(
                    node: node,
                    depth: 0,
                    ordinal: String(index + 1),
                    expandedNodeIDs: $expandedNodeIDs,
                    generationDisabled: generationDisabled,
                    runtimeID: runtimeID,
                    onOpenMarkdown: onOpenMarkdown,
                    onGenerate: onGenerate
                )
                if index < nodes.count - 1 {
                    Divider().padding(.leading, 46)
                }
            }
        }
        // Keep the structural marker as a container.  Applying its identifier
        // to an implicit, combined accessibility element would cause it to
        // replace the identifiers of the node controls it contains.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-learning-tree")
    }
}

private struct CourseLearningTreeNodeView: View {
    let node: CourseLearningNode
    let depth: Int
    let ordinal: String
    @Binding var expandedNodeIDs: Set<String>
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    private var isExpanded: Bool {
        expandedNodeIDs.contains(node.id)
    }

    private var canExpand: Bool {
        #if targetEnvironment(macCatalyst)
        !node.children.isEmpty
        #else
        node.kind == .folder && !node.children.isEmpty
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                #if targetEnvironment(macCatalyst)
                if node.kind != .folder, canExpand {
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            if isExpanded { expandedNodeIDs.remove(node.id) }
                            else { expandedNodeIDs.insert(node.id) }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(isExpanded ? "Hide" : "Show") explorations for \(node.title)")
                    .accessibilityIdentifier("mac-course-branch-\(node.id)")
                }
                #endif
                Button(action: primaryAction) {
                    HStack(spacing: 10) {
                        if node.kind == .folder {
                            Image(systemName: canExpand ? (isExpanded ? "chevron.down" : "chevron.right") : "folder.fill")
                                .font(canExpand ? .caption.weight(.bold) : .body)
                                .foregroundStyle(node.status == .pendingGeneration ? Color.secondary : Color.blue)
                                .frame(width: 24)

                            if canExpand {
                                Image(systemName: "folder.fill")
                                    .font(.body)
                                    .foregroundStyle(.blue)
                            }
                        } else {
                            Image(systemName: "doc.text.fill")
                                .font(.body)
                                .foregroundStyle(node.status == .generated ? Color.blue : Color.secondary)
                                .frame(width: 24)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .font(.system(size: depth == 0 ? 16 : 15, weight: depth == 0 ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if node.kind == .folder, !node.children.isEmpty {
                                Text("\(node.children.count) \(node.children.count == 1 ? "item" : "items")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(node.kind == .markdown && node.status != .generated)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(
                    CourseLearningTreeAccessibilityPolicy.rowIdentifier(for: node)
                )
                .accessibilityLabel(
                    CourseLearningTreeAccessibilityPolicy.rowLabel(
                        for: node,
                        ordinal: ordinal
                    )
                )
                .accessibilityHint(primaryAccessibilityHint)
                .accessibilityValue(node.status.rawValue)

                trailingControl
            }
            .padding(.leading, CGFloat(depth) * 22 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, depth == 0 ? 13 : 11)
            .opacity(node.status == .pendingGeneration ? 0.82 : 1)

            if canExpand, isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                        CourseLearningTreeNodeView(
                            node: child,
                            depth: depth + 1,
                            ordinal: "\(ordinal).\(index + 1)",
                            expandedNodeIDs: $expandedNodeIDs,
                            generationDisabled: generationDisabled,
                            runtimeID: runtimeID,
                            onOpenMarkdown: onOpenMarkdown,
                            onGenerate: onGenerate
                        )
                        if index < node.children.count - 1 {
                            Divider().padding(.leading, CGFloat(depth + 2) * 22 + 34)
                        }
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.16))
                        .frame(width: 2)
                        .padding(.leading, CGFloat(depth + 1) * 22 + 18)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch node.status {
        case .pendingGeneration:
            if let generationRequest = CourseExperienceStore.directGenerationRequest(
                for: node,
                runtimeID: runtimeID
            ) {
                // Explorations have their own writers, so a busy course agent
                // never blocks them.
                let blocked = generationDisabled && !CourseExplorationMap.isExploration(node)
                Button(generationRequest.controlTitle) { onGenerate(node) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityIdentifier(
                        "generate-course-node-\(node.id)"
                    )
                    .accessibilityValue(
                        blocked
                            ? "pending_generation-disabled"
                            : "pending_generation"
                    )
                    .accessibilityLabel(generationRequest.accessibilityLabel)
                    .accessibilityHint(
                        blocked
                            ? "Wait for the current course agent request to finish."
                            : generationRequest.accessibilityHint
                    )
                    .disabled(blocked)
                    .opacity(blocked ? 0.45 : 1)
            } else {
                Text("Pending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            }
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Generating")
            .accessibilityIdentifier(
                "course-node-generation-status-\(node.id)"
            )
            .accessibilityValue(node.status.rawValue)
        case .partiallyGenerated:
            Text("In progress")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.1), in: Capsule())
                .accessibilityIdentifier(
                    "course-node-generation-status-\(node.id)"
                )
                .accessibilityValue(node.status.rawValue)
        case .generated:
            if node.kind == .markdown {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Open \(node.title)")
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Generated")
                    .accessibilityIdentifier(
                        "course-node-generation-status-\(node.id)"
                    )
                    .accessibilityValue(node.status.rawValue)
            }
        }
    }

    private func primaryAction() {
        if node.kind == .folder, canExpand {
            withAnimation(.snappy(duration: 0.24)) {
                if isExpanded {
                    expandedNodeIDs.remove(node.id)
                } else {
                    expandedNodeIDs.insert(node.id)
                }
            }
        } else if node.kind == .markdown,
                  node.status == .generated,
                  let pageID = node.pageID {
            onOpenMarkdown(pageID)
        }
    }

    private var primaryAccessibilityHint: String {
        if canExpand {
            return isExpanded ? "Collapses this section." : "Expands this section."
        }
        if node.kind == .markdown, node.status == .generated {
            return "Opens this editable course page."
        }
        return "This course page is not ready yet."
    }
}

struct CourseNodeGenerationErrorView: View {
    let error: String
    let onOpenCourseAgent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier("course-node-generation-error")

            Button("Open Course Agent", action: onOpenCourseAgent)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                    "course-node-generation-error-open-agent"
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

@MainActor
enum CourseLearningPathLayout {
    struct Section: Equatable {
        let node: CourseLearningNode
        /// "3.2" for a chapter's section, "3.2.1" for a nested one.
        let number: String
        /// 1 for a chapter's direct section, 2 or more for nested sections.
        let depth: Int
        let readyCount: Int
        let lessonCount: Int
    }

    struct Stop: Equatable {
        let node: CourseLearningNode
        /// Zig-zag position, restarted at every section so each begins centered.
        let step: Int
        /// "3.2 · Title" when a one-lesson section is folded into its lesson.
        let eyebrow: String?
        let sectionTitle: String?
        let positionInSection: Int
        let sectionLessonCount: Int
        /// Only the first creatable stop in a section says "Tap to create".
        let showsCreateHint: Bool
    }

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case section(Section)
            /// Lessons that resume a parent after one of its nested sections,
            /// so they don't read as part of the section above them.
            case continuation(String)
            case lesson(Stop)
        }

        let id: String
        let kind: Kind
    }

    static func contains(_ nodeID: String, in node: CourseLearningNode) -> Bool {
        node.id == nodeID || node.children.contains { contains(nodeID, in: $0) }
    }

    /// Flattens one chapter into ordered path entries. Sections stay open so
    /// the path reads as one continuous scroll; depth is carried by numbering
    /// and header weight rather than indentation.
    static func entries(
        for chapter: CourseLearningNode,
        chapterNumber: Int,
        runtimeID: String
    ) -> [Entry] {
        var entries: [Entry] = []

        func appendStops(
            _ leaves: [CourseLearningNode],
            sectionTitle: String?,
            eyebrow: String? = nil
        ) {
            var hintShown = false
            for (index, leaf) in leaves.enumerated() {
                let creatable = leaf.status == .pendingGeneration
                    && CourseExperienceStore.directGenerationRequest(
                        for: leaf,
                        runtimeID: runtimeID
                    ) != nil
                let showsHint = creatable && !hintShown
                if creatable { hintShown = true }
                entries.append(Entry(id: leaf.id, kind: .lesson(Stop(
                    node: leaf,
                    step: index,
                    eyebrow: eyebrow,
                    sectionTitle: sectionTitle,
                    positionInSection: index + 1,
                    sectionLessonCount: leaves.count,
                    showsCreateHint: showsHint
                ))))
            }
        }

        func visit(_ children: [CourseLearningNode], parentTitle: String?, prefix: String, depth: Int) {
            var pendingLeaves: [CourseLearningNode] = []
            var sectionIndex = 0
            func flushLeaves() {
                guard !pendingLeaves.isEmpty else { return }
                if sectionIndex > 0 {
                    let label = parentTitle.map { "\(prefix) \($0), continued" }
                        ?? "More in chapter \(prefix)"
                    entries.append(Entry(
                        id: "continuation-\(prefix)-\(pendingLeaves[0].id)",
                        kind: .continuation(label)
                    ))
                }
                appendStops(pendingLeaves, sectionTitle: parentTitle)
                pendingLeaves = []
            }
            for child in children {
                guard child.kind == .folder else {
                    pendingLeaves.append(child)
                    continue
                }
                flushLeaves()
                sectionIndex += 1
                let number = "\(prefix).\(sectionIndex)"
                // A section holding exactly one lesson reads better as that
                // lesson with a small eyebrow than as a header over one stop.
                if child.children.count == 1, child.children[0].kind != .folder {
                    appendStops(
                        child.children,
                        sectionTitle: child.title,
                        eyebrow: "\(number) · \(child.title)"
                    )
                    continue
                }
                let lessons = CourseReadingOrder.lessons(in: [child])
                entries.append(Entry(id: "section-\(child.id)", kind: .section(Section(
                    node: child,
                    number: number,
                    depth: depth,
                    readyCount: lessons.filter { $0.status == .generated }.count,
                    lessonCount: lessons.count
                ))))
                visit(child.children, parentTitle: child.title, prefix: number, depth: depth + 1)
            }
            flushLeaves()
        }

        visit(chapter.children, parentTitle: nil, prefix: String(chapterNumber), depth: 1)
        return entries
    }

    /// A gentle trail, restarted per section. Flattens at accessibility sizes.
    static func leadingInset(step: Int, isAccessibilitySize: Bool) -> CGFloat {
        guard !isAccessibilitySize else { return 20 }
        // A triangle wave (0, 1, 2, 1, 0, …) keeps every stop on one of three
        // evenly spaced columns, so neighbours never land on uneven offsets.
        let column = [0, 1, 2, 1][step % 4]
        return 24 + CGFloat(column) * 26
    }
}

/// One create style everywhere: a small bordered capsule.
private struct CourseCreateCapsule: View {
    let node: CourseLearningNode
    let request: CourseDirectGenerationRequest
    let generationDisabled: Bool
    let onGenerate: (CourseLearningNode) -> Void

    var body: some View {
        Button("Create", systemImage: "sparkles") { onGenerate(node) }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(generationDisabled)
            .accessibilityIdentifier("generate-course-node-\(node.id)")
            .accessibilityLabel(request.accessibilityLabel)
            .accessibilityHint(
                generationDisabled
                    ? "Wait for the current course agent request to finish."
                    : request.accessibilityHint
            )
            .accessibilityValue(
                generationDisabled ? "pending_generation-disabled" : "pending_generation"
            )
    }
}

private struct CourseChapterSwitcherCard: View {
    let chapters: [CourseLearningNode]
    let selectedIndex: Int
    let generationDisabled: Bool
    let runtimeID: String
    let onSelect: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    private var chapter: CourseLearningNode { chapters[selectedIndex] }

    private static func readiness(of node: CourseLearningNode) -> String {
        let lessons = CourseReadingOrder.lessons(in: [node])
        let ready = lessons.filter { $0.status == .generated }.count
        return "\(ready) of \(lessons.count) ready"
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, node in
                    Button {
                        onSelect(node.id)
                    } label: {
                        Text("\(index + 1). \(node.title)")
                        Text(
                            index == selectedIndex
                                ? "Current · \(Self.readiness(of: node))"
                                : Self.readiness(of: node)
                        )
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selectedIndex + 1). \(chapter.title)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text(Self.readiness(of: chapter))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .tint(.primary)
            .accessibilityIdentifier("course-chapter-switcher")
            .accessibilityLabel(
                "Chapter \(selectedIndex + 1) of \(chapters.count), \(chapter.title), \(Self.readiness(of: chapter))"
            )
            .accessibilityHint("Choose another chapter.")

            if chapter.status == .pendingGeneration,
               let request = CourseExperienceStore.directGenerationRequest(
                   for: chapter,
                   runtimeID: runtimeID
               ) {
                CourseCreateCapsule(
                    node: chapter,
                    request: request,
                    generationDisabled: generationDisabled,
                    onGenerate: onGenerate
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

private struct CourseSectionHeader: View {
    let section: CourseLearningPathLayout.Section
    let isFirst: Bool
    let generationDisabled: Bool
    let runtimeID: String
    let onGenerate: (CourseLearningNode) -> Void

    private var request: CourseDirectGenerationRequest? {
        CourseExperienceStore.directGenerationRequest(for: section.node, runtimeID: runtimeID)
    }

    private var isWriting: Bool {
        section.node.status == .generating
            || section.node.children.contains { $0.status == .generating }
    }

    var body: some View {
        if section.depth == 1 {
            primaryHeader
        } else {
            subsectionHeader
        }
    }

    private var primaryHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                Divider().padding(.bottom, 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(section.number)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(section.node.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(
                "Section \(section.number), \(section.node.title), \(section.readyCount) of \(section.lessonCount) lessons ready"
            )
            HStack(spacing: 8) {
                Group {
                    if section.lessonCount > 0, section.readyCount == section.lessonCount {
                        Label("All \(section.lessonCount) ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("\(section.readyCount) of \(section.lessonCount) ready")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if isWriting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Writing…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if let request {
                    CourseCreateCapsule(
                        node: section.node,
                        request: request,
                        generationDisabled: generationDisabled,
                        onGenerate: onGenerate
                    )
                }
            }
            .padding(.top, 6)
        }
        .padding(.top, isFirst ? 0 : 8)
        .padding(.bottom, 12)
        .padding(.horizontal, 20)
    }

    private var subsectionHeader: some View {
        Text("\(section.number) \(section.node.title)")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 4)
            .padding(.horizontal, 20)
            .contextMenu {
                if let request, !generationDisabled {
                    Button("Create", systemImage: "sparkles") { onGenerate(section.node) }
                        .accessibilityHint(request.accessibilityHint)
                }
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(
                "Section \(section.number), \(section.node.title), \(section.readyCount) of \(section.lessonCount) lessons ready"
            )
            .accessibilityActions {
                if request != nil, !generationDisabled {
                    Button("Create section") { onGenerate(section.node) }
                }
            }
    }
}

private struct CourseLessonPathView: View {
    let chapter: CourseLearningNode
    let chapterNumber: Int
    let currentNodeID: String?
    var explorationProgress = CourseExplorationProgress()
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let entries = CourseLearningPathLayout.entries(
            for: chapter,
            chapterNumber: chapterNumber,
            runtimeID: runtimeID
        )
        ScrollViewReader { proxy in
            pathStack(entries)
                .onAppear {
                    // Bring a far-down "Up next" into view; near the top the
                    // header context matters more than centering.
                    guard let currentNodeID,
                          let index = entries.firstIndex(where: { $0.id == currentNodeID }),
                          index > 3 else { return }
                    DispatchQueue.main.async {
                        if reduceMotion {
                            proxy.scrollTo(currentNodeID, anchor: .center)
                        } else {
                            withAnimation(.snappy) { proxy.scrollTo(currentNodeID, anchor: .center) }
                        }
                    }
                }
        }
    }

    private func pathStack(_ entries: [CourseLearningPathLayout.Entry]) -> some View {
        VStack(spacing: 20) {
            ForEach(entries) { entry in
                switch entry.kind {
                case .section(let section):
                    CourseSectionHeader(
                        section: section,
                        isFirst: entries.first?.id == entry.id,
                        generationDisabled: generationDisabled,
                        runtimeID: runtimeID,
                        onGenerate: onGenerate
                    )
                case .continuation(let label):
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                        .padding(.horizontal, 20)
                        .accessibilityAddTraits(.isHeader)
                case .lesson(let stop):
                    let inset = CourseLearningPathLayout.leadingInset(
                        step: stop.step,
                        isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        CourseLessonPathStop(
                            stop: stop,
                            isCurrent: stop.node.id == currentNodeID,
                            explorationCount: CourseExplorationMap.explorationCount(below: stop.node),
                            generationDisabled: generationDisabled,
                            runtimeID: runtimeID,
                            onOpenMarkdown: onOpenMarkdown,
                            onGenerate: onGenerate
                        )
                        if !stop.node.children.isEmpty {
                            CourseSideTrailList(
                                origin: stop.node,
                                depth: 0,
                                currentNodeID: currentNodeID,
                                progress: explorationProgress,
                                generationDisabled: generationDisabled,
                                runtimeID: runtimeID,
                                onOpenMarkdown: onOpenMarkdown,
                                onGenerate: onGenerate
                            )
                            // Trails sprout from the center of the lesson badge.
                            .padding(.leading, CourseLessonPathStop.badgeCenterOffset - 1)
                        }
                    }
                    .padding(.leading, inset)
                    .padding(.trailing, 20)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-learning-tree")
    }
}

private struct CourseLessonPathStop: View {
    let stop: CourseLearningPathLayout.Stop
    let isCurrent: Bool
    var explorationCount = 0
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    @ScaledMetric(relativeTo: .body) private var scaledBadge: CGFloat = 60
    /// Horizontal center of a default-size badge within its row.
    static let badgeCenterOffset: CGFloat = (60 + 14) / 2

    private var node: CourseLearningNode { stop.node }
    private var badgeSize: CGFloat { min(max(scaledBadge, 60), 72) }

    private var generationRequest: CourseDirectGenerationRequest? {
        CourseExperienceStore.directGenerationRequest(for: node, runtimeID: runtimeID)
    }

    private var isEnabled: Bool {
        switch node.status {
        case .generated: node.pageID != nil
        case .pendingGeneration: generationRequest != nil && !generationDisabled
        case .generating, .partiallyGenerated: false
        }
    }

    private var isWriting: Bool {
        node.status == .generating || node.status == .partiallyGenerated
    }

    private var caption: String? {
        switch node.status {
        case .generated:
            if isCurrent { return "Up next" }
            if let role = node.role, role != .lesson { return role.displayName }
            return nil
        case .pendingGeneration:
            if generationRequest == nil { return "Not started" }
            return stop.showsCreateHint ? "Tap to create" : nil
        case .generating, .partiallyGenerated:
            return "Writing…"
        }
    }

    private var stateDescription: String {
        switch node.status {
        case .generated: isCurrent ? "up next" : "ready"
        case .pendingGeneration: generationRequest == nil ? "not started" : "not created yet"
        case .generating, .partiallyGenerated: "being written"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    if let eyebrow = stop.eyebrow {
                        Text(eyebrow)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(node.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Writing stops stay at full strength; only truly unavailable ones dim.
        .disabled(!isEnabled && !isWriting)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isWriting ? .updatesFrequently : [])
        .accessibilityIdentifier(
            node.status == .pendingGeneration && generationRequest != nil
                ? "generate-course-node-\(node.id)"
                : CourseLearningTreeAccessibilityPolicy.rowIdentifier(for: node)
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            node.status == .pendingGeneration && generationRequest != nil
                ? "Creates this lesson with your course agent."
                : ""
        )
        .accessibilityValue(
            node.status == .pendingGeneration && generationDisabled
                ? "pending_generation-disabled"
                : node.status.rawValue
        )
    }

    private var accessibilityLabel: String {
        var parts = [node.title]
        if explorationCount > 0 {
            parts.append("\(explorationCount) \(explorationCount == 1 ? "exploration" : "explorations")")
        }
        if let section = stop.sectionTitle {
            parts.append("lesson \(stop.positionInSection) of \(stop.sectionLessonCount) in \(section)")
        } else {
            parts.append("lesson \(stop.positionInSection) of \(stop.sectionLessonCount)")
        }
        parts.append(stateDescription)
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var badge: some View {
        let isPendingCreatable = node.status == .pendingGeneration && generationRequest != nil
        ZStack {
            // Every layer shares one center; depth comes from a concentric
            // edge rather than an offset base that reads as misalignment.
            Circle()
                .fill(fill)
                .frame(width: badgeSize, height: badgeSize)
            Circle()
                .strokeBorder(edgeColor, lineWidth: 1)
                .frame(width: badgeSize, height: badgeSize)
            if isPendingCreatable {
                Circle()
                    .strokeBorder(
                        Color.secondary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                    .frame(width: badgeSize, height: badgeSize)
            }
            if isCurrent {
                Circle()
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 4)
                    .frame(width: badgeSize + 12, height: badgeSize + 12)
            }
            switch node.status {
            case .generating, .partiallyGenerated:
                ProgressView()
            default:
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    // The play triangle's visual weight sits left of its box.
                    .offset(x: symbol == "play.fill" ? 2 : 0)
            }
        }
        .frame(width: badgeSize + 14, height: badgeSize + 14)
        .overlay(alignment: .topTrailing) {
            if explorationCount > 0 {
                // How far the learner wandered from this stop.
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(explorationCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.courseExploration, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(uiColor: .systemGroupedBackground), lineWidth: 2))
                .accessibilityHidden(true)
            }
        }
    }

    private var fill: Color {
        switch node.status {
        case .generated: isCurrent ? .accentColor : Color.accentColor.opacity(0.14)
        default: Color(uiColor: .tertiarySystemFill)
        }
    }

    private var edgeColor: Color {
        switch node.status {
        case .generated: isCurrent ? .clear : Color.accentColor.opacity(0.25)
        case .pendingGeneration where generationRequest != nil: .clear
        default: Color(uiColor: .separator)
        }
    }

    private var symbol: String {
        guard node.status == .generated else {
            return generationRequest == nil ? "circle.dotted" : "sparkle"
        }
        if isCurrent { return "play.fill" }
        switch node.role {
        case .explainer: return "lightbulb.fill"
        case .module: return "square.stack.3d.up.fill"
        default: return "book.fill"
        }
    }

    private var symbolColor: Color {
        switch node.status {
        case .generated: isCurrent ? .white : .accentColor
        default: .secondary
        }
    }

    private func action() {
        switch node.status {
        case .generated:
            if let pageID = node.pageID { onOpenMarkdown(pageID) }
        case .pendingGeneration:
            if generationRequest != nil { onGenerate(node) }
        case .generating, .partiallyGenerated:
            break
        }
    }
}

enum CourseLearningTreeAccessibilityPolicy {
    static func rowIdentifier(for node: CourseLearningNode) -> String {
        "course-learning-node-\(node.id)"
    }

    static func rowLabel(for node: CourseLearningNode, ordinal: String) -> String {
        let role = node.role?.displayName ?? (node.kind == .folder ? "Section" : "Page")
        return "\(ordinal), \(role), \(node.title), \(statusLabel(for: node.status))"
    }

    private static func statusLabel(
        for status: CourseLearningNode.GenerationStatus
    ) -> String {
        switch status {
        case .pendingGeneration: "Pending generation"
        case .generating: "Generating"
        case .partiallyGenerated: "Partially generated"
        case .generated: "Ready"
        }
    }
}

#if DEBUG
/// Renders the lesson path for a nested fixture course so nesting, section
/// headers, and every stop state can be inspected without an agent.
struct CourseLearningPathUITestHarnessView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-learning-path")
    }

    @State private var selectedIndex = 0

    private static func lesson(
        _ id: String,
        _ title: String,
        _ status: CourseLearningNode.GenerationStatus = .pendingGeneration,
        role: CourseLearningNode.Role = .lesson
    ) -> CourseLearningNode {
        CourseLearningNode(
            id: id,
            title: title,
            kind: .markdown,
            status: status,
            role: role,
            pageID: status == .generated ? "page-\(id)" : nil
        )
    }

    private static func branch(
        _ id: String,
        _ title: String,
        _ status: CourseLearningNode.GenerationStatus = .pendingGeneration,
        question: String,
        followUps: [CourseLearningNode] = []
    ) -> CourseLearningNode {
        var node = lesson(id, title, status, role: .explainer)
        node.originQuestion = question
        node.children = followUps
        return node
    }

    private static func folder(
        _ id: String,
        _ title: String,
        role: CourseLearningNode.Role,
        _ children: [CourseLearningNode]
    ) -> CourseLearningNode {
        let statuses = Set(children.map(\.status))
        let status: CourseLearningNode.GenerationStatus = statuses == [.generated]
            ? .generated
            : statuses == [.pendingGeneration] ? .pendingGeneration : .partiallyGenerated
        return CourseLearningNode(
            id: id, title: title, kind: .folder, status: status, role: role, children: children
        )
    }

    static let chapters: [CourseLearningNode] = [
        folder("valuation", "Cash-flow valuation and yield measures", role: .chapter, [
            {
                var node = lesson("intro", "Why yields, not prices, are quoted", .generated)
                node.children = [
                    branch("why-bey", "Why bills quote a discount rate", .generated,
                           question: "Why don't bills just quote a yield like notes?",
                           followUps: [
                               branch("bey-history", "A short history of bill quoting", .generated,
                                      question: "When did that convention start?",
                                      followUps: [branch("explore-auction", "How Treasury auctions set the first price", .generated,
                                                         question: "Who decides the price at auction?")]),
                               branch("explore-banks", "Why banks prefer discount instruments", .pendingGeneration,
                                      question: "Who actually buys bills?"),
                           ]),
                    branch("clean-dirty", "Clean versus dirty in practice", .generating,
                           question: "Which price do traders actually see on screen?"),
                    branch("par-yield", "What a par yield really means",
                           question: "Is par yield the same as coupon rate?"),
                ]
                return node
            }(),
            folder("pricing", "Pricing Treasury securities", role: .subchapter, [
                lesson("pv", "Present value of coupon cash flows", .generated),
                lesson("accrued", "Accrued interest and dirty prices", .generated),
                lesson("conventions", "Day-count conventions", .generated, role: .explainer),
            ]),
            folder("yields", "Yield measures", role: .subchapter, [
                lesson("ytm", "Yield to maturity", .generating),
                folder("bey", "Bond-equivalent yields", role: .subchapter, [
                    lesson("bey-bills", "Discount rate versus BEY for bills"),
                    lesson("bey-notes", "Semiannual compounding for notes"),
                ]),
                lesson("worked", "Worked example: a 10-year note", role: .module),
            ]),
            folder("lab", "Pricing lab", role: .subchapter, [
                lesson("lab-1", "Build a pricing spreadsheet", role: .module),
            ]),
        ]),
        folder("risk", "Duration, convexity, and portfolio risk", role: .chapter, [
            folder("duration", "Duration", role: .subchapter, [
                lesson("macaulay", "Macaulay and modified duration"),
                lesson("dv01", "Dollar duration and DV01"),
            ]),
            folder("convexity", "Convexity", role: .subchapter, [
                lesson("second-order", "Second-order price approximation"),
                lesson("hedging", "Hedging with convexity in mind"),
            ]),
        ]),
    ]

    /// `--ui-test-learning-path-in-exploration` puts the learner deep in a trail.
    private static var currentNodeID: String {
        ProcessInfo.processInfo.arguments.contains("--ui-test-learning-path-in-exploration")
            ? "explore-auction" : "accrued"
    }

    private static let progress: CourseExplorationProgress = {
        var progress = CourseExplorationProgress()
        progress.finishedPageIDs = ["page-why-bey"]
        progress.lastVisitedAt["page-why-bey"] = Date(timeIntervalSince1970: 1)
        progress.lastVisitedAt["page-bey-history"] = Date(timeIntervalSince1970: 2)
        progress.pinnedNodeIDs = ["bey-history"]
        return progress
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CourseChapterSwitcherCard(
                    chapters: Self.chapters,
                    selectedIndex: selectedIndex,
                    generationDisabled: false,
                    runtimeID: CourseAgentProvider.codex,
                    onSelect: { id in
                        selectedIndex = Self.chapters.firstIndex { $0.id == id } ?? 0
                    },
                    onGenerate: { _ in }
                )
                CourseLessonPathView(
                    chapter: Self.chapters[selectedIndex],
                    chapterNumber: selectedIndex + 1,
                    currentNodeID: Self.currentNodeID,
                    explorationProgress: Self.progress,
                    generationDisabled: false,
                    runtimeID: CourseAgentProvider.codex,
                    onOpenMarkdown: { _ in },
                    onGenerate: { _ in }
                )
                .id(selectedIndex)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("course-learning-path-harness")
    }
}
#endif

#if DEBUG
struct CourseGenerationControlUITestHarnessView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-generation-control")
    }

    private static var usesAccessibility3XL: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-dynamic-type-ax3xl")
    }

    private static var submissionRecoveryState: CourseAgentSubmissionRecoveryState? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-generation-recovery-acceptance-unknown") {
            return .acceptanceUnknown
        }
        if arguments.contains("--ui-test-generation-recovery-accepted-reply-incomplete") {
            return .acceptedReplyIncomplete
        }
        return nil
    }

    @State private var expandedNodeIDs: Set<String> = [
        "ui-generation-folder",
        "ui-generation-section",
    ]
    @State private var lastRequestedNodeID = "none"
    @State private var lastOpenedPageID = "none"

    private let nodes = [
        CourseLearningNode(
            id: "ui-generation-folder",
            title: "Cellular ageing",
            kind: .folder,
            status: .pendingGeneration,
            role: .chapter,
            pageID: "ui-generation-folder-page",
            children: [
                CourseLearningNode(
                    id: "ui-generation-section",
                    title: "Cell repair mechanisms",
                    kind: .folder,
                    status: .pendingGeneration,
                    role: .subchapter,
                    pageID: "ui-generation-section-page",
                    children: [
                        CourseLearningNode(
                            id: "ui-generation-leaf",
                            title: "Cellular ageing concept map",
                            kind: .markdown,
                            status: .pendingGeneration,
                            role: .explainer,
                            pageID: "ui-generation-leaf-page"
                        ),
                    ]
                ),
            ]
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Course Generation Control Test")
                        .font(.headline)
                        .accessibilityIdentifier("courseGenerationControlHarness.title")

                    CourseLearningTreeView(
                        nodes: nodes,
                        expandedNodeIDs: $expandedNodeIDs,
                        generationDisabled: CourseExperienceStore
                            .shouldDisableCourseNodeGeneration(
                                backgroundGenerationActive: false,
                                mainAgentPhase: .idle,
                                submissionRecoveryState: Self.submissionRecoveryState
                            ),
                        runtimeID: CourseAgentProvider.appleOnDevice,
                        onOpenMarkdown: { pageID in lastOpenedPageID = pageID },
                        onGenerate: { node in lastRequestedNodeID = node.id }
                    )
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 20))

                    Text(lastRequestedNodeID)
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.lastRequestedNodeID"
                        )

                    Text(Self.submissionRecoveryState?.rawValue ?? "none")
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.submissionRecoveryState"
                        )

                    CoursePageStructureBrowser(
                        nodes: nodes,
                        onOpenPage: { pageID in lastOpenedPageID = pageID }
                    )

                    Text(lastOpenedPageID)
                        .font(.caption)
                        .accessibilityIdentifier(
                            "courseGenerationControlHarness.lastOpenedPageID"
                        )

                    Spacer()
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Generate")
        }
        .environment(
            \.dynamicTypeSize,
            Self.usesAccessibility3XL ? .accessibility3 : .large
        )
        .onAppear {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }
    }
}
#endif

enum CourseBuildingProgressCopy {
    static func firstTargetMilestone(for brief: CourseBrief) -> String {
        guard let target = CoursePlanHierarchyPolicy.firstContentLeaf(in: brief) else {
            return "Writing your first learning page"
        }
        return "Writing \(target.role?.displayName ?? "Page"): \(target.title)"
    }

    static func subtitle(agentName: String, brief: CourseBrief) -> String {
        guard let target = CoursePlanHierarchyPolicy.firstContentLeaf(in: brief) else {
            return "\(agentName) is mapping the full course and writing only your first learning page."
        }
        return "\(agentName) is mapping the full course and writing only \(target.title), your first \(target.role?.rawValue ?? "learning page")."
    }
}

enum CourseBuildingMilestoneState: String, Equatable {
    case complete
    case active
    case failed
    case upcoming
}

struct CourseBuildingPresentationSnapshot {
    static let milestoneCount = 5

    let brief: CourseBrief
    let agentName: String
    let generationStep: Int
    let generationError: String?

    var isComplete: Bool {
        generationStep >= Self.milestoneCount && generationError == nil
    }

    var stateIdentifier: String {
        if generationError != nil { return "generation-error" }
        if isComplete { return "completion" }
        return "milestone-\(min(max(generationStep, 0), Self.milestoneCount - 1) + 1)"
    }

    var milestones: [(title: String, systemImage: String)] {
        [
            ("Saving your learner profile", "person.text.rectangle"),
            ("Creating your course map", "point.3.connected.trianglepath.dotted"),
            ("Preparing every chapter folder", "folder.fill.badge.plus"),
            (
                CourseBuildingProgressCopy.firstTargetMilestone(for: brief),
                "text.book.closed.fill"
            ),
            ("Ready to start learning", "sparkles"),
        ]
    }

    func milestoneState(at index: Int) -> CourseBuildingMilestoneState {
        if generationError != nil,
           index == min(max(generationStep, 0), Self.milestoneCount - 1) {
            return .failed
        }
        if index < generationStep { return .complete }
        if index == generationStep { return .active }
        return .upcoming
    }
}

struct CourseBuildingPresentation: View {
    let snapshot: CourseBuildingPresentationSnapshot
    let onOpenCourse: () -> Void
    let onReturnToCourseAgent: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.07, blue: 0.17), Color(red: 0.05, green: 0.16, blue: 0.35)],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text("Building Your Course")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(CourseBuildingProgressCopy.subtitle(
                            agentName: snapshot.agentName,
                            brief: snapshot.brief
                        ))
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    CourseArtwork(title: snapshot.brief.title, accentHex: "1F6FEB")
                        .frame(height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .stroke(.white.opacity(0.15))
                        }
                        .shadow(color: .blue.opacity(0.28), radius: 30, y: 16)

                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.milestones.enumerated()), id: \.offset) { index, milestone in
                            let milestoneState = snapshot.milestoneState(at: index)
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            milestoneState == .complete
                                                ? Color.green
                                                : milestoneState == .failed
                                                    ? Color.red.opacity(0.72)
                                                    : Color.white.opacity(0.1)
                                        )
                                    if milestoneState == .complete {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    } else if milestoneState == .failed {
                                        Image(systemName: "xmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    } else if milestoneState == .active {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: milestone.systemImage)
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                                .frame(width: 34, height: 34)

                                Text(milestone.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(
                                        milestoneState == .upcoming
                                            ? .white.opacity(0.45)
                                            : milestoneState == .failed
                                                ? Color.yellow
                                                : .white
                                    )
                                Spacer()
                            }
                            .padding(.vertical, 13)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("course-building-milestone-\(index + 1)")
                            .accessibilityValue(milestoneState.rawValue)

                            if index < snapshot.milestones.count - 1 {
                                Rectangle()
                                    .fill(.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.leading, 48)
                            }
                        }
                    }
                    .padding(.horizontal, 17)
                    .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR COURSE PATH")
                            .font(.caption2.bold())
                            .tracking(1.3)
                            .foregroundStyle(.white.opacity(0.5))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(Array(snapshot.brief.chapters.enumerated()), id: \.element.id) { index, chapter in
                                    Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                        .frame(width: 44, height: 36)
                                        .background(.white.opacity(index < max(snapshot.generationStep, 1) ? 0.18 : 0.07), in: Capsule())
                                        .accessibilityLabel("Chapter \(index + 1), \(chapter.title)")
                                }
                            }
                        }
                    }

                    if snapshot.isComplete {
                        Button("Open My Course", action: onOpenCourse)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.blue)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .accessibilityIdentifier("course-building-open-course")
                    } else if snapshot.generationError == nil {
                        Text("You can close this screen while generation continues with the app open.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.48))
                    }

                    if let generationError = snapshot.generationError {
                        VStack(spacing: 12) {
                            Label(generationError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("course-building-error")
                            Button("Return to Course Agent", action: onReturnToCourseAgent)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.white.opacity(0.14), in: Capsule())
                                .accessibilityIdentifier("course-building-return-agent")
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 30)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Close course generation")
                .accessibilityIdentifier("course-building-close")

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.07, blue: 0.17),
                        Color(red: 0.035, green: 0.105, blue: 0.24),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeInOut(duration: 0.35), value: snapshot.generationStep)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-building-state")
        .accessibilityValue(snapshot.stateIdentifier)
    }
}

private struct CourseBuildingView: View {
    @Bindable var store: CourseExperienceStore

    var body: some View {
        CourseBuildingPresentation(
            snapshot: CourseBuildingPresentationSnapshot(
                brief: store.brief,
                agentName: store.activeAgentID.displayLabel,
                generationStep: store.generationStep,
                generationError: store.generationError
            ),
            onOpenCourse: store.openGeneratedCourse,
            onReturnToCourseAgent: store.returnToCourseAgent,
            onClose: store.leaveBuildingScreen
        )
    }
}

#if DEBUG
struct CourseGenerationCheckpointUITestHarnessView: View {
    let scenario: CourseGenerationCheckpointScenario

    @State private var displayedScenario: CourseGenerationCheckpointScenario
    @State private var memoryOnlyActionCount = 0
    @State private var actionResult: String?

    init(scenario: CourseGenerationCheckpointScenario) {
        self.scenario = scenario
        _displayedScenario = State(initialValue: scenario)
    }

    var body: some View {
        Group {
            if displayedScenario == .lf40ReturnedAgent {
                CourseGenerationReturnedAgentCheckpointView()
            } else if let snapshot = buildingSnapshot {
                CourseBuildingPresentation(
                    snapshot: snapshot,
                    onOpenCourse: {
                        recordMemoryOnlyAction("Open course action stayed in memory")
                    },
                    onReturnToCourseAgent: {
                        recordMemoryOnlyAction("Returned to the non-live agent receipt")
                        displayedScenario = .lf40ReturnedAgent
                    },
                    onClose: {
                        recordMemoryOnlyAction("Close action stayed in memory")
                    }
                )
            } else {
                CourseNodeGenerationCheckpointView(
                    scenario: displayedScenario,
                    onMemoryOnlyAction: recordMemoryOnlyAction
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            checkpointHeader
        }
        .overlay(alignment: .bottom) {
            if let actionResult {
                Text(actionResult)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.indigo, in: Capsule())
                    .padding(.bottom, 8)
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.memoryOnlyActionResult"
                    )
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("courseGenerationCheckpoint.root")
    }

    private var checkpointHeader: some View {
        VStack(spacing: 3) {
            Text(displayedScenario.nonLiveBoundary)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.indigo)
                .accessibilityIdentifier(
                    "courseGenerationCheckpoint.nonLiveBoundary"
                )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Route · \(displayedScenario.checkpointID)")
                        .accessibilityIdentifier(
                            "courseGenerationCheckpoint.route"
                        )
                        .accessibilityValue(displayedScenario.route)
                    Text("State · \(displayedScenario.substate)")
                        .accessibilityIdentifier(
                            "courseGenerationCheckpoint.state"
                        )
                        .accessibilityValue(displayedScenario.rawValue)
                }
                Spacer(minLength: 4)
                Text("Persistent mutations · 0")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.persistentMutations"
                    )
                    .accessibilityValue(
                        "keychain=0,defaults=0,pasteboard=0,network=0,files=0"
                    )
            }

            HStack(spacing: 8) {
                Text("Hook · \(displayedScenario.hookIdentifier)")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.hook"
                    )
                    .accessibilityValue(displayedScenario.hookIdentifier)
                Spacer(minLength: 4)
                Text("Memory actions · \(memoryOnlyActionCount)")
                    .accessibilityIdentifier(
                        "courseGenerationCheckpoint.memoryOnlyActions"
                    )
                    .accessibilityValue(String(memoryOnlyActionCount))
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
        .background(Color(uiColor: .systemBackground))
    }

    private var buildingSnapshot: CourseBuildingPresentationSnapshot? {
        let step: Int
        let error: String?
        switch displayedScenario {
        case .lf39Milestone1:
            step = 0
            error = nil
        case .lf39Milestone2:
            step = 1
            error = nil
        case .lf39Milestone3:
            step = 2
            error = nil
        case .lf39Milestone4:
            step = 3
            error = nil
        case .lf39Milestone5:
            step = 4
            error = nil
        case .lf40GenerationError:
            step = 3
            error = "The first learning page could not be written. Your course map and conversation are preserved."
        case .lf40ReturnedAgent, .lf44Pending, .lf44Generating,
             .lf44PartialGenerated, .lf44Error:
            return nil
        }
        return CourseBuildingPresentationSnapshot(
            brief: Self.fixtureBrief,
            agentName: "Course Agent",
            generationStep: step,
            generationError: error
        )
    }

    private func recordMemoryOnlyAction(_ result: String) {
        memoryOnlyActionCount += 1
        actionResult = result
    }

    private static let fixtureBrief: CourseBrief = {
        var brief = CourseBrief()
        brief.planID = "lf39-checkpoint-plan"
        brief.revision = 1
        brief.title = "Systems Thinking for Climate Resilience"
        brief.summary = "A practical course from core system models to a local resilience project."
        brief.outcome = "Model a local climate risk and design a defensible intervention."
        brief.startingPoint = "Comfortable with general science and basic charts."
        brief.focusGap = "Feedback loops, uncertainty, and intervention design."
        brief.estimatedDuration = "6 weeks"
        brief.chapters = [
            CourseChapter(
                id: "foundations",
                title: "Systems Foundations",
                objective: "Read causal structure clearly.",
                deliverables: ["Feedback-loop map"]
            ),
            CourseChapter(
                id: "risk",
                title: "Climate Risk",
                objective: "Reason under uncertainty.",
                deliverables: ["Risk model"]
            ),
            CourseChapter(
                id: "intervention",
                title: "Resilient Intervention",
                objective: "Turn analysis into action.",
                deliverables: ["Local intervention brief"]
            ),
        ]
        return brief
    }()
}

private struct CourseGenerationReturnedAgentCheckpointView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Returned to Course Agent", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.blue)

                    Text("Your course request and plan remain available. Adjust the request or ask the agent to try the failed page again.")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("GENERATION RECOVERY")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.secondary)
                        Text("The first learning page could not be written. Your course map and conversation are preserved.")
                            .font(.subheadline)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                    Label(
                        "Frozen component receipt — no runtime, conversation, or persistent course was started.",
                        systemImage: "shield.lefthalf.filled"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("course-building-returned-agent-boundary")
                }
                .padding(20)
            }
            .navigationTitle("Course Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("course-building-returned-agent")
        .accessibilityValue("non-live-receipt")
    }
}

private struct CourseNodeGenerationCheckpointView: View {
    let scenario: CourseGenerationCheckpointScenario
    let onMemoryOnlyAction: (String) -> Void

    @State private var expandedNodeIDs: Set<String> = ["lf44-chapter"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Learning path")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Open any ready lesson. Generate a pending section when you want to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                CourseLearningTreeView(
                    nodes: nodes,
                    expandedNodeIDs: $expandedNodeIDs,
                    generationDisabled: scenario == .lf44Generating,
                    runtimeID: CourseAgentProvider.codex,
                    onOpenMarkdown: { pageID in
                        onMemoryOnlyAction("Opened \(pageID) in memory")
                    },
                    onGenerate: { node in
                        onMemoryOnlyAction("Requested \(node.id) in memory")
                    }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    .background,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )

                if scenario == .lf44Error {
                    CourseNodeGenerationErrorView(
                        error: "The course agent couldn’t generate Feedback Loops. Your existing lessons are unchanged.",
                        onOpenCourseAgent: {
                            onMemoryOnlyAction(
                                "Opened the non-live course-agent recovery receipt"
                            )
                        }
                    )
                }
            }
            .padding(18)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityIdentifier("course-node-generation-checkpoint")
        .accessibilityValue(scenario.substate)
    }

    private var nodes: [CourseLearningNode] {
        let firstLessonStatus: CourseLearningNode.GenerationStatus
        let secondLessonStatus: CourseLearningNode.GenerationStatus
        let chapterStatus: CourseLearningNode.GenerationStatus

        switch scenario {
        case .lf44Generating:
            chapterStatus = .partiallyGenerated
            firstLessonStatus = .generating
            secondLessonStatus = .pendingGeneration
        case .lf44PartialGenerated:
            chapterStatus = .partiallyGenerated
            firstLessonStatus = .generated
            secondLessonStatus = .pendingGeneration
        case .lf44Pending, .lf44Error:
            chapterStatus = .pendingGeneration
            firstLessonStatus = .pendingGeneration
            secondLessonStatus = .pendingGeneration
        case .lf39Milestone1, .lf39Milestone2, .lf39Milestone3,
             .lf39Milestone4, .lf39Milestone5, .lf40GenerationError,
             .lf40ReturnedAgent:
            return []
        }

        return [
            CourseLearningNode(
                id: "lf44-chapter",
                title: "Feedback Loops",
                kind: .folder,
                status: chapterStatus,
                role: .chapter,
                children: [
                    CourseLearningNode(
                        id: "lf44-lesson-ready",
                        title: "Reinforcing and balancing loops",
                        kind: .markdown,
                        status: firstLessonStatus,
                        role: .lesson,
                        relativePath: "chapters/feedback-loops/loops.md",
                        pageID: "lf44-page-ready"
                    ),
                    CourseLearningNode(
                        id: "lf44-lesson-next",
                        title: "Delays and unintended effects",
                        kind: .markdown,
                        status: secondLessonStatus,
                        role: .lesson,
                        relativePath: "chapters/feedback-loops/delays.md",
                        pageID: "lf44-page-next"
                    ),
                ]
            ),
        ]
    }
}

struct ProviderSettingsSourceCheckpointUITestHarnessView: View {
    let scenario: ProviderSettingsSourceCheckpointScenario?

    /// Central strict-root dispatch must use this initializer so the one
    /// authoritative launch parse is injected instead of repeated here.
    init(scenario: ProviderSettingsSourceCheckpointScenario) {
        self.scenario = scenario
    }

    /// Compatibility only for callers that have not migrated to the central
    /// typed strict root. This path is not used by strict-root dispatch.
    init() {
        scenario = ProviderSettingsSourceCheckpointScenario.current()
    }

    var body: some View {
        Group {
            if let scenario {
                ProviderSettingsSourceCheckpointValidHarnessView(
                    scenario: scenario
                )
            } else {
                ProviderSettingsSourceCheckpointConfigurationErrorView()
            }
        }
    }
}

private struct ProviderSettingsSourceCheckpointConfigurationErrorView: View {
    var body: some View {
        ContentUnavailableView {
            Label(
                "Provider checkpoint not configured",
                systemImage: "wrench.and.screwdriver"
            )
        } description: {
            Text(
                "Add exactly one documented LF-03, LF-05, LF-06, LF-27, LF-28, or LF-30 state argument."
            )
        }
        .accessibilityIdentifier(
            "providerSettingsSourceCheckpoint.configurationError"
        )
    }
}

private struct ProviderSettingsSourceCheckpointValidHarnessView: View {
    let scenario: ProviderSettingsSourceCheckpointScenario

    @State private var baseURL = "https://checkpoint.invalid/v1"
    @State private var apiKey = ""
    @State private var modelID = "checkpoint-model"
    @State private var selectedAgentID: String
    @State private var selectedModelID: String
    @State private var selectedEffortID: String
    @State private var didCancel = false
    @State private var didAttemptSave = false
    @State private var didRetry = false
    @State private var memoryOnlyActionCount = 0

    init(scenario: ProviderSettingsSourceCheckpointScenario) {
        self.scenario = scenario
        let initialDraft = switch scenario {
        case .lf27Cancel, .lf27FailureRollback:
            Self.proposedSettings
        default:
            Self.persistedSettings
        }
        _selectedAgentID = State(initialValue: initialDraft.agentID)
        _selectedModelID = State(initialValue: initialDraft.modelID)
        _selectedEffortID = State(initialValue: initialDraft.effortID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if scenario.isSourceCheckpoint {
                    CourseSourceCheckpointUITestHarnessView(
                        scenario: scenario,
                        onMemoryOnlyAction: recordMemoryOnlyAction
                    )
                } else {
                    checkpointContent
                }
            }
            .frame(maxHeight: .infinity)

            checkpointHeader
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providerSettingsSourceCheckpoint.root")
    }

    private var checkpointHeader: some View {
        VStack(spacing: 4) {
            Text(scenario.nonLiveBoundary)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.indigo)
                .accessibilityIdentifier(
                    "providerSettingsSourceCheckpoint.nonLiveBoundary"
                )

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route · \(scenario.checkpointID)")
                        .accessibilityIdentifier(
                            "providerSettingsSourceCheckpoint.route"
                        )
                        .accessibilityValue(
                            ProviderSettingsSourceCheckpointScenario
                                .launchArgument
                        )
                    Text("State · \(scenario.substate)")
                        .accessibilityIdentifier(
                            "providerSettingsSourceCheckpoint.state"
                        )
                        .accessibilityValue(scenario.rawValue)
                }
                Spacer()
                Text("Persistent mutations · 0")
                    .accessibilityIdentifier(
                        "providerSettingsSourceCheckpoint.persistentMutations"
                    )
                    .accessibilityValue(
                        "keychain=0,defaults=0,pasteboard=0,network=0,files=0"
                    )
            }
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)

            if let hookIdentifier = scenario.deterministicHookIdentifier {
                Text("Hook · \(hookIdentifier)")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .accessibilityIdentifier(
                        "providerSettingsSourceCheckpoint.hook"
                    )
                    .accessibilityValue(hookIdentifier)
            }

            Text("Fixture actions · memory only · \(memoryOnlyActionCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityIdentifier(
                    "providerSettingsSourceCheckpoint.memoryOnlyActions"
                )
                .accessibilityValue(String(memoryOnlyActionCount))
        }
        .padding(.bottom, 5)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var checkpointContent: some View {
        switch scenario {
        case .lf03PickerAvailable, .lf03PickerUnavailable:
            setupPickerAvailabilityCheckpoint
        case .lf05Saving, .lf05Error:
            providerFormCheckpoint
        case .lf05SuccessReturn:
            providerSuccessReturnCheckpoint
        case .lf06Connecting, .lf06Failed:
            setupConnectionCheckpoint
        case .lf06ConnectedTarget:
            connectedLibraryCheckpoint
        case .lf27ModelLoading, .lf27ModelEmpty, .lf27ModelDefault,
             .lf27ModelPopulated, .lf27Checking, .lf27Cancel,
             .lf27FailureRollback, .lf27AgentError:
            settingsLifecycleCheckpoint
        case .lf28Synced, .lf28OnThisDevice, .lf28SignInRequired,
             .lf28NeedsAttention, .lf28Retry:
            cloudSyncCheckpoint
        case .lf30SourceMenu, .lf30Preparing, .lf30PassageContext,
             .lf30PermissionError, .lf30ParseError, .lf30PreparationError:
            EmptyView()
        }
    }

    private var setupPickerAvailabilityCheckpoint: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                CourseAgentSetupPickerContent(
                    agentOptions: setupPickerAgentOptions,
                    showsUnavailableOptions:
                        scenario == .lf03PickerUnavailable,
                    selectedAgentID: $selectedAgentID,
                    hasCustomEndpoint: false,
                    onSelectAgent: { _ in recordMemoryOnlyAction() },
                    onAddServer: recordMemoryOnlyAction,
                    onOpenCustomProvider: recordMemoryOnlyAction
                )
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 72)
            }
            .safeAreaPadding(.bottom, 16)
        }
    }

    private var setupPickerAgentOptions: [CourseAgentOption] {
        let appleOptions: [CourseAgentOption]
        if scenario == .lf03PickerUnavailable {
            appleOptions = [
                CourseAgentOption(
                    id: CourseAgentProvider.applePrivateCloud,
                    title: "Apple Private Cloud Compute",
                    available: false,
                    availabilityDescription:
                        "Requires an eligible iPhone and supported region"
                ),
                CourseAgentOption(
                    id: CourseAgentProvider.appleOnDevice,
                    title: "Apple On-Device",
                    available: false,
                    availabilityDescription:
                        "Requires Apple Intelligence on this iPhone"
                ),
            ]
        } else {
            appleOptions = [
                CourseAgentOption(
                    id: CourseAgentProvider.applePrivateCloud,
                    title: "Apple Private Cloud Compute",
                    available: true,
                    availabilityDescription:
                        "Available with Private Cloud Compute"
                ),
                CourseAgentOption(
                    id: CourseAgentProvider.appleOnDevice,
                    title: "Apple On-Device",
                    available: true,
                    availabilityDescription: "Available on this iPhone"
                ),
            ]
        }

        return appleOptions + [
            CourseAgentOption(
                id: CourseAgentProvider.codex,
                title: "Codex",
                available: true,
                availabilityDescription:
                    "Available with the configured provider"
            ),
        ]
    }

    @ViewBuilder
    private var providerFormCheckpoint: some View {
        if didCancel {
            NavigationStack {
                VStack(spacing: 18) {
                    Label(
                        "Provider setup cancelled",
                        systemImage: "xmark.circle"
                    )
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("lf05-cancelled")
                    Text("No provider setting changed.")
                        .foregroundStyle(.secondary)
                    CourseAgentCustomProviderButton(
                        hasCustomEndpoint: false,
                        action: recordMemoryOnlyAction
                    )
                }
                .padding(20)
                .navigationTitle("Choose your course agent")
            }
        } else {
            OpenAICompatibleProviderForm(
                baseURL: $baseURL,
                apiKey: $apiKey,
                modelID: $modelID,
                hasStoredKey: true,
                hasStoredBaseURL: true,
                isSaving: scenario == .lf05Saving,
                errorMessage: scenario == .lf05Error
                    ? "The provider could not be verified. Check the endpoint and try again."
                    : nil,
                canSave: true,
                onCancel: {
                    recordMemoryOnlyAction()
                    didCancel = true
                },
                onSave: recordMemoryOnlyAction,
                onClearCustomEndpoint: recordMemoryOnlyAction
            )
        }
    }

    private var providerSuccessReturnCheckpoint: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(
                        "Provider activated",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("lf05-provider-activated")

                    CourseAgentCustomProviderButton(
                        hasCustomEndpoint: true,
                        action: recordMemoryOnlyAction
                    )

                    CourseAgentSetupConnectionControls(
                        agentID: "codex",
                        connectionState: .idle,
                        isAgentAvailable: true,
                        needsAuthentication: false,
                        isSigningIn: false,
                        onConnect: recordMemoryOnlyAction,
                        onSignIn: recordMemoryOnlyAction
                    )
                }
                .padding(20)
            }
            .navigationTitle("Choose your course agent")
        }
    }

    private var setupConnectionCheckpoint: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose your course agent")
                        .font(.largeTitle.bold())

                    CourseAgentChoiceRow(
                        id: "codex",
                        title: "Codex",
                        subtitle: "Runs on this device with the selected provider",
                        available: true,
                        selected: true,
                        onSelect: recordMemoryOnlyAction
                    )

                    CourseAgentSetupConnectionControls(
                        agentID: "codex",
                        connectionState: setupConnectionState,
                        isAgentAvailable: true,
                        needsAuthentication: false,
                        isSigningIn: false,
                        onConnect: {
                            recordMemoryOnlyAction()
                            didRetry = true
                        },
                        onSignIn: recordMemoryOnlyAction
                    )
                }
                .padding(20)
            }
        }
    }

    private var setupConnectionState: CourseExperienceStore.AgentConnectionState {
        if didRetry { return .connecting }
        switch scenario {
        case .lf06Connecting:
            return .connecting
        case .lf06Failed:
            return .failed(
                "Couldn’t reach the selected provider. Check the connection and try again."
            )
        default:
            return .idle
        }
    }

    private var connectedLibraryCheckpoint: some View {
        NavigationStack {
            CourseLibraryContent(
                courses: [],
                selectedAgentID: "codex",
                resumableDraft: nil,
                onOpenAppSettings: recordMemoryOnlyAction,
                onOpenAgentSettings: recordMemoryOnlyAction,
                onOpenCourse: { _ in recordMemoryOnlyAction() },
                onResumeDraft: recordMemoryOnlyAction,
                onNewCourse: recordMemoryOnlyAction
            )
            .toolbar(.visible, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var settingsLifecycleCheckpoint: some View {
        if scenario == .lf27Cancel, didCancel {
            NavigationStack {
                VStack(spacing: 18) {
                    HStack {
                        Image(systemName: "checkmark.shield")
                            .accessibilityHidden(true)
                        Text("Settings unchanged")
                            .accessibilityIdentifier("lf27-cancel-result")
                    }
                    .font(.title3.weight(.bold))
                    restoredSettingsMarkers
                    CourseLibraryEmptyState()
                }
                .padding(20)
                .navigationTitle("My Courses")
            }
        } else {
            NavigationStack {
                Form {
                    Section("Course agent") {
                        LabeledContent(
                            "Selected",
                            value: selectedAgentID.displayLabel
                        )
                            .accessibilityIdentifier(
                                "lf27-selected-agent"
                            )
                            .accessibilityValue(selectedAgentID)
                    }

                    CourseAgentModelSection(
                        agentID: selectedAgentID,
                        models: settingsModels,
                        isLoading: scenario == .lf27ModelLoading,
                        selectedModel: selectedModelID,
                        onSelect: { model in
                            recordMemoryOnlyAction()
                            selectedModelID = model.id
                            selectedEffortID = model.defaultReasoningEffort.wireValue
                        }
                    )

                    Section("Reasoning") {
                        LabeledContent(
                            "Effort",
                            value: selectedEffortID.capitalized
                        )
                        .accessibilityIdentifier("course-settings-effort")
                        .accessibilityValue(selectedEffortID)
                    }

                    if hasDivergentSettingsDraft {
                        Section {
                            HStack {
                                Image(systemName: "pencil.and.list.clipboard")
                                    .accessibilityHidden(true)
                                Text("Unsaved draft · Fast model · Low effort")
                                    .accessibilityIdentifier("lf27-divergent-draft")
                                    .accessibilityValue(settingsDraftValue)
                            }
                        } footer: {
                            Text("Saved settings remain Codex, Recommended model, Medium effort until Save succeeds.")
                        }
                    }

                    if scenario == .lf27FailureRollback, didAttemptSave {
                        Section {
                            HStack {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .accessibilityHidden(true)
                                Text("Changes weren’t saved. Previous settings restored.")
                                    .accessibilityIdentifier(
                                        "lf27-failure-rollback"
                                    )
                            }
                            .foregroundStyle(.orange)
                            restoredSettingsMarkers
                        }
                    }

                    if scenario == .lf27AgentError {
                        CourseAgentSettingsErrorSection(
                            message: "ChatGPT sign-in could not be verified. Sign in again or try again.",
                            showsCodexRecovery: true,
                            showsChatGPTSignIn: true,
                            hasCustomEndpoint: false,
                            isSigningIn: false,
                            onSignIn: recordMemoryOnlyAction,
                            onRetry: recordMemoryOnlyAction,
                            onOpenProvider: recordMemoryOnlyAction
                        )
                    }
                }
                .navigationTitle("Course Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            recordMemoryOnlyAction()
                            restorePersistedSettings()
                            didCancel = true
                        }
                        .accessibilityIdentifier("course-settings-cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(
                            scenario == .lf27Checking ? "Checking…" : "Save"
                        ) {
                            recordMemoryOnlyAction()
                            if scenario == .lf27FailureRollback {
                                restorePersistedSettings()
                                didAttemptSave = true
                            }
                        }
                        .disabled(scenario == .lf27Checking)
                        .accessibilityIdentifier("course-settings-save")
                    }
                }
                .interactiveDismissDisabled(scenario == .lf27Checking)
                .accessibilityIdentifier("course-settings-checkpoint-form")
                .accessibilityValue(
                    scenario == .lf27Checking ? "checking" : scenario.substate
                )
            }
        }
    }

    private var settingsModels: [ModelInfo] {
        switch scenario {
        case .lf27ModelLoading, .lf27ModelEmpty:
            []
        case .lf27ModelDefault:
            [Self.defaultModel]
        default:
            [Self.defaultModel, Self.secondaryModel]
        }
    }

    private var hasDivergentSettingsDraft: Bool {
        currentSettingsDraft != Self.persistedSettings
    }

    private var currentSettingsDraft: CourseAgentSettingsDraft {
        CourseAgentSettingsDraft(
            agentID: selectedAgentID,
            modelID: selectedModelID,
            effortID: selectedEffortID
        )
    }

    private var settingsDraftValue: String {
        "agent=\(selectedAgentID),model=\(selectedModelID),effort=\(selectedEffortID)"
    }

    private var restoredSettingsMarkers: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(
                "Restored agent",
                value: selectedAgentID.displayLabel
            )
                .accessibilityIdentifier("lf27-restored-agent")
                .accessibilityValue(selectedAgentID)
            LabeledContent(
                "Restored model",
                value: selectedModelID == Self.persistedSettings.modelID
                    ? "Recommended model"
                    : selectedModelID
            )
                .accessibilityIdentifier("lf27-restored-model")
                .accessibilityValue(selectedModelID)
            LabeledContent(
                "Restored effort",
                value: selectedEffortID.capitalized
            )
                .accessibilityIdentifier("lf27-restored-effort")
                .accessibilityValue(selectedEffortID)
        }
    }

    private var cloudSyncCheckpoint: some View {
        NavigationStack {
            Form {
                CourseCloudSyncStatusSection(
                    availability: cloudAvailability,
                    workspaceErrors: [:],
                    courseTitles: [:],
                    isRetrying: scenario == .lf28Retry || didRetry,
                    onRetry: {
                        recordMemoryOnlyAction()
                        didRetry = true
                    }
                )
            }
            .navigationTitle("Course Settings")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("lf28-cloud-status-form")
        }
    }

    private var cloudAvailability: CourseCloudSyncAvailability {
        switch scenario {
        case .lf28Synced:
            .available
        case .lf28OnThisDevice:
            .missingEntitlement
        case .lf28SignInRequired:
            .noAccount
        case .lf28NeedsAttention, .lf28Retry:
            .failed(
                "The iCloud account needs attention. Local courses remain available."
            )
        default:
            .missingEntitlement
        }
    }

    private func recordMemoryOnlyAction() {
        memoryOnlyActionCount += 1
    }

    private func restorePersistedSettings() {
        let restored = CourseAgentSettingsDraftPolicy.afterSave(
            current: currentSettingsDraft,
            persisted: Self.persistedSettings,
            didSave: false
        )
        selectedAgentID = restored.agentID
        selectedModelID = restored.modelID
        selectedEffortID = restored.effortID
    }

    private static let persistedSettings = CourseAgentSettingsDraft(
        agentID: "codex",
        modelID: "checkpoint-default",
        effortID: "medium"
    )

    private static let proposedSettings = CourseAgentSettingsDraft(
        agentID: "codex",
        modelID: "checkpoint-fast",
        effortID: "low"
    )

    private static let defaultModel = ModelInfo(
        id: "checkpoint-default",
        model: "checkpoint-default",
        displayName: "Recommended model",
        description: "Balanced for course creation",
        hidden: false,
        supportedReasoningEfforts: [
            ReasoningEffortOption(
                reasoningEffort: .medium,
                description: "Balanced"
            ),
        ],
        defaultReasoningEffort: .medium,
        inputModalities: [.text],
        isDefault: true,
        agentRuntimeKind: "codex"
    )

    private static let secondaryModel = ModelInfo(
        id: "checkpoint-fast",
        model: "checkpoint-fast",
        displayName: "Fast model",
        description: "Lower latency for short questions",
        hidden: false,
        supportedReasoningEfforts: [
            ReasoningEffortOption(
                reasoningEffort: .low,
                description: "Fast"
            ),
        ],
        defaultReasoningEffort: .low,
        inputModalities: [.text],
        isDefault: false,
        agentRuntimeKind: "codex"
    )
}
#endif
