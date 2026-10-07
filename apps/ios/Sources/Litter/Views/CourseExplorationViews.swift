import SwiftUI

/// Forks explorations and opens existing ones. Forking returns as soon as the
/// placeholder page exists; the store's exploration workers write it, so the
/// learner keeps reading and can fork again right away.
@MainActor
@Observable
final class CourseExplorationLauncher {
    private(set) var status: String?
    var error: String?
    private var task: Task<Void, Never>?
    private var forkCount = 0

    var isBusy: Bool { task != nil }
    var isForking: Bool { forkCount > 0 }

    func launch(
        _ request: CourseExplorationRequest,
        anchor: CourseExplorationAnchor? = nil,
        course: LearningCourse,
        store: CourseExperienceStore,
        appModel: AppModel,
        appState: AppState
    ) {
        error = nil
        forkCount += 1
        Task { @MainActor [weak self] in
            defer { self?.forkCount -= 1 }
            do {
                try await store.startExploration(
                    request, anchor: anchor, in: course, appModel: appModel, appState: appState
                )
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    func open(
        _ node: CourseLearningNode,
        course: LearningCourse,
        store: CourseExperienceStore,
        appModel: AppModel,
        appState: AppState,
        replacesCurrentPage: Bool = false
    ) {
        guard task == nil else { return }
        error = nil
        if node.status != .generated { status = "Writing “\(node.title)”…" }
        // Writing can take minutes; never pull the learner back after they leave.
        let origin = store.navigationPath.last
        task = Task { @MainActor [weak self] in
            defer {
                self?.task = nil
                self?.status = nil
            }
            do {
                try await store.openCourseNode(
                    node,
                    in: course,
                    replacesCurrentPage: replacesCurrentPage,
                    appModel: appModel,
                    appState: appState,
                    shouldOpen: { store.navigationPath.last == origin }
                )
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }
}

private struct CourseExplorationStatusView: View {
    let launcher: CourseExplorationLauncher

    var body: some View {
        if let status = launcher.status {
            HStack(spacing: 10) {
                ProgressView()
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("course-exploration-status")
        } else if let error = launcher.error {
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
                    .disabled(launcher.isBusy || launcher.isForking)
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
                .disabled(trimmedQuestion.isEmpty || launcher.isBusy || launcher.isForking)
                .accessibilityLabel("Explore this question")
                .accessibilityIdentifier("course-explore-question-submit")
            }

            CourseExplorationStatusView(launcher: launcher)

            if !exploredFromHere.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already explored from here")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(exploredFromHere) { node in
                        Button {
                            onOpen(node)
                        } label: {
                            Label(node.title, systemImage: node.status == .generated
                                  ? "arrow.triangle.branch" : "sparkle")
                                .font(.subheadline)
                                .foregroundStyle(Color.courseExploration)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(launcher.isBusy)
                        .accessibilityIdentifier("course-explored-\(node.id)")
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
        guard !trimmedQuestion.isEmpty, !launcher.isBusy, !launcher.isForking else { return }
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
    /// Explorations an agent is writing right now.
    var writingNodeIDs: Set<String> = []
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
        // Pinned goals already have their own row above.
        CourseExplorationMap.openThreads(
            in: nodes, progress: progress, excludingPageID: resumeNode?.pageID
        ).filter { !progress.pinnedNodeIDs.contains($0.id) }
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
                            row(
                                title: thread.title,
                                subtitle: thread.status == .generated
                                    ? (thread.originQuestion.map { "“\($0)”" } ?? "Not finished")
                                    : writingNodeIDs.contains(thread.id) ? "Writing…" : "Not written yet",
                                systemImage: thread.status == .generated ? "arrow.triangle.branch" : "sparkle",
                                identifier: "course-open-thread-\(thread.id)"
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
                    .disabled(launcher.isBusy)
                    .accessibilityHint(CourseExplorationDirection.synthesis.detail)
                    .accessibilityIdentifier("course-explore-synthesis")
                }
                CourseExplorationStatusView(launcher: launcher)
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
                        .disabled(node.kind != .markdown || node.pageID == nil || launcher.isBusy)
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

    private func row(
        title: String,
        subtitle: String,
        systemImage: String,
        identifier: String,
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
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
        .disabled(launcher.isBusy)
        .accessibilityIdentifier(identifier)
    }
}

extension Color {
    /// Explorations wander off the blue suggested route in their own color.
    static let courseExploration = Color(uiColor: .systemPurple)
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
        case .pendingGeneration: generationRequest != nil && !generationDisabled
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
            if isCurrent {
                Circle()
                    .stroke(Color.courseExploration.opacity(0.3), lineWidth: 4)
                    .padding(-5)
            }
        }
        .frame(width: isCompact ? 30 : Self.badgeSize, height: isCompact ? 30 : Self.badgeSize)
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
struct CourseExplorePassagePrompt: View {
    let passage: String
    /// Mac popovers are tighter and submit on Return.
    var isCompact = false
    let onSubmit: (String?) -> Void
    let onCancel: () -> Void

    @State private var question = ""
    @FocusState private var questionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 16) {
            if !isCompact {
                HStack {
                    Text("Explore")
                        .font(.headline)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("course-explore-prompt-cancel")
                }
            }

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
                .accessibilityIdentifier("course-explore-prompt-field")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CourseExplorePassageIntent.allCases) { intent in
                        Button {
                            question = intent.question
                            questionFocused = true
                        } label: {
                            Label(intent.label, systemImage: intent.systemImage)
                                .font(isCompact ? .system(size: 11, weight: .medium) : .subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(isCompact ? .small : .regular)
                        .tint(Color.courseExploration)
                        .accessibilityHint("Fills in: \(intent.question)")
                        .accessibilityIdentifier("course-explore-intent-\(intent.rawValue)")
                    }
                }
            }

            HStack {
                if isCompact {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                }
                Spacer()
                Button(action: submit) {
                    Label("Explore", systemImage: "arrow.triangle.branch")
                        .font(isCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.courseExploration)
                .controlSize(isCompact ? .small : .regular)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(trimmedQuestion.isEmpty
                    ? "Writes a new page about this passage"
                    : "Writes a new page that answers your question")
                .accessibilityIdentifier("course-explore-prompt-submit")
            }
        }
        .padding(isCompact ? 14 : 20)
        .frame(width: isCompact ? 340 : nil)
        .frame(maxHeight: isCompact ? nil : .infinity, alignment: .top)
        .onAppear { questionFocused = true }
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        onSubmit(trimmedQuestion.isEmpty ? nil : trimmedQuestion)
    }
}

/// Floating status for explorations forked from the page being read: what is
/// being written, then a way to open it. Reading is never interrupted.
struct CourseExplorationJobsPill: View {
    let jobs: [CourseExplorationJob]
    let forkError: String?
    /// Mac shows one inline line in the reader's header instead of a pill.
    var isCompact = false
    let onOpen: (CourseExplorationJob) -> Void
    let onRetry: (CourseExplorationJob) -> Void
    let onDismiss: (CourseExplorationJob) -> Void
    let onDismissForkError: () -> Void

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let content {
                if isCompact {
                    compactBody(content)
                } else if isExpanded, jobs.count > 1 {
                    expandedBody
                } else {
                    pillBody(content)
                }
            }
        }
        .onChange(of: jobs.count) { _, count in
            if count < 2 { isExpanded = false }
        }
    }

    private func compactBody(_ content: Content) -> some View {
        HStack(spacing: 6) {
            content.icon
                .controlSize(.mini)
                .frame(width: 14)
            if content.listsJobs {
                Menu {
                    ForEach(jobs) { job in
                        if let action = action(for: job) {
                            Button(job.displayTitle, systemImage: action.systemImage, action: action.perform)
                        } else {
                            Text("\(job.displayTitle) · \(job.statusDetail)")
                        }
                    }
                } label: {
                    Text(content.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(content.detail ?? content.title)
                .accessibilityIdentifier("course-exploration-pill-expand")
            } else {
                Text(content.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .help(content.detail ?? content.title)
            }
            if let action = content.action {
                Button(action.label, action: action.perform)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderless)
                    .tint(Color.courseExploration)
                    .accessibilityIdentifier("course-exploration-pill-action")
            }
            if let dismiss = content.dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("course-exploration-pill-dismiss")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-exploration-pill")
    }

    private func pillBody(_ content: Content) -> some View {
        HStack(spacing: 10) {
            if content.listsJobs {
                // The summary names the others; tapping it lists each one.
                Button { setExpanded(true) } label: {
                    summary(content, showsDisclosure: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows each exploration from this page")
                .accessibilityIdentifier("course-exploration-pill-expand")
            } else {
                summary(content, showsDisclosure: false)
            }
            Spacer(minLength: 4)
            if let action = content.action {
                Button(action.label, action: action.perform)
                    .buttonStyle(ExplorationPillActionStyle())
                    .accessibilityIdentifier("course-exploration-pill-action")
            }
            if let dismiss = content.dismiss {
                dismissButton(dismiss)
                    .accessibilityIdentifier("course-exploration-pill-dismiss")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        // Not interactive glass: its press highlight washed out the Open label.
        // A capsule at one line, a rounded card when the title wraps.
        .modifier(GlassRoundedRectModifier(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-exploration-pill")
    }

    private func summary(_ content: Content, showsDisclosure: Bool) -> some View {
        HStack(spacing: 10) {
            content.icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                // Page titles get a second line rather than an ellipsis.
                Text(content.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let detail = content.detail {
                    HStack(spacing: 4) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if showsDisclosure {
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.primary)
    }

    /// Every exploration from this page, each with its own way in.
    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { setExpanded(false) } label: {
                HStack {
                    Text("Explorations from this page")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide explorations")
            .accessibilityIdentifier("course-exploration-pill-collapse")

            ForEach(jobs) { job in
                jobRow(job)
            }
        }
        .padding(.bottom, 6)
        .modifier(GlassRoundedRectModifier(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-exploration-pill")
    }

    private func jobRow(_ job: CourseExplorationJob) -> some View {
        HStack(spacing: 10) {
            icon(for: job)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(job.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let action = action(for: job) {
                Button(action.label, action: action.perform)
                    .buttonStyle(ExplorationPillActionStyle())
                    .accessibilityIdentifier("course-exploration-job-action")
            }
            if !job.isActive {
                dismissButton { onDismiss(job) }
                    .accessibilityIdentifier("course-exploration-job-dismiss")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-exploration-job")
    }

    private func dismissButton(_ dismiss: @escaping () -> Void) -> some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.snappy(duration: 0.25)) { isExpanded = expanded }
    }

    private func icon(for job: CourseExplorationJob) -> AnyView {
        switch job.phase {
        case .queued, .writing:
            AnyView(ProgressView().controlSize(.small))
        case .ready:
            AnyView(Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.courseExploration))
        case .failed:
            AnyView(Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange))
        }
    }

    private func action(for job: CourseExplorationJob) -> Content.Action? {
        switch job.phase {
        case .ready: .init(label: "Open", systemImage: "arrow.up.right") { onOpen(job) }
        case .failed: .init(label: "Retry", systemImage: "arrow.clockwise") { onRetry(job) }
        case .queued, .writing: nil
        }
    }

    private struct Content {
        struct Action {
            let label: String
            let systemImage: String
            let perform: () -> Void
        }

        let icon: AnyView
        let title: String
        let detail: String?
        let action: Action?
        let dismiss: (() -> Void)?
        var listsJobs = false
    }

    private var content: Content? {
        if let summary = CourseExplorationPillSummary(jobs: jobs) {
            switch summary.lead {
            case .ready(let job), .failed(let job):
                return Content(
                    icon: icon(for: job),
                    title: summary.title,
                    detail: summary.detail,
                    action: action(for: job),
                    dismiss: { onDismiss(job) },
                    listsJobs: summary.listsJobs
                )
            case .writing:
                return Content(
                    icon: AnyView(ProgressView().controlSize(.small)),
                    title: summary.title,
                    detail: summary.detail,
                    action: nil,
                    dismiss: nil,
                    listsJobs: summary.listsJobs
                )
            }
        }
        if let forkError {
            return Content(
                icon: AnyView(Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)),
                title: "Couldn’t start the exploration",
                detail: forkError,
                action: nil,
                dismiss: onDismissForkError
            )
        }
        return nil
    }
}

/// A filled capsule whose label stays put while pressed; only the capsule
/// dims and shrinks a little.
private struct ExplorationPillActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.courseExploration))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
