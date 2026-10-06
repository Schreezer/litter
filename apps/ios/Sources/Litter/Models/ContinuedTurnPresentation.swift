import Foundation

/// The job a continued-processing task is doing, chosen by the caller that
/// starts the turn. The banner title names this job for the life of the task;
/// Rust's typed `AppTurnActivity` supplies what is happening now.
struct ContinuedTurnContext: Equatable, Sendable {
    enum Intent: Equatable, Sendable {
        case writeLesson(title: String?, pageID: String?)
        case exploreTopic(title: String, pageID: String?)
        case answerQuestion(pageTitle: String?)
        case courseChat(courseTitle: String?)
        case generic(title: String?)
    }

    var agentName: String
    var intent: Intent
    /// Page titles from the course's learning path, used when Rust reports
    /// only a page ID.
    var pageTitlesByID: [String: String] = [:]

    /// A generic turn is named by its thread's explicit title, else by the
    /// first line the learner typed. Later lines are never used: when the
    /// first line is an envelope, the whole text is internal.
    static func genericTitle(threadTitle: String?, typedText: String) -> String? {
        if let threadTitle = ContinuedTurnBannerFormatter.cleanedTitle(threadTitle) {
            return threadTitle
        }
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ContinuedTurnBannerFormatter.isEnvelope(text),
              let firstLine = text.split(whereSeparator: \.isNewline).first else { return nil }
        return ContinuedTurnBannerFormatter.cleanedTitle(String(firstLine))
    }
}

extension ContinuedTurnContext.Intent {
    fileprivate var targetPageID: String? {
        switch self {
        case .writeLesson(_, let pageID), .exploreTopic(_, let pageID):
            pageID
        case .answerQuestion, .courseChat, .generic:
            nil
        }
    }

    fileprivate var writesPage: Bool {
        switch self {
        case .writeLesson, .exploreTopic: true
        case .answerQuestion, .courseChat, .generic: false
        }
    }

    fileprivate var isExploration: Bool {
        if case .exploreTopic = self { return true }
        return false
    }

    fileprivate var isCourse: Bool {
        if case .generic = self { return false }
        return true
    }

    /// The lesson or topic a page-writing intent names.
    fileprivate var pageTitle: String? {
        switch self {
        case .writeLesson(let title, _): title
        case .exploreTopic(let title, _): title
        case .answerQuestion, .courseChat, .generic: nil
        }
    }
}

struct ContinuedTurnBanner: Equatable, Sendable {
    let title: String
    let subtitle: String
}

/// Learner-facing copy for the system's continued-processing banner.
///
/// Course turns show lesson titles, page titles and course search queries.
/// Commands, file names and reasoning headlines appear only for generic
/// chats. Lengths are counted in grapheme clusters; the system's real widths
/// still need checking on a device.
enum ContinuedTurnBannerFormatter {
    static let titleLimit = 34
    static let subtitleLimit = 44

    static func submitted(_ context: ContinuedTurnContext) -> ContinuedTurnBanner {
        ContinuedTurnBanner(
            title: title(for: context),
            subtitle: String(localized: "Getting started")
        )
    }

    /// Subtitle precedence: the learner is needed, then the plan step, then
    /// the current activity.
    static func running(
        context: ContinuedTurnContext,
        activity: AppTurnActivity?,
        plan: AppPlanProgressSnapshot?,
        needsApproval: Bool,
        needsInput: Bool
    ) -> ContinuedTurnBanner {
        let subtitle: String
        if needsApproval {
            subtitle = String(localized: "Needs your approval")
        } else if needsInput {
            subtitle = String(localized: "Waiting for your answer")
        } else if let step = planStep(plan, context: context, activity: activity, limit: subtitleLimit) {
            subtitle = step
        } else if let activity {
            subtitle = activityPhrase(activity, context: context, limit: subtitleLimit)
        } else {
            let agent = agentName(context)
            subtitle = truncated(String(localized: "\(agent) is working"), limit: subtitleLimit)
        }
        return ContinuedTurnBanner(title: title(for: context), subtitle: subtitle)
    }

    /// The final banner and the value for `setTaskCompleted(success:)`. A
    /// missing outcome is treated as completed.
    static func finished(
        context: ContinuedTurnContext,
        activity: AppTurnActivity?,
        outcome: TurnOutcome?
    ) -> (banner: ContinuedTurnBanner, success: Bool) {
        switch outcome {
        case .some(.failed):
            let banner = ContinuedTurnBanner(
                title: failedTitle(context),
                subtitle: String(localized: "Open Learnfold to try again")
            )
            return (banner, false)
        case .some(.interrupted):
            let banner = ContinuedTurnBanner(
                title: stoppedTitle(context),
                subtitle: String(localized: "Pick it up again in Learnfold")
            )
            return (banner, false)
        case .some(.completed), .none:
            return (completedBanner(context, activity: activity), true)
        }
    }

