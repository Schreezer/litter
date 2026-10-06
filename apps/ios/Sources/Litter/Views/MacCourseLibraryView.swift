#if targetEnvironment(macCatalyst)
import SwiftUI

struct MacCourseLibraryView: View {
    let courses: [LearningCourse]
    let resumableDraft: CourseDraftResumePresentation?
    let onOpenCourse: (String) -> Void
    let onResumeDraft: () -> Void
    let onNewCourse: () -> Void

    @State private var searchText = ""

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16, alignment: .top)]

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
        Group {
            if courses.isEmpty {
                emptyLibrary
            } else if visibleCourses.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .accessibilityIdentifier("course-library-search-empty")
            } else {
                library
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Courses")
        .accessibilityIdentifier("course-library-root")
    }

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if searchQuery.isEmpty {
                    if let resumableDraft {
                        MacCourseDraftBanner(presentation: resumableDraft, action: onResumeDraft)
                    }

                    if let course = courses.first {
                        section("Continue Learning") {
                            MacContinueLearningCard(course: course) {
                                onOpenCourse(course.id)
                            }
                        }
                    }
                }

                section(searchQuery.isEmpty ? "All Courses" : "Results", count: visibleCourses.count) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(visibleCourses) { course in
                            MacLibraryCourseCard(course: course) {
                                onOpenCourse(course.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func section<Body: View>(
        _ title: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let count {
                    Text("\(count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Courses Yet", systemImage: "books.vertical")
        } description: {
            Text("Create your first course and shape it one lesson at a time.")
        } actions: {
            Button("New Course", action: onNewCourse)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-library-empty-create")
        }
        .accessibilityIdentifier("course-library-empty")
    }
}

private struct MacContinueLearningCard: View {
    let course: LearningCourse
    let action: () -> Void
    @State private var isHovered = false

    private var progress: Double { macLibraryProgress(course.progress) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                MacCourseLibraryArtwork(accentHex: course.accentHex, isFeatured: true)
                    .frame(width: 96, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(course.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !course.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(course.subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    MacCourseLibraryMetadata(course: course)
                    HStack(spacing: 10) {
                        ProgressView(value: progress)
                            .frame(maxWidth: 200)
                        Text(macLibraryProgressLabel(progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(progress > 0 ? "Resume" : "Start")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macLibraryCardSurface(isHovered: isHovered, cornerRadius: 12)
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
                    .frame(height: 64)
                    .overlay(alignment: .topTrailing) {
                        if progress >= 1 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(course.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2, reservesSpace: true)

                    Text(course.subtitle.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1, reservesSpace: true)

                    Spacer(minLength: 4)

                    MacCourseLibraryMetadata(course: course, compact: true)

                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                        Text(progress >= 1 ? "Done" : "\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .macLibraryCardSurface(isHovered: isHovered, cornerRadius: 10)
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
    var compact = false

    private var duration: String {
        course.duration.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 12) {
            Label(course.lessonCount == 1 ? "1 lesson" : "\(course.lessonCount) lessons", systemImage: "doc.text")
            if !duration.isEmpty {
                Label(duration, systemImage: "clock")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(compact ? .caption : .subheadline)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .help(duration)
    }
}

private struct MacCourseDraftBanner: View {
    let presentation: CourseDraftResumePresentation
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.isAgentWorking ? "ellipsis.message" : "square.and.pencil")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.courseTitle ?? "Your course draft")
                    .font(.headline)
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button("Resume Draft", action: action)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("continue-course-draft-button")
                .accessibilityValue(presentation.isAgentWorking ? "agent-working" : "saved")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macLibraryCardSurface(isHovered: false, cornerRadius: 10)
    }
}

private extension View {
    func macLibraryCardSurface(isHovered: Bool, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(isHovered ? 0.18 : 0.08), lineWidth: 1)
            }
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: isHovered)
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
                    .font(.system(size: isFeatured ? 34 : 24, weight: .light))
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
