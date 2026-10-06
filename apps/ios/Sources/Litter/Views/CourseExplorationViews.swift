import SwiftUI

/// Forks explorations and opens existing ones. Forking returns as soon as the
/// placeholder page exists; the store's exploration workers write it, so the
/// learner keeps reading and can fork again right away. Nothing here waits
/// for a page to be written: the learner opens it once it is ready.
@MainActor
@Observable
final class CourseExplorationLauncher {
    var error: String?
    private var openTask: Task<Void, Never>?
    private var forkCount = 0

    var isForking: Bool { forkCount > 0 }

    func launch(
        _ request: CourseExplorationRequest,
        anchor: CourseExplorationAnchor? = nil,
        course: LearningCourse,
        store: CourseExperienceStore,
        appModel: AppModel,
        appState: AppState
    ) {
        Task { @MainActor [weak self] in
            do {
                try await self?.fork(
                    request, anchor: anchor, course: course, store: store, appModel: appModel, appState: appState
                )
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    /// Creates the placeholder page and queues it, for callers that show
    /// their own progress and errors.
    func fork(
        _ request: CourseExplorationRequest,
        anchor: CourseExplorationAnchor? = nil,
        course: LearningCourse,
        store: CourseExperienceStore,
        appModel: AppModel,
        appState: AppState
    ) async throws {
        error = nil
        forkCount += 1
        defer { forkCount -= 1 }
        try await store.startExploration(
            request, anchor: anchor, in: course, appModel: appModel, appState: appState
        )
    }

    /// Opens a written page. An exploration that is not written yet is queued
    /// or retried instead, and it never opens by itself when it finishes.
    func open(
        _ node: CourseLearningNode,
        course: LearningCourse,
        store: CourseExperienceStore,
        appModel: AppModel,
        appState: AppState,
        replacesCurrentPage: Bool = false
    ) {
        error = nil
        let job = store.explorationJob(nodeID: node.id)
        if CourseExplorationMap.isExploration(node), node.status != .generated, job?.phase != .ready {
            if job?.isActive == true { return }
            if job?.failureReason != nil {
                store.retryExploration(nodeID: node.id, appModel: appModel, appState: appState)
                return
            }
            Task { @MainActor [weak self] in
                do {
                    try await store.writeExploration(
                        nodeID: node.id, in: course, appModel: appModel, appState: appState
                    )
                } catch {
                    self?.error = error.localizedDescription
                }
            }
            return
        }
        // The latest tap wins; an earlier open that is still checking the page
        // must not push a second page later.
        openTask?.cancel()
        let origin = store.navigationPath.last
        openTask = Task { @MainActor [weak self] in
            do {
                try await store.openCourseNode(
                    node,
                    in: course,
                    replacesCurrentPage: replacesCurrentPage,
                    appModel: appModel,
                    appState: appState,
                    shouldOpen: { !Task.isCancelled && store.navigationPath.last == origin }
                )
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }
}

/// Why the last fork or open did not happen, next to the control that asked.
struct CourseExplorationForkErrorView: View {
    let launcher: CourseExplorationLauncher

    var body: some View {
        if let error = launcher.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("course-exploration-error")
        }
    }
}

/// The doors at the end of every page: deeper, sideways, wider, or the
/// learner's own question, plus where they already went from here.
struct CourseWhereNextSection: View {
    let exploredFromHere: [CourseLearningNode]
    /// Where each exploration from here stands, and its label while unwritten.
    let stateOf: (CourseLearningNode) -> CourseExplorationState
    let labelOf: (CourseLearningNode) -> String
    let forkParent: CourseLearningNode?
    let isExploration: Bool
    let isPinned: Bool
    let launcher: CourseExplorationLauncher
    let onFork: (CourseExplorationDirection, String?) -> Void
    let onOpen: (CourseLearningNode) -> Void
    let onBack: (CourseLearningNode) -> Void
    let onTogglePin: () -> Void

    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where next?")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 8) {
                ForEach(CourseExplorationDirection.doors, id: \.self) { direction in
                    Button {
                        onFork(direction, nil)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: direction.systemImage)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.courseExploration)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(direction.label)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(direction.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.courseExploration.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(launcher.isForking)
                    .accessibilityHint(direction.detail)
                    .accessibilityIdentifier("course-explore-\(direction.rawValue)")
                }
            }

            HStack(spacing: 8) {
                TextField("Or follow your own question…", text: $question, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($questionFocused)
                    .submitLabel(.go)
                    .onSubmit(submitQuestion)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .accessibilityIdentifier("course-explore-question-field")
                Button(action: submitQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.courseExploration)
                }
                .disabled(trimmedQuestion.isEmpty || launcher.isForking)
                .accessibilityLabel("Explore this question")
                .accessibilityIdentifier("course-explore-question-submit")
            }

            CourseExplorationForkErrorView(launcher: launcher)

            if !exploredFromHere.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already explored from here")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(exploredFromHere) { node in
                        let state = stateOf(node)
                        CourseExplorationRow(
                            node: node,
                            state: state,
                            label: labelOf(node),
                            identifier: "course-explored-\(node.id)",
                            actionIdentifier: "course-explored-\(state == .unwritten ? "write" : "retry")-\(node.id)",
                            onOpen: { onOpen(node) },
                            onWrite: { onOpen(node) }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                if let forkParent {
                    Button {
                        onBack(forkParent)
                    } label: {
                        Label("Back to \(forkParent.title)", systemImage: "arrow.uturn.backward")
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("course-explore-back")
                }
                if isExploration {
                    Button(action: onTogglePin) {
                        Label(isPinned ? "Goal pinned" : "Pin as a goal",
                              systemImage: isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("course-explore-pin")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-where-next")
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitQuestion() {
        guard !trimmedQuestion.isEmpty, !launcher.isForking else { return }
        onFork(.question, trimmedQuestion)
        question = ""
        questionFocused = false
    }
}

/// Orientation for a map with no single path: where the learner is, what they
/// are working toward, and the rabbit holes they left open.
struct CourseExplorationOverview: View {
    let nodes: [CourseLearningNode]
    let resumeNode: CourseLearningNode?
    let progress: CourseExplorationProgress
    let launcher: CourseExplorationLauncher
    /// Where each exploration stands right now.
    let stateOf: (CourseLearningNode) -> CourseExplorationState
    let onOpen: (CourseLearningNode) -> Void
    let onSynthesize: (CourseLearningNode, [String]) -> Void

    @State private var showsAllThreads = false
    private let collapsedThreadLimit = 3

    private var explorations: [CourseLearningNode] {
        CourseExplorationMap.explorations(in: nodes)
    }

    private var trail: [CourseLearningNode] {
        guard let pageID = resumeNode?.pageID else { return [] }
        return CourseExplorationMap.trail(toPageID: pageID, in: nodes)
    }

    private var goals: [CourseLearningNode] {
        explorations.filter { progress.pinnedNodeIDs.contains($0.id) }
    }

    private var openThreads: [CourseLearningNode] {
        // Pinned goals already have their own row above. Threads being written
        // come first, so "Show more" never hides one.
        let threads = CourseExplorationMap.openThreads(
            in: nodes, progress: progress, excludingPageID: resumeNode?.pageID
        ).filter { !progress.pinnedNodeIDs.contains($0.id) }
        return threads.filter { stateOf($0).isActive } + threads.filter { !stateOf($0).isActive }
    }

    var body: some View {
        let explored = explorations
        if !explored.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                if let resumeNode, CourseExplorationMap.isExploration(resumeNode), trail.count > 1 {
                    trailCard
                }
                if !goals.isEmpty {
                    section("Your goals", identifier: "course-goals") {
                        ForEach(goals) { goal in
                            let next = CourseExplorationMap.resume(inside: goal, progress: progress)
                            let visited = goal.pageID.map { progress.lastVisitedAt[$0] != nil } ?? false
                            row(
                                title: goal.title,
                                subtitle: next.id != goal.id
                                    ? "Continue with \(next.title)"
                                    : (visited ? "Continue" : "Start here"),
                                systemImage: "pin.fill",
                                identifier: "course-goal-\(goal.id)"
                            ) { onOpen(next) }
                        }
                    }
                }
                if !openThreads.isEmpty {
                    let threads = openThreads
                    let visible = showsAllThreads ? threads : Array(threads.prefix(collapsedThreadLimit))
                    section("Open threads", identifier: "course-open-threads") {
                        ForEach(visible) { thread in
                            let state = stateOf(thread)
                            row(
                                title: thread.title,
                                subtitle: subtitle(for: thread, state: state),
                                systemImage: systemImage(for: state),
                                identifier: "course-open-thread-\(thread.id)",
                                isWriting: state.isActive
                            ) { onOpen(thread) }
                        }
                        if !showsAllThreads, threads.count > collapsedThreadLimit {
                            Button("Show \(threads.count - collapsedThreadLimit) more") {
                                withAnimation(.snappy(duration: 0.24)) { showsAllThreads = true }
                            }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                        }
                    }
                }
                let written = explored.filter { $0.status == .generated }
                if written.count >= 3, let anchor = resumeNode, anchor.pageID != nil {
                    Button {
                        onSynthesize(anchor, written.map(\.title))
                    } label: {
                        Label(CourseExplorationDirection.synthesis.label,
                              systemImage: CourseExplorationDirection.synthesis.systemImage)
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(launcher.isForking)
                    .accessibilityHint(CourseExplorationDirection.synthesis.detail)
                    .accessibilityIdentifier("course-explore-synthesis")
                }
                CourseExplorationForkErrorView(launcher: launcher)
            }
            .padding(.horizontal, 4)
        }
    }

    private var trailCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your trail")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(trail.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        let isCurrent = index == trail.count - 1
                        Button {
                            onOpen(node)
                        } label: {
                            Text(node.title)
                                .font(.footnote.weight(isCurrent ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    isCurrent ? Color.courseExploration.opacity(0.16) : Color(uiColor: .tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(node.kind != .markdown || node.pageID == nil)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your trail: " + trail.map(\.title).joined(separator: ", then "))
        .accessibilityIdentifier("course-trail")
    }

    private func section<Content: View>(
        _ title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func subtitle(for thread: CourseLearningNode, state: CourseExplorationState) -> String {
        let question = thread.originQuestion.flatMap { $0 == thread.title || $0.isEmpty ? nil : "“\($0)”" }
        switch state {
        case .written(let isNew, _):
            if isNew { return question.map { "New · \($0)" } ?? "New" }
            return question ?? "Not finished"
        case .writing: return "Writing…"
        case .queued: return "Waiting to start"
        case .failed: return "Couldn’t finish · Tap to try again"
        case .unwritten: return "Not written yet · Tap to write"
        }
    }

    private func systemImage(for state: CourseExplorationState) -> String {
        switch state {
        case .written: "arrow.triangle.branch"
        case .writing: "pencil.line"
        case .queued: "clock"
        case .failed: "exclamationmark.triangle"
        case .unwritten: "sparkle"
        }
    }

    private func row(
        title: String,
        subtitle: String,
        systemImage: String,
        identifier: String,
        isWriting: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.courseExploration)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A page being written opens once it is ready, from here or the reader.
        .allowsHitTesting(!isWriting)
        .accessibilityIdentifier(identifier)
    }
}

extension Color {
    /// Explorations wander off the blue suggested route in their own color.
    static let courseExploration = Color(uiColor: .systemPurple)
}

extension EnvironmentValues {
    /// Where an exploration stands, for views far below the store, so every
    /// part of a screen tells the same story about it.
    @Entry var courseExplorationState: ((CourseLearningNode) -> CourseExplorationState)?
}

/// Explorations growing off one page, drawn as side trails that sprout from
/// the page's badge and keep branching as deep as the learner went.
struct CourseSideTrailList: View {
    let origin: CourseLearningNode
    let depth: Int
    let currentNodeID: String?
    let progress: CourseExplorationProgress
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    @State private var showsAll = false
    private let collapsedLimit = 3

    var body: some View {
        let trails = origin.children
        let visible = showsAll ? trails : Array(trails.prefix(collapsedLimit))
        let hidden = trails.count - visible.count
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, trail in
                CourseSideTrailRow(
                    trail: trail,
                    depth: depth,
                    isLast: index == visible.count - 1 && hidden == 0,
                    currentNodeID: currentNodeID,
                    progress: progress,
                    generationDisabled: generationDisabled,
                    runtimeID: runtimeID,
                    onOpenMarkdown: onOpenMarkdown,
                    onGenerate: onGenerate
                )
            }
            if hidden > 0 {
                HStack(spacing: 0) {
                    CourseTrailConnector(isLast: true)
                        .stroke(Color.courseExploration.opacity(0.45), style: CourseSideTrailRow.trailStroke)
                        .frame(width: CourseSideTrailRow.connectorWidth, height: 36)
                    Button {
                        withAnimation(.snappy(duration: 0.24)) { showsAll = true }
                    } label: {
                        Label("\(hidden) more \(hidden == 1 ? "trail" : "trails")", systemImage: "ellipsis")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.courseExploration)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.courseExploration.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("course-trail-more-\(origin.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Explorations from \(origin.title)")
    }
}

struct CourseSideTrailRow: View {
    static let connectorWidth: CGFloat = 26
    static let badgeSize: CGFloat = 38
    static let cardPadding: CGFloat = 10
    static let trailStroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [1, 6])

    let trail: CourseLearningNode
    let depth: Int
    let isLast: Bool
    let currentNodeID: String?
    let progress: CourseExplorationProgress
    let generationDisabled: Bool
    let runtimeID: String
    let onOpenMarkdown: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void
    @Environment(\.courseExplorationState) private var explorationStateOf
    @State private var showsDeeper: Bool

    init(
        trail: CourseLearningNode,
        depth: Int,
        isLast: Bool,
        currentNodeID: String?,
        progress: CourseExplorationProgress,
        generationDisabled: Bool,
        runtimeID: String,
        onOpenMarkdown: @escaping (String) -> Void,
        onGenerate: @escaping (CourseLearningNode) -> Void
    ) {
        self.trail = trail
        self.depth = depth
        self.isLast = isLast
        self.currentNodeID = currentNodeID
        self.progress = progress
        self.generationDisabled = generationDisabled
        self.runtimeID = runtimeID
        self.onOpenMarkdown = onOpenMarkdown
        self.onGenerate = onGenerate
        // Open the way to wherever the learner is; keep short first forks open.
        let leadsToCurrent = currentNodeID.map {
            CourseExplorationMap.node(withID: $0, in: trail.children) != nil
        } ?? false
        _showsDeeper = State(initialValue: leadsToCurrent || (depth == 0 && trail.children.count <= 2))
    }

    private var isCurrent: Bool { trail.id == currentNodeID }
    /// Queued and failed explorations, which the page status alone cannot tell apart.
    private var explorationState: CourseExplorationState? { explorationStateOf?(trail) }
    private var isPinned: Bool { progress.pinnedNodeIDs.contains(trail.id) }
    private var isFinished: Bool { trail.pageID.map(progress.finishedPageIDs.contains) ?? false }
    private var isVisited: Bool { trail.pageID.map { progress.lastVisitedAt[$0] != nil } ?? false }
    private var deeperCount: Int { CourseExplorationMap.explorationCount(below: trail) }

    private var generationRequest: CourseDirectGenerationRequest? {
        CourseExperienceStore.directGenerationRequest(for: trail, runtimeID: runtimeID)
    }

    private var isEnabled: Bool {
        switch trail.status {
        case .generated: trail.pageID != nil
        // Explorations are written by their own workers, so a busy course
        // agent never blocks them.
        case .pendingGeneration: generationRequest != nil
            && (!generationDisabled || CourseExplorationMap.isExploration(trail))
        case .generating, .partiallyGenerated: false
        }
    }

    /// Deeper trails hang a little inside their card so nesting stays narrow,
    /// and stop indenting after two levels so cards keep a readable width.
    private var deeperIndent: CGFloat { depth >= 1 ? 0 : Self.nestedIndent }
    static let nestedIndent: CGFloat = 14
    private var isCompact: Bool { depth >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .padding(.vertical, 5)
                .padding(.leading, Self.connectorWidth)
                // Drawn behind the row so the trail always spans its full height.
                .background(alignment: .leading) {
                    CourseTrailConnector(isLast: isLast)
                        .stroke(Color.courseExploration.opacity(0.45), style: Self.trailStroke)
                        .frame(width: Self.connectorWidth)
                }
            if !trail.children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    deeperToggle
                    if showsDeeper {
                        CourseSideTrailList(
                            origin: trail,
                            depth: depth + 1,
                            currentNodeID: currentNodeID,
                            progress: progress,
                            generationDisabled: generationDisabled,
                            runtimeID: runtimeID,
                            onOpenMarkdown: onOpenMarkdown,
                            onGenerate: onGenerate
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.leading, Self.connectorWidth + deeperIndent)
                .background(alignment: .leading) {
                    // Keeps the parent trail running past this row's deeper trails.
                    CourseTrailLine()
                        .stroke(isLast ? Color.clear : Color.courseExploration.opacity(0.45), style: Self.trailStroke)
                        .frame(width: Self.connectorWidth)
                }
            }
        }
    }

    private var card: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: isCompact ? 10 : 12) {
                badge
                VStack(alignment: .leading, spacing: 4) {
                    Text(trail.title)
                        .font(isCompact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isCompact, let question = trail.originQuestion, !question.isEmpty, question != trail.title {
                        Text("“\(question)”")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    chips
                }
                Spacer(minLength: 0)
            }
            .padding(isCompact ? 8 : Self.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isCurrent ? Color.courseExploration : Color.courseExploration.opacity(0.14),
                        lineWidth: isCurrent ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("course-branch-\(trail.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isEnabled ? .isButton : [])
    }

    private var badge: some View {
        ZStack {
            if let explorationState, explorationState == .queued || explorationState.failureReason != nil {
                CourseExplorationStateBadge(state: explorationState, size: isCompact ? 30 : Self.badgeSize)
            } else {
                statusBadge
            }
            if isCurrent {
                Circle()
                    .stroke(Color.courseExploration.opacity(0.3), lineWidth: 4)
                    .padding(-5)
            }
        }
        .frame(width: isCompact ? 30 : Self.badgeSize, height: isCompact ? 30 : Self.badgeSize)
    }

    @ViewBuilder
    private var statusBadge: some View {
        ZStack {
            switch trail.status {
            case .generated:
                Circle().fill(Color.courseExploration.opacity(isFinished && !isCurrent ? 0.16 : 1))
                Image(systemName: badgeSymbol)
                    .font(.system(size: isCompact ? 12 : 15, weight: .bold))
                    .foregroundStyle(isFinished && !isCurrent ? Color.courseExploration : .white)
            case .pendingGeneration:
                Circle().fill(Color.courseExploration.opacity(0.06))
                Circle().strokeBorder(
                    Color.courseExploration.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.courseExploration)
            case .generating, .partiallyGenerated:
                Circle().fill(Color.courseExploration.opacity(0.1))
                ProgressView().controlSize(.small).tint(Color.courseExploration)
            }
        }
    }

    private var badgeSymbol: String {
        if isCurrent { return "location.fill" }
        if isFinished { return "checkmark" }
        return "arrow.triangle.branch"
    }

    @ViewBuilder
    private var chips: some View {
        let items = chipItems
        if !items.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chipViews(items) }
                VStack(alignment: .leading, spacing: 4) { chipViews(items) }
            }
        }
    }

    @ViewBuilder
    private func chipViews(_ items: [Chip]) -> some View {
                ForEach(items, id: \.label) { item in
                    Label(item.label, systemImage: item.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.prominent ? .white : Color.courseExploration)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            item.prominent ? Color.courseExploration : Color.courseExploration.opacity(0.12),
                            in: Capsule()
                        )
                        .lineLimit(1)
                        .fixedSize()
                }
    }

    private struct Chip {
        let label: String
        let symbol: String
        var prominent = false
    }

    private var chipItems: [Chip] {
        var items: [Chip] = []
        if isCurrent { items.append(Chip(label: "You are here", symbol: "location.fill", prominent: true)) }
        if isPinned { items.append(Chip(label: "Goal", symbol: "pin.fill")) }
        if explorationState == .queued {
            items.append(Chip(label: "Waiting to start", symbol: "clock"))
            return items
        }
        if explorationState?.failureReason != nil {
            items.append(Chip(label: "Couldn’t finish · Tap to try again", symbol: "exclamationmark.triangle"))
            return items
        }
        switch trail.status {
        case .pendingGeneration:
            items.append(Chip(label: "Tap to write", symbol: "sparkle"))
        case .generating, .partiallyGenerated:
            items.append(Chip(label: "Writing…", symbol: "pencil.line"))
        case .generated:
            if isFinished {
                items.append(Chip(label: "Read", symbol: "checkmark"))
            } else if !isVisited, !isCurrent {
                items.append(Chip(label: "New", symbol: "sparkles"))
            }
        }
        return items
    }

    private var deeperToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.26)) { showsDeeper.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showsDeeper ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                Text(showsDeeper ? "Hide deeper trails" : "\(deeperCount) deeper \(deeperCount == 1 ? "trail" : "trails")")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.courseExploration)
            .padding(.vertical, 6)
            .padding(.leading, Self.connectorWidth - 4)
            .background(alignment: .leading) {
                // The stem from this card down into its deeper trails.
                CourseTrailLine()
                    .stroke(Color.courseExploration.opacity(0.45), style: Self.trailStroke)
                    .frame(width: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsDeeper
            ? "Hide explorations deeper than \(trail.title)"
            : "Show \(deeperCount) explorations deeper than \(trail.title)")
        .accessibilityIdentifier("course-branch-toggle-\(trail.id)")
    }

    private var accessibilityLabel: String {
        var parts = ["Exploration", trail.title]
        if let question = trail.originQuestion, !question.isEmpty {
            parts.append("from your question: \(question)")
        }
        parts.append(contentsOf: chipItems.map(\.label))
        if deeperCount > 0 {
            parts.append("\(deeperCount) deeper \(deeperCount == 1 ? "exploration" : "explorations")")
        }
        return parts.joined(separator: ", ")
    }

    private func action() {
        switch trail.status {
        case .generated:
            if let pageID = trail.pageID { onOpenMarkdown(pageID) }
        case .pendingGeneration:
            if generationRequest != nil { onGenerate(trail) }
        case .generating, .partiallyGenerated:
            break
        }
    }
}

/// A trail that runs down the left edge and curves out to one exploration.
struct CourseTrailConnector: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 1
        let midY = rect.midY
        let radius = min(14, rect.width - 4, midY)
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: midY - radius))
        path.addQuadCurve(
            to: CGPoint(x: x + radius, y: midY),
            control: CGPoint(x: x, y: midY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        if !isLast {
            path.move(to: CGPoint(x: x, y: midY - radius))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

/// A straight stretch of trail.
struct CourseTrailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + 1, y: rect.maxY))
        return path
    }
}

/// Asks what the learner wants from the passage before forking it. The
/// question is optional; the chips fill the field so it can still be reworded.
/// It stays open until the new page exists, so a failure is shown right here.
struct CourseExplorePassagePrompt: View {
    let passage: String
    /// Mac popovers are tighter and submit on Return.
    var isCompact = false
    /// Explorations that already start on this passage.
    var alreadyExploredTitles: [String] = []
    /// Quick questions already asked about this passage.
    var usedIntents: Set<CourseExplorePassageIntent> = []
    let onSubmit: (String?) async throws -> Void
    let onCancel: () -> Void

    @State private var question = ""
    @State private var isStarting = false
    @State private var error: String?
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 16) {
            if !isCompact {
                HStack {
                    Text("Explore")
                        .font(.headline)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .disabled(isStarting)
                        .accessibilityIdentifier("course-explore-prompt-cancel")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("“\(passage)”")
                    .font(isCompact ? .system(size: 12) : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.courseExploration.opacity(0.6))
                            .frame(width: 3)
                    }
                    .accessibilityLabel("Selected passage: \(passage)")
                if let alreadyExplored {
                    Label(alreadyExplored, systemImage: "arrow.triangle.branch")
                        .font(isCompact ? .system(size: 11) : .caption)
                        .foregroundStyle(Color.courseExploration)
                        .lineLimit(2)
                        .accessibilityIdentifier("course-explore-prompt-already")
                }
            }

            TextField("What do you want to explore?", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($questionFocused)
                .submitLabel(.go)
                .onSubmit(submit)
                .font(isCompact ? .system(size: 13) : .body)
                .padding(.horizontal, 12)
                .padding(.vertical, isCompact ? 7 : 10)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: isCompact ? 8 : 14, style: .continuous)
                )
                .disabled(isStarting)
                .accessibilityIdentifier("course-explore-prompt-field")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CourseExplorePassageIntent.allCases) { intent in
                        let isUsed = usedIntents.contains(intent)
                        Button {
                            question = intent.question
                            questionFocused = true
                        } label: {
                            HStack(spacing: 4) {
                                Label(intent.label, systemImage: intent.systemImage)
                                if isUsed {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                }
                            }
                            .font(isCompact ? .system(size: 11, weight: .medium) : .subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(isCompact ? .small : .regular)
                        .tint(Color.courseExploration)
                        .disabled(isStarting)
                        .accessibilityHint(isUsed
                            ? "You already explored this question here."
                            : "Fills in: \(intent.question)")
                        .accessibilityIdentifier("course-explore-intent-\(intent.rawValue)")
                    }
                }
            }

