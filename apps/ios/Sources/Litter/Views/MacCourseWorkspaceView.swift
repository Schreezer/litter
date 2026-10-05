#if targetEnvironment(macCatalyst)
import SwiftUI

/// Desktop navigation stays mounted while the existing course routes change.
struct MacCourseWorkspaceView<Content: View>: View {
    @Bindable var store: CourseExperienceStore
    let onNewCourse: () -> Void
    let onOpenAppSettings: () -> Void
    let onOpenAgentSettings: () -> Void
    @ViewBuilder let content: () -> Content

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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("mac-course-workspace")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Learnfold")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 24)

            Button(action: onNewCourse) {
                Label("New course", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .help("Create a course (⌘N)")
            .accessibilityIdentifier("mac-sidebar-new-course")

            sidebarRow(
                title: "My courses",
                icon: "square.grid.2x2",
                selected: store.navigationPath.isEmpty
            ) { store.navigationPath.removeAll() }
            .padding(.horizontal, 10)
            .accessibilityIdentifier("mac-sidebar-library")

            if let draft = store.resumableCourseDraft {
                sidebarRow(
                    title: "Course draft",
                    icon: draft.isAgentWorking ? "ellipsis.message" : "square.and.pencil",
                    selected: store.navigationPath.last == .newCourse && selectedCourseID == nil
                ) { store.resumeCourseDraft() }
                .padding(.horizontal, 10)
                .accessibilityIdentifier("mac-sidebar-draft")
            }

            HStack {
                Text("COURSES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                Spacer()
                Text("\(store.courses.count)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 9)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.courses) { course in
                        sidebarRow(
                            title: course.title,
                            icon: "book.closed",
                            selected: selectedCourseID == course.id,
                            tint: Color(hex: course.accentHex)
                        ) { store.navigationPath = [.course(course.id)] }
                        .help(course.title)
                        .accessibilityIdentifier("mac-sidebar-course-\(course.id)")
                    }
                    if store.courses.isEmpty {
                        Text("Your courses will appear here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().padding(.horizontal, 16)

            Button(action: onOpenAgentSettings) {
                HStack(spacing: 10) {
                    AgentIconView(kind: store.selectedAgentID ?? "codex", size: 27)
                    VStack(alignment: .leading, spacing: 3) {
                        Text((store.selectedAgentID ?? "codex").titleDisplayLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Circle().fill(connectionTint).frame(width: 5, height: 5)
                            Text(connectionLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Agent and iCloud settings")
            .accessibilityLabel("Course agent menu")
            .accessibilityIdentifier("course-home-agent-settings")
            .padding(.horizontal, 10)

            sidebarRow(title: "Settings", icon: "gearshape", selected: false, action: onOpenAppSettings)
                .accessibilityLabel("App Settings")
                .accessibilityIdentifier("course-home-app-settings")
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-course-sidebar")
    }

    private func sidebarRow(
        title: String,
        icon: String,
        selected: Bool,
        tint: Color = .blue,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.blue : tint)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.blue : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.blue.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
#endif