    static func activityPhrase(
        _ activity: AppTurnActivity,
        context: ContinuedTurnContext?,
        limit: Int
    ) -> String {
        let intent = context?.intent
        let writesPage = intent?.writesPage ?? false
        let showsWorkDetails = intent?.isCourse != true
        let isTarget = activity.pageId != nil && activity.pageId == intent?.targetPageID
        let subject = cleaned(activity.subject)
        let pageTitle = subject ?? activity.pageId
            .flatMap { context?.pageTitlesByID[$0] }
            .flatMap { cleanedTitle($0) }
        let wroteLesson = writesPage && activity.coursePagesWritten >= 1
        let units = Int(activity.unitCount)

        let phrase: String
        switch activity.kind {
        case .starting:
            phrase = String(localized: "Getting started")
        case .thinking:
            if intent?.isCourse == true {
                let pagesRead = Int(activity.coursePagesRead)
                if wroteLesson {
                    phrase = String(localized: "Wrapping up")
                } else if pagesRead == 1 {
                    phrase = String(localized: "Thinking · read 1 page")
                } else if pagesRead > 1 {
                    phrase = String(localized: "Thinking · read \(pagesRead) pages")
                } else {
                    phrase = String(localized: "Thinking it through")
                }
            } else if let subject {
                phrase = subject
            } else if let context {
                let agent = agentName(context)
                phrase = String(localized: "\(agent) is thinking")
            } else {
                phrase = String(localized: "Thinking")
            }
        case .responding:
            if wroteLesson {
                phrase = String(localized: "Wrapping up")
            } else if case .answerQuestion = intent {
                phrase = String(localized: "Writing your answer")
            } else {
                phrase = String(localized: "Writing a reply")
            }
        case .readingCourse:
            if isTarget {
                phrase = String(localized: "Reading the current draft")
            } else if let pageTitle {
                phrase = sentence(pageTitle, limit: limit) { String(localized: "Reading “\($0)”") }
            } else if activity.stepCount >= 2 {
                let count = Int(activity.stepCount)
                phrase = String(localized: "Reading course pages (\(count))")
            } else {
                phrase = String(localized: "Reading a course page")
            }
        case .readingCourseOutline:
            phrase = String(localized: "Reading the course outline")
        case .searchingCourse:
            if let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Searching for “\($0)”") }
            } else {
                phrase = String(localized: "Searching the course")
            }
        case .verifyingCoursePage:
            if isTarget {
                phrase = String(localized: "Checking the saved lesson")
            } else if let pageTitle {
                phrase = sentence(pageTitle, limit: limit) { String(localized: "Checking “\($0)”") }
            } else {
                phrase = String(localized: "Checking a saved page")
            }
        case .writingCoursePage:
            if isTarget || (activity.pageId == nil && writesPage) {
                phrase = String(localized: "Saving the lesson")
            } else if let pageTitle {
                phrase = sentence(pageTitle, limit: limit) { String(localized: "Saving “\($0)”") }
            } else {
                phrase = String(localized: "Saving a course page")
            }
        case .updatingCourseDetails:
            if let pageTitle {
                phrase = sentence(pageTitle, limit: limit) { String(localized: "Updating “\($0)” details") }
            } else {
                phrase = String(localized: "Updating page details")
            }
        case .addingCoursePages:
            if units >= 2 {
                phrase = String(localized: "Adding \(units) pages")
            } else if let pageTitle {
                phrase = sentence(pageTitle, limit: limit) { String(localized: "Adding “\($0)”") }
            } else {
                phrase = String(localized: "Adding a page")
            }
        case .organizingCourse:
            phrase = String(localized: "Reorganizing pages")
        case .savingCourseChanges:
            phrase = String(localized: "Finishing a large save")
        case .planningCourse:
            phrase = String(localized: "Preparing your course plan")
        case .checkingCourseFiles:
            phrase = String(localized: "Checking your source files")
        case .runningCommand:
            if showsWorkDetails, let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Running \($0)") }
            } else {
                phrase = String(localized: "Running a command")
            }
        case .readingFiles:
            let count = max(units, Int(activity.stepCount))
            if showsWorkDetails, let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Reading \($0)") }
            } else if count >= 2 {
                phrase = String(localized: "Reading \(count) files")
            } else {
                phrase = String(localized: "Reading files")
            }
        case .searchingFiles:
            if showsWorkDetails, let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Searching files for “\($0)”") }
            } else {
                phrase = String(localized: "Searching files")
            }
        case .editingFiles:
            if showsWorkDetails, let subject {
                if units >= 2 {
                    let others = units - 1
                    phrase = sentence(subject, limit: limit) { String(localized: "Editing \($0) +\(others) more") }
                } else {
                    phrase = sentence(subject, limit: limit) { String(localized: "Editing \($0)") }
                }
            } else if units >= 2 {
                phrase = String(localized: "Editing \(units) files")
            } else {
                phrase = String(localized: "Editing files")
            }
        case .searchingWeb:
            if let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Searching the web for “\($0)”") }
            } else {
                phrase = String(localized: "Searching the web")
            }
        case .usingTool:
            if let subject {
                phrase = sentence(subject, limit: limit) { String(localized: "Using \($0)") }
            } else {
                phrase = String(localized: "Using a tool")
            }
        case .delegating:
            if units >= 2 {
                phrase = String(localized: "Working with \(units) helpers")
            } else if units == 1 {
                phrase = String(localized: "Working with a helper")
            } else {
                phrase = String(localized: "Working with helpers")
            }
        case .generatingImage:
            phrase = String(localized: "Generating an image")
        }
        return truncated(phrase, limit: limit)
    }

    /// Builds `prefix“quoted”suffix` within `limit` grapheme clusters. Only the
    /// quoted text is shortened, so the verb, both quotes and any
    /// "Step k of n ·" prefix survive. Without quoted text the tail is cut.
    static func fit(prefix: String, quoted: String?, suffix: String, limit: Int) -> String {
        guard let quoted, !quoted.isEmpty else {
            return truncated(prefix + suffix, limit: limit)
        }
        return shorten(prefix: prefix + "“", subject: quoted, suffix: "”" + suffix, limit: limit)
    }

    /// One line of learner-safe text from Rust subjects or model-written plan
    /// steps, or nil. Rust already cleans activity subjects; this also keeps
    /// internal tool names, JSON and envelopes off the lock screen.
    static func cleaned(_ text: String?) -> String? {
        guard let collapsed = collapsedLine(text) else { return nil }
        let lowered = collapsed.lowercased()
        if lowered.contains("native-editor")
            || lowered.contains("learnfold_")
            || lowered.contains("mcp__")
            || collapsed.hasPrefix("MCP ")
            || collapsed.hasPrefix("{")
            || collapsed.hasPrefix("[")
            || collapsed.hasPrefix("<") {
            return nil
        }
        return collapsed
    }

    /// One line of a title Swift supplies: lesson, page, course and thread
    /// titles, agent names and the learner's typed text. These are the
    /// learner's own words, so only internal envelopes and JSON are dropped.
    static func cleanedTitle(_ text: String?) -> String? {
        guard let collapsed = collapsedLine(text), !isEnvelope(collapsed) else { return nil }
        return collapsed
    }

    /// An internal prompt envelope or a JSON object or array, not prose.
    static func isEnvelope(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("<learnfold_") { return true }
        guard text.hasPrefix("{") || text.hasPrefix("["),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any] || object is [Any]
    }

    private static func collapsedLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: - Titles

    private static func title(for context: ContinuedTurnContext) -> String {
        switch context.intent {
        case .writeLesson(let title, _):
            if let title = cleanedTitle(title) {
                return sentence(title, limit: titleLimit) { String(localized: "Writing “\($0)”") }
            }
            return String(localized: "Writing a lesson")
        case .exploreTopic(let title, _):
            if let title = cleanedTitle(title) {
                return sentence(title, limit: titleLimit) { String(localized: "Exploring “\($0)”") }
            }
            return String(localized: "Exploring a new topic")
        case .answerQuestion(let pageTitle):
            if let pageTitle = cleanedTitle(pageTitle) {
                return sentence(pageTitle, limit: titleLimit) { String(localized: "Answering about “\($0)”") }
            }
            return String(localized: "Answering your question")
        case .courseChat(let courseTitle):
            if let courseTitle = cleanedTitle(courseTitle) {
                return sentence(courseTitle, limit: titleLimit) { String(localized: "Working on “\($0)”") }
            }
            return String(localized: "Working on your course")
        case .generic(let title):
            if let title = cleanedTitle(title) {
                return truncated(title, limit: titleLimit)
            }
            let agent = agentName(context)
            return truncated(String(localized: "\(agent) is working"), limit: titleLimit)
        }
    }

    private static func completedBanner(
        _ context: ContinuedTurnContext,
        activity: AppTurnActivity?
    ) -> ContinuedTurnBanner {
        let agent = agentName(context)
        let wrotePage = (activity?.coursePagesWritten ?? 0) >= 1
        switch context.intent {
        case .writeLesson, .exploreTopic:
            let isExploration = context.intent.isExploration
            let title = cleanedTitle(context.intent.pageTitle)
            if wrotePage {
                let bannerTitle = title.map { title in
                    sentence(title, limit: titleLimit) { String(localized: "“\($0)” is ready") }
                } ?? (isExploration
                    ? String(localized: "Your new page is ready")
                    : String(localized: "Your lesson is ready"))
                let subtitle = isExploration
                    ? String(localized: "Open Learnfold to read it")
                    : String(localized: "Open Learnfold to start the lesson")
                return ContinuedTurnBanner(title: bannerTitle, subtitle: subtitle)
            }
            let subtitle = title.map { title in
                sentence(title, limit: subtitleLimit) { String(localized: "Open Learnfold to check “\($0)”") }
            } ?? (isExploration
                ? String(localized: "Open Learnfold to check the page")
                : String(localized: "Open Learnfold to check the lesson"))
            return ContinuedTurnBanner(
                title: truncated(String(localized: "\(agent) finished"), limit: titleLimit),
                subtitle: subtitle
            )
        case .answerQuestion(let pageTitle):
            let subtitle = cleanedTitle(pageTitle).map { page in
                sentence(page, limit: subtitleLimit) { String(localized: "About “\($0)”") }
            } ?? String(localized: "Open Learnfold to read it")
            return ContinuedTurnBanner(
                title: String(localized: "Your answer is ready"),
                subtitle: subtitle
            )
        case .courseChat(let courseTitle):
            return ContinuedTurnBanner(
                title: truncated(String(localized: "\(agent) replied"), limit: titleLimit),
                subtitle: cleanedTitle(courseTitle).map { truncated($0, limit: subtitleLimit) }
                    ?? String(localized: "Open Learnfold to read it")
            )
        case .generic(let title):
            return ContinuedTurnBanner(
                title: truncated(String(localized: "\(agent) finished"), limit: titleLimit),
                subtitle: cleanedTitle(title).map { truncated($0, limit: subtitleLimit) }
                    ?? String(localized: "Your task is ready")
            )
        }
    }

    private static func failedTitle(_ context: ContinuedTurnContext) -> String {
        if let object = quotedObject(context) {
            return sentence(object, limit: titleLimit) { String(localized: "Couldn’t finish “\($0)”") }
        }
        switch context.intent {
        case .writeLesson: return String(localized: "Couldn’t finish the lesson")
        case .exploreTopic: return String(localized: "Couldn’t finish the page")
        case .answerQuestion: return String(localized: "Couldn’t finish your answer")
        case .courseChat: return String(localized: "Couldn’t finish the reply")
        case .generic: return String(localized: "Couldn’t finish the task")
        }
    }

    private static func stoppedTitle(_ context: ContinuedTurnContext) -> String {
        if let object = quotedObject(context) {
            return sentence(object, limit: titleLimit) { String(localized: "Stopped “\($0)”") }
        }
        switch context.intent {
        case .writeLesson: return String(localized: "Stopped the lesson")
        case .exploreTopic: return String(localized: "Stopped the page")
        case .answerQuestion: return String(localized: "Stopped answering")
        case .courseChat: return String(localized: "Stopped the reply")
        case .generic: return String(localized: "Stopped the task")
        }
    }

    /// What a failed or stopped banner names: the lesson, topic or thread.
    private static func quotedObject(_ context: ContinuedTurnContext) -> String? {
        switch context.intent {
        case .writeLesson, .exploreTopic:
            cleanedTitle(context.intent.pageTitle)
        case .generic(let title):
            cleanedTitle(title)
        case .answerQuestion, .courseChat:
            nil
        }
    }

    // MARK: - Plan

    /// `Step k of n · {step}`, where k is the first in-progress step, otherwise
    /// the step after the completed ones. Step text the lock screen should not
    /// show gives way to the activity phrase, or to the bare counter.
    private static func planStep(
        _ plan: AppPlanProgressSnapshot?,
        context: ContinuedTurnContext,
        activity: AppTurnActivity?,
        limit: Int
    ) -> String? {
        guard let steps = plan?.plan, !steps.isEmpty else { return nil }
        let count = steps.count
        let current = steps.firstIndex { $0.status == .inProgress }.map { $0 + 1 }
            ?? min(steps.filter { $0.status == .completed }.count + 1, count)
        let text = cleaned(steps[current - 1].step).flatMap { text in
            context.intent.isCourse && !isLearnerSafeCourseStep(text) ? nil : text
        }
        if let text = text ?? activity.map({ activityPhrase($0, context: context, limit: limit) }) {
            return sentence(text, limit: limit) { String(localized: "Step \(current) of \(count) · \($0)") }
        }
        return String(localized: "Step \(current) of \(count)")
    }

    /// Course prompts hand the model page IDs, tool names and page
    /// properties, which then show up in its plan. Course steps that carry
    /// any of them stay off the lock screen.
    private static func isLearnerSafeCourseStep(_ text: String) -> Bool {
        let internalPatterns = [
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            "\\bmcp\\b",
            "\\b\\w+_\\w+\\b",
            "\\w=\\S",
            "\\b(update-page|create-pages|move-pages|duplicate-page|get-async-task)\\b",
        ]
        return !internalPatterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    // MARK: - Length

    private static let subjectMarker = "\u{E000}"

    private static func agentName(_ context: ContinuedTurnContext) -> String {
        cleanedTitle(context.agentName) ?? "Codex"
    }

    /// Renders a localized sentence around `subject`, shortening only the
    /// subject when the sentence is longer than `limit`.
    private static func sentence(
        _ subject: String,
        limit: Int,
        _ template: (String) -> String
    ) -> String {
        let frame = template(subjectMarker)
        guard let marker = frame.range(of: subjectMarker) else {
            return truncated(template(subject), limit: limit)
        }
        return shorten(
            prefix: String(frame[..<marker.lowerBound]),
            subject: subject,
            suffix: String(frame[marker.upperBound...]),
            limit: limit
        )
    }

    private static func shorten(prefix: String, subject: String, suffix: String, limit: Int) -> String {
        let whole = prefix + subject + suffix
        guard whole.count > limit else { return whole }
        let budget = limit - prefix.count - suffix.count
        guard budget >= 2 else { return truncated(whole, limit: limit) }
        return prefix + truncated(subject, limit: budget) + suffix
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return String(text.prefix(max(limit, 0))) }
        let kept = text.prefix(limit - 1)
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? String(kept) : trimmed) + "…"
    }
}