            if let error {
                Label {
                    Text("Couldn’t start this exploration. \(error)")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                .font(isCompact ? .system(size: 11) : .footnote)
                .accessibilityIdentifier("course-explore-prompt-error")
            }

            HStack {
                if isCompact {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                        .disabled(isStarting)
                }
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isStarting {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        } else {
                            Label("Explore", systemImage: "arrow.triangle.branch")
                        }
                    }
                    .font(isCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.courseExploration)
                .controlSize(isCompact ? .small : .regular)
                .keyboardShortcut(.defaultAction)
                .disabled(isStarting)
                .accessibilityHint(trimmedQuestion.isEmpty
                    ? "Writes a new page about this passage"
                    : "Writes a new page that answers your question")
                .accessibilityIdentifier("course-explore-prompt-submit")
            }
        }
        .padding(isCompact ? 14 : 20)
        .frame(width: isCompact ? 340 : nil)
        .frame(maxHeight: isCompact ? nil : .infinity, alignment: .top)
        // A fork that is starting finishes here, so its result is never lost.
        .interactiveDismissDisabled(isStarting)
        .onAppear { questionFocused = true }
    }

    private var alreadyExplored: String? {
        guard !alreadyExploredTitles.isEmpty else { return nil }
        let shown = alreadyExploredTitles.prefix(2).map { title in
            title.count > 40 ? String(title.prefix(39)) + "…" : title
        }
        let more = alreadyExploredTitles.count - shown.count
        return "Already explored here: " + shown.joined(separator: ", ") + (more > 0 ? " +\(more) more" : "")
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !isStarting else { return }
        let question = trimmedQuestion.isEmpty ? nil : trimmedQuestion
        error = nil
        isStarting = true
        Task { @MainActor in
            do {
                try await onSubmit(question)
            } catch {
                self.error = error.localizedDescription
            }
            isStarting = false
        }
    }
}

