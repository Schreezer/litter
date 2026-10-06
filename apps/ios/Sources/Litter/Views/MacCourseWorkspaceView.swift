#if targetEnvironment(macCatalyst)
import SwiftUI

enum MacCourseSidebarItem: Hashable {
    case library
    case draft
    case course(String)
}

/// Desktop navigation stays mounted while the existing course routes change.
/// Uses the system split view so the sidebar gets the platform material,
/// row metrics (which follow the user's sidebar icon size), accent-colored
/// selection, and a standard show/hide control.
struct MacCourseWorkspaceView<Content: View>: View {
    @Bindable var store: CourseExperienceStore
    let onNewCourse: () -> Void
    let onOpenAppSettings: () -> Void
    let onOpenAgentSettings: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private var selectedCourseID: String? {
        for route in store.navigationPath.reversed() {
            switch route {
            case .course(let id), .courseFile(let id, _), .coursePage(let id, _):
                return id
            case .newCourse, .building:
                continue
            }
        }
        return nil
    }

    private var selectedItem: MacCourseSidebarItem? {
        if let selectedCourseID { return .course(selectedCourseID) }
        if store.navigationPath.isEmpty { return .library }
        if store.navigationPath.last == .newCourse { return .draft }
        return nil
    }

    private func select(_ item: MacCourseSidebarItem) {
        switch item {
        case .library:
            store.navigationPath.removeAll()
        case .draft:
            store.resumeCourseDraft()
        case .course(let id):
            store.navigationPath = [.course(id)]
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 320)
        } detail: {
            content()
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("mac-course-workspace")
    }

    private var sidebar: some View {
        // Rows are buttons rather than `List(selection:)`: a selection change
        // inside a split view sidebar resets the detail NavigationStack, which
        // would drop the course route the store just pushed.
        List {
            Section {
                row(.library, title: "Library", systemImage: "books.vertical")
                    .accessibilityIdentifier("mac-sidebar-library")

                if let draft = store.resumableCourseDraft {
                    row(
                        .draft,
                        title: draft.courseTitle ?? "Course Draft",
                        systemImage: draft.isAgentWorking ? "ellipsis.message" : "square.and.pencil"
                    )
                    .help(draft.detail)
                    .accessibilityIdentifier("mac-sidebar-draft")
                }
            }

            Section("Courses") {
                ForEach(store.courses) { course in
                    row(.course(course.id), title: course.title, systemImage: macSidebarCourseSymbol(course))
                        .help(course.title)
                        .accessibilityIdentifier("mac-sidebar-course-\(course.id)")
                }
                if store.courses.isEmpty {
                    Text("No courses yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 28)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            agentStatus
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewCourse) {
                    Label("New Course", systemImage: "plus")
                }
                .help("New Course (⌘N)")
                .accessibilityIdentifier("mac-sidebar-new-course")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-course-sidebar")
    }

    private func row(_ item: MacCourseSidebarItem, title: String, systemImage: String) -> some View {
        let isSelected = selectedItem == item
        return Button {
            select(item)
        } label: {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                .padding(.horizontal, 6)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Status, not a primary action: the agent's own settings stay one click
    /// away, while app settings live in the app menu (⌘,).
    private var agentStatus: some View {
        Button(action: onOpenAgentSettings) {
            HStack(spacing: 8) {
                AgentIconView(kind: store.selectedAgentID ?? "codex", size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text((store.selectedAgentID ?? "codex").titleDisplayLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Circle().fill(connectionTint).frame(width: 6, height: 6)
                        Text(connectionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Agent and iCloud settings")
        .accessibilityLabel("Course agent, \(connectionLabel)")
        .accessibilityIdentifier("course-home-agent-settings")
        .contextMenu {
            Button("Agent Settings…", action: onOpenAgentSettings)
            Button("Settings…", action: onOpenAppSettings)
                .accessibilityIdentifier("course-home-app-settings")
        }
    }

    private var connectionLabel: String {
        if store.agentNeedsAuthentication { return "Sign in required" }
        switch store.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .idle: return "Not connected"
        case .failed: return "Needs attention"
        }
    }

    private var connectionTint: Color {
        if store.agentNeedsAuthentication { return .orange }
        switch store.connectionState {
        case .connected: return .green
        case .connecting, .idle: return .secondary
        case .failed: return .orange
        }
    }
}

private func macSidebarCourseSymbol(_ course: LearningCourse) -> String {
    let progress = course.progress.isFinite ? course.progress : 0
    return progress >= 1 ? "checkmark.circle" : "book.closed"
}
#endif
