#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct MacCourseReaderChrome {
    let isOutlineVisible: Bool
    let toggleOutline: () -> Void
}

/// Keeps the document's model mounted when a narrow window shows its discussion.
struct MacCourseReadingWorkspace<Reader: View, Discussion: View>: View {
    let courseTitle: String
    let nodes: [CourseLearningNode]
    let selectedPageID: String
    let runtimeID: String
    let generationDisabled: Bool
    let hasDiscussion: Bool
    let onOpenPage: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void
    let reader: (MacCourseReaderChrome) -> Reader
    let discussion: () -> Discussion

    @State private var showsOutline = true
    @State private var showsCompactOutline = false

    var body: some View {
        GeometryReader { geometry in
            let canShowOutline = geometry.size.width >= (hasDiscussion ? 1_080 : 850)
            let showsInlineOutline = showsOutline && canShowOutline
            let replacesReader = hasDiscussion && geometry.size.width < 720
            let discussionWidth = min(max(geometry.size.width * 0.36, 320), 390)
            let chrome = MacCourseReaderChrome(
                isOutlineVisible: showsInlineOutline || showsCompactOutline,
                toggleOutline: {
                    if canShowOutline {
                        showsOutline.toggle()
                    } else {
                        showsCompactOutline.toggle()
                    }
                }
            )

            HStack(spacing: 0) {
                if showsInlineOutline {
                    outline
                        .frame(width: 192)
                    Divider()
                }

                reader(chrome)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, hasDiscussion && !replacesReader ? discussionWidth + 1 : 0)
                    .opacity(replacesReader ? 0 : 1)
                    .allowsHitTesting(!replacesReader)
                    .accessibilityHidden(replacesReader)
            }
            .overlay(alignment: .trailing) {
                if hasDiscussion {
                    HStack(spacing: 0) {
                        Divider()
                        discussion()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: replacesReader ? geometry.size.width : discussionWidth + 1)
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .popover(isPresented: $showsCompactOutline, arrowEdge: .leading) {
                outline
                    .frame(width: 290, height: min(max(geometry.size.height - 80, 320), 660))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-course-reading-workspace")
    }

    private var outline: some View {
        MacCourseReadingOutline(
            courseTitle: courseTitle,
            nodes: nodes,
            selectedPageID: selectedPageID,
            runtimeID: runtimeID,
            generationDisabled: generationDisabled,
            onOpenPage: { pageID in
                showsCompactOutline = false
                onOpenPage(pageID)
            },
            onGenerate: onGenerate
        )
    }
}

private struct MacCourseReadingOutline: View {
    let courseTitle: String
    let nodes: [CourseLearningNode]
    let selectedPageID: String
    let runtimeID: String
    let generationDisabled: Bool
    let onOpenPage: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void

    private var lessonSummary: String {
        let lessons = CourseReadingOrder.lessons(in: nodes)
        let ready = lessons.filter { $0.status == .generated }.count
        return "\(ready) of \(lessons.count) lessons ready"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("COURSE OUTLINE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Text(courseTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                Text(lessonSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(nodes) { node in
                        MacCourseOutlineNode(
                            node: node,
                            depth: 0,
                            selectedPageID: selectedPageID,
                            runtimeID: runtimeID,
                            generationDisabled: generationDisabled,
                            onOpenPage: onOpenPage,
                            onGenerate: onGenerate
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-course-reading-outline")
    }
}

private struct MacCourseOutlineNode: View {
    let node: CourseLearningNode
    let depth: Int
    let selectedPageID: String
    let runtimeID: String
    let generationDisabled: Bool
    let onOpenPage: (String) -> Void
    let onGenerate: (CourseLearningNode) -> Void
    @State private var isExpanded = true

    private var isSelected: Bool { node.pageID == selectedPageID }
    private var canOpen: Bool {
        node.kind == .markdown && node.status == .generated && node.pageID != nil
    }
    private var generationRequest: CourseDirectGenerationRequest? {
        CourseExperienceStore.directGenerationRequest(for: node, runtimeID: runtimeID)
    }

    private var statusLabel: String {
        switch node.status {
        case .generated: isSelected ? "Reading" : "Ready"
        case .pendingGeneration: "Not created yet"
        case .generating: "Writing…"
        case .partiallyGenerated: "In progress"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if !node.children.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(node.title)")
                } else {
                    Image(systemName: node.status == .generated ? "doc.text" : "circle.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 14)
                }

                Button(action: openNode) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(statusLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canOpen && node.children.isEmpty)
                .accessibilityLabel("\(node.title), \(statusLabel)")
                .accessibilityIdentifier("mac-course-outline-node-\(node.id)")

                if node.status == .generating {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Writing \(node.title)")
                } else if generationRequest != nil {
                    Button {
                        onGenerate(node)
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(generationDisabled)
                    .help("Create \(node.title)")
                    .accessibilityLabel(generationRequest?.accessibilityLabel ?? "Create \(node.title)")
                    .accessibilityIdentifier("generate-course-node-\(node.id)")
                } else if node.status == .partiallyGenerated {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(node.title) is in progress")
                }
            }
            .padding(.leading, CGFloat(min(depth, 4)) * 9 + 6)
            .padding(.trailing, 7)
            .padding(.vertical, 9)
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )

            if isExpanded {
                ForEach(node.children) { child in
                    MacCourseOutlineNode(
                        node: child,
                        depth: depth + 1,
                        selectedPageID: selectedPageID,
                        runtimeID: runtimeID,
                        generationDisabled: generationDisabled,
                        onOpenPage: onOpenPage,
                        onGenerate: onGenerate
                    )
                }
            }
        }
    }

    private func openNode() {
        if canOpen, let pageID = node.pageID {
            guard pageID != selectedPageID else { return }
            onOpenPage(pageID)
        } else if !node.children.isEmpty {
            isExpanded.toggle()
        }
    }
}
#endif