/// An exploration's state in the Learn map's badge vocabulary.
struct CourseExplorationStateBadge: View {
    let state: CourseExplorationState
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            switch state {
            case .written(let isNew, let isFinished):
                Circle().fill(Color.courseExploration.opacity(isNew ? 1 : 0.16))
                Image(systemName: isFinished ? "checkmark" : "arrow.triangle.branch")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(isNew ? Color.white : Color.courseExploration)
            case .writing:
                Circle().fill(Color.courseExploration.opacity(0.1))
                ProgressView().controlSize(.small).tint(Color.courseExploration)
            case .queued:
                Circle().fill(Color.courseExploration.opacity(0.08))
                Image(systemName: "clock")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.courseExploration)
            case .failed:
                Circle().fill(Color.orange.opacity(0.14))
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.orange)
            case .unwritten:
                Circle().fill(Color.courseExploration.opacity(0.06))
                Circle().strokeBorder(
                    Color.courseExploration.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.courseExploration)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One exploration as a row: what it is, where it stands, and the one thing
/// a tap can do. Only a written page opens; nothing opens by itself later.
struct CourseExplorationRow: View {
    let node: CourseLearningNode
    let state: CourseExplorationState
    /// How the learner asked for it, shown until the page has its own title.
    let label: String
    let identifier: String
    /// Identifies the Write It / Try Again button.
    let actionIdentifier: String
    let onOpen: () -> Void
    /// Writes an unwritten page or retries a failed one, in place.
    let onWrite: () -> Void

