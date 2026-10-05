#if targetEnvironment(macCatalyst)
import SwiftUI

struct MacCourseLibraryView: View {
    let courses: [LearningCourse]
    let resumableDraft: CourseDraftResumePresentation?
    let onOpenCourse: (String) -> Void
    let onResumeDraft: () -> Void
    let onNewCourse: () -> Void

    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 18, alignment: .top)]

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleCourses: [LearningCourse] {
        guard !searchQuery.isEmpty else { return courses }
        return courses.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || $0.subtitle.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if searchQuery.isEmpty {
                    if let resumableDraft {
                        MacCourseDraftBanner(presentation: resumableDraft, action: onResumeDraft)
                    }

                    if let course = courses.first {
                        MacContinueLearningCard(course: course) {
                            onOpenCourse(course.id)
                        }
                    }
                }

                if courses.isEmpty {
                    emptyLibrary
                } else if visibleCourses.isEmpty {
                    emptySearch
                } else {
                    courseGrid
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 1140, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("course-library-root")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("My Courses")
                        .font(.system(size: 30, weight: .bold))
                    Text("Pick up where you left off, or learn something new.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onNewCourse) {
                    Label("New Course", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .fixedSize()
                .accessibilityIdentifier("new-course-button")
            }

            searchField
                .frame(maxWidth: 360)
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search your courses", text: $searchText)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Search your courses")
                .accessibilityIdentifier("course-library-search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear course search")
                .accessibilityIdentifier("course-library-search-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var courseGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(searchQuery.isEmpty ? "All courses" : "Search results")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(visibleCourses.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.05), in: Capsule())
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(visibleCourses) { course in
                    MacLibraryCourseCard(course: course) {
                        onOpenCourse(course.id)
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 76, height: 76)
                .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 7) {
                Text("What would you like to learn?")
                    .font(.system(size: 21, weight: .semibold))
                Text("Create your first course and make it your own, one lesson at a time.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Create a Course", action: onNewCourse)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4)
                .accessibilityIdentifier("course-library-empty-create")
        }
        .padding(40)
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("course-library-empty")
    }

    private var emptySearch: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("No matching courses")
                .font(.system(size: 18, weight: .semibold))
            Text("Try a different title or topic.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button("Clear Search") {
                searchText = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityIdentifier("course-library-search-empty")
    }
}

private struct MacContinueLearningCard: View {
    let course: LearningCourse
    let action: () -> Void
    @State private var isHovered = false

    private var progress: Double { macLibraryProgress(course.progress) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                MacCourseLibraryArtwork(accentHex: course.accentHex, isFeatured: true)
                    .frame(width: 122, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 11) {
                    Text("CONTINUE LEARNING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(.blue)
                    Text(course.title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    MacCourseLibraryMetadata(course: course)
                    HStack(spacing: 12) {
                        ProgressView(value: progress)
                            .tint(.blue)
                            .frame(maxWidth: 180)
                        Text(macLibraryProgressLabel(progress))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(isHovered ? 0.16 : 0.09), in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.blue.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continue learning, \(course.title)")
        .accessibilityValue(macLibraryProgressLabel(progress))
        .accessibilityHint("Opens this course")
        .accessibilityIdentifier("continue-course-\(course.id)")
    }
}

private struct MacLibraryCourseCard: View {
    let course: LearningCourse
    let action: () -> Void
    @State private var isHovered = false

    private var progress: Double { macLibraryProgress(course.progress) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                MacCourseLibraryArtwork(accentHex: course.accentHex, isFeatured: false)
                    .frame(height: 88)
                    .overlay(alignment: .topTrailing) {
                        if progress >= 1 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                    }

                VStack(alignment: .leading, spacing: 10) {
                    Text(course.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

                    if !course.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(course.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    }

                    MacCourseLibraryMetadata(course: course)
                        .padding(.top, 2)

                    HStack(spacing: 10) {
                        ProgressView(value: progress)
                            .tint(Color(hex: course.accentHex))
                        Text(progress >= 1 ? "Done" : "\(Int(progress * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .padding(.top, 3)
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isHovered ? Color.blue.opacity(0.4) : Color.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.08 : 0), radius: 10, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(course.title)
        .accessibilityValue("\(course.lessonCount) lessons, \(macLibraryProgressLabel(progress))")
        .accessibilityHint("Opens this course")
        .accessibilityIdentifier("course-\(course.id)")
    }
}

private struct MacCourseLibraryMetadata: View {
    let course: LearningCourse

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                lessonCount
                if !course.duration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(course.duration, systemImage: "clock")
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                lessonCount
                if !course.duration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label(course.duration, systemImage: "clock")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private var lessonCount: some View {
        Label(course.lessonCount == 1 ? "1 lesson" : "\(course.lessonCount) lessons", systemImage: "rectangle.stack")
    }
}

private struct MacCourseDraftBanner: View {
    let presentation: CourseDraftResumePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: presentation.isAgentWorking ? "ellipsis.message" : "square.and.pencil")
                    .font(.system(size: 19))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.courseTitle ?? "Your course draft")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(presentation.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Text("Resume draft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.blue.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continue-course-draft-button")
        .accessibilityValue(presentation.isAgentWorking ? "agent-working" : "saved")
    }
}

private struct MacCourseLibraryArtwork: View {
    let accentHex: String
    let isFeatured: Bool

    var body: some View {
        GeometryReader { geometry in
            let accent = Color(hex: accentHex)
            ZStack {
                LinearGradient(
                    colors: [accent.opacity(0.9), accent, accent.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .stroke(.white.opacity(0.13), lineWidth: 1)
                    .frame(width: geometry.size.width * 0.75)
                    .offset(x: geometry.size.width * 0.33, y: -geometry.size.height * 0.35)
                Circle()
                    .fill(.white.opacity(0.07))
                    .frame(width: geometry.size.width * 0.9)
                    .offset(x: -geometry.size.width * 0.4, y: geometry.size.height * 0.55)
                Image(systemName: "book.pages")
                    .font(.system(size: isFeatured ? 40 : 30, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
                    .rotationEffect(.degrees(-8))
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

private func macLibraryProgress(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
}

private func macLibraryProgressLabel(_ progress: Double) -> String {
    if progress >= 1 { return "Completed" }
    if progress <= 0 { return "Ready to begin" }
    return "\(Int(progress * 100))% complete"
}
#endif