/// Progress for the system's continued-processing ring, out of `total` units.
///
/// Units never decrease and move on every tick, because the system may
/// expire a task that looks stalled. Each tick creeps toward the current
/// band's ceiling; once there, it trickles one unit at a time. Only the
/// controller's success path reaches 100%.
struct ContinuedTurnProgress {
    static let total: Int64 = 10_000

    private(set) var completed: Int64 = 1

    mutating func tick(
        context: ContinuedTurnContext,
        activity: AppTurnActivity?,
        plan: AppPlanProgressSnapshot?
    ) -> Int64 {
        let band = Self.band(context: context, activity: activity, plan: plan)
        completed = max(completed, band.floor)
        if completed < band.ceiling - 1 {
            completed = min(band.ceiling - 1, completed + max(1, (band.ceiling - completed) / 40))
        } else {
            completed = min(Self.total - 1, completed + 1)
        }
        return completed
    }

    private static func band(
        context: ContinuedTurnContext,
        activity: AppTurnActivity?,
        plan: AppPlanProgressSnapshot?
    ) -> (floor: Int64, ceiling: Int64) {
        if let steps = plan?.plan, !steps.isEmpty {
            // An in-progress step counts as half done; the ceiling is the
            // floor the plan reaches at its next step change.
            let done = steps.reduce(into: 0.0) { result, step in
                switch step.status {
                case .completed: result += 1
                case .inProgress: result += 0.5
                case .pending: break
                }
            }
            let count = Double(steps.count)
            return (planUnits(done / count), planUnits((done + 0.5) / count))
        }
        guard context.intent.writesPage else { return (0, 6_000) }
        guard let activity else { return (300, 6_000) }
        if activity.kind == .verifyingCoursePage { return (9_000, 9_500) }
        if activity.coursePagesWritten >= 1 { return (8_500, 9_000) }
        if activity.kind == .writingCoursePage, activity.isRunning { return (6_000, 8_500) }
        if activity.coursePagesRead >= 1 { return (1_500, 6_000) }
        return (300, 6_000)
    }

    /// Plan steps occupy 5...95% of the ring.
    private static func planUnits(_ fraction: Double) -> Int64 {
        min(500 + Int64(min(fraction, 1) * 9_000), 9_500)
    }
}