    var body: some View {
        switch state {
        case .written:
            Button(action: onOpen) {
                content(trailing: AnyView(
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                ))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(identifier)
        case .failed, .unwritten:
            let actionTitle = state == .unwritten ? "Write It" : "Try Again"
            content(trailing: AnyView(
                Button(actionTitle, action: onWrite)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Color.courseExploration)
                    .accessibilityIdentifier(actionIdentifier)
            ))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction(named: actionTitle, onWrite)
            .accessibilityIdentifier(identifier)
        case .writing, .queued:
            content(trailing: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier(identifier)
        }
    }

    private var title: String {
        state.isWritten ? node.title : label
    }

    private var question: String? {
        guard let question = node.originQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty, question != title else { return nil }
        return question
    }

    private func content(trailing: AnyView?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            CourseExplorationStateBadge(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitle: Text {
        switch state {
        case .written(let isNew, let isFinished):
            if isFinished {
                return question.map { Text("Read · \(Text($0).italic())") } ?? Text("Read")
            }
            if isNew {
                return question.map { Text("New · \(Text($0).italic())") } ?? Text("New")
            }
            return question.map { Text($0).italic() } ?? Text("Opened")
        case .writing:
            return Text("Writing… It’ll be ready right here.")
        case .queued:
            return Text("Waiting to start. It’ll be ready right here.")
        case .failed(let reason):
            return Text("Couldn’t finish. \(reason)")
        case .unwritten:
            return Text("Not written yet.")
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .written(let isNew, let isFinished):
            let status = isFinished ? ", read" : isNew ? ", new" : ""
            return "Exploration, \(title)\(status). Opens the page."
        case .writing: return "Exploration, \(title), being written."
        case .queued: return "Exploration, \(title), waiting to start."
        case .failed(let reason): return "Exploration, \(title), couldn’t finish. \(reason)"
        case .unwritten: return "Exploration, \(title), not written yet."
        }
    }
}

/// The reader's one quiet status for every exploration the learner started in
/// this course. It lives in the toolbar the reader already has and opens a
/// menu; nothing floats over the text and nothing opens until the learner asks.
struct CourseExplorationStatusMenu: View {
    enum Placement: Equatable {
        case toolbar(compact: Bool)
        case macHeader
    }

    let summary: CourseExplorationStatusSummary
    let currentPageID: String?
    let placement: Placement
    let onOpen: (CourseExplorationJob) -> Void
    let onRetry: (CourseExplorationJob) -> Void
    let onDismiss: (CourseExplorationJob) -> Void
    let onMarkAllSeen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            if !summary.ready.isEmpty {
                Section("Ready to Read") {
                    ForEach(summary.ready) { job in
                        Button {
                            onOpen(job)
                        } label: {
                            Text(job.title)
                            Text(summary.origin(of: job, currentPageID: currentPageID))
                        }
                        .accessibilityIdentifier("course-exploration-status-open-\(job.id)")
                    }
                }
            }
            if !summary.writing.isEmpty {
                Section("Writing") {
                    ForEach(summary.writing) { job in
                        let isQueued = job.phase == .queued
                        Button {} label: {
                            Text(job.label)
                            Text("\(isQueued ? "Waiting to start" : "Writing…") · \(summary.origin(of: job, currentPageID: currentPageID))")
                        }
                        .disabled(true)
                    }
                }
            }
            if !summary.failed.isEmpty {
                Section("Didn’t Finish") {
                    ForEach(summary.failed) { job in
                        Menu {
                            Button {
                                onRetry(job)
                            } label: {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                            Button {
                                onDismiss(job)
                            } label: {
                                Label("Dismiss", systemImage: "xmark")
                            }
                        } label: {
                            Text(job.label)
                            Text(job.failureReason ?? "")
                        }
                    }
                }
            }
            if !summary.ready.isEmpty || !summary.failed.isEmpty {
                Section {
                    Button(action: onMarkAllSeen) {
                        Label("Mark All as Seen", systemImage: "checkmark")
                    }
                }
            }
        } label: {
            label
        }
        .modifier(MacHeaderMenuStyle(isMac: placement == .macHeader))
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Shows the explorations you started.")
        .accessibilityIdentifier("course-exploration-status")
    }

    private var label: some View {
        HStack(spacing: placement == .macHeader ? 5 : 6) {
            Image(systemName: summary.systemImage)
                .foregroundStyle(iconColor)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : summary.ready.count)
            Text(isCompact ? "\(summary.totalCount)" : summary.fullLabel)
                .font(placement == .macHeader ? .system(size: 11, weight: .medium) : .callout.weight(.semibold))
                .foregroundStyle(summary.isReadyTinted ? Color.courseExploration : Color.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: summary.fullLabel)
    }

    private var isCompact: Bool {
        if case .toolbar(let compact) = placement { compact } else { false }
    }

    private var iconColor: Color {
        if summary.isReadyTinted { return .courseExploration }
        return summary.isFailureOnly ? .orange : .primary
    }

    private struct MacHeaderMenuStyle: ViewModifier {
        let isMac: Bool

        func body(content: Content) -> some View {
            if isMac {
                content
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Explorations you started")
            } else {
                content
            }
        }
    }
}

/// Everything that starts at a tapped passage: each exploration in the order
/// it was forked, then any discussion, then ways to go further from here.
struct CoursePassageThreadsList: View {
    struct Exploration: Identifiable {
        let node: CourseLearningNode
        let state: CourseExplorationState
        let label: String
        var id: String { node.id }
    }

    let explorations: [Exploration]
    let discussions: [CourseSelectionDiscussion]
    /// Why the last Write It or Try Again did not start.
    var error: String?
    let onOpenExploration: (CourseLearningNode) -> Void
    let onWrite: (CourseLearningNode) -> Void
    let onOpenDiscussion: (CourseSelectionDiscussion) -> Void
    let onExploreAgain: () -> Void
    /// Absent when the passage already has a discussion to continue.
    let onAsk: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0
    private let maximumListHeight: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                rows
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maximumListHeight))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("course-passage-error")
            }

            Divider()

            HStack(spacing: 8) {
                Button(action: onExploreAgain) {
                    Label("Explore Again", systemImage: "arrow.triangle.branch")
                }
                .accessibilityHint("Asks what to explore, then writes another page from this passage")
                .accessibilityIdentifier("course-passage-explore-again")
                if let onAsk {
                    Button(action: onAsk) {
                        Label("Ask", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityHint("Opens a discussion about this passage")
                    .accessibilityIdentifier("course-passage-ask")
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color.courseExploration)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(idealWidth: 320, maxWidth: 420)
        .animation(reduceMotion ? nil : .default, value: explorations.map(\.state))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-passage-threads")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(explorations) { item in
                CourseExplorationRow(
                    node: item.node,
                    state: item.state,
                    label: item.label,
                    identifier: "course-passage-exploration-\(item.node.id)",
                    actionIdentifier: "course-passage-\(item.state == .unwritten ? "write" : "retry")-\(item.node.id)",
                    onOpen: { onOpenExploration(item.node) },
                    onWrite: { onWrite(item.node) }
                )
            }
            ForEach(discussions) { discussion in
                Button {
                    onOpenDiscussion(discussion)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.14))
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.blue)
                        }
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your discussion")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Started \(discussion.createdAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("course-passage-discussion-\(discussion.id.uuidString)")
            }
        }
    }
}
