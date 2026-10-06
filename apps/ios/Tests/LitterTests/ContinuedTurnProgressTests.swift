import XCTest
@testable import Litter

final class ContinuedTurnProgressTests: XCTestCase {
    private let lesson = ContinuedTurnContext(
        agentName: "Codex",
        intent: .writeLesson(title: "Light Reactions", pageID: "page-light")
    )
    private let generic = ContinuedTurnContext(
        agentName: "Codex",
        intent: .generic(title: "Fix flaky login test")
    )

    func testProgressNeverDecreases() {
        var progress = ContinuedTurnProgress()
        var previous = progress.completed
        let inputs: [(ContinuedTurnContext, AppTurnActivity?, AppPlanProgressSnapshot?)] = [
            (lesson, activity(.verifyingCoursePage, written: 1), nil),
            (lesson, nil, nil),
            (generic, nil, plan([.inProgress, .pending, .pending, .pending])),
            (generic, nil, plan([.completed, .completed, .completed, .inProgress])),
            (generic, nil, plan([.pending, .pending])),
            (generic, nil, nil),
            (lesson, activity(.readingCourse, read: 1), nil),
        ]
        for _ in 0..<50 {
            for (context, activity, plan) in inputs {
                let units = progress.tick(context: context, activity: activity, plan: plan)
                XCTAssertGreaterThan(units, previous)
                XCTAssertEqual(units, progress.completed)
                previous = units
            }
        }
        XCTAssertLessThan(previous, ContinuedTurnProgress.total)
    }

    func testProgressStillMovesAfterThreeThousandTicks() {
        var progress = ContinuedTurnProgress()
        var previous = progress.completed
        for tick in 0..<3_000 {
            let units = progress.tick(context: generic, activity: nil, plan: nil)
            XCTAssertGreaterThan(units, previous, "stalled at tick \(tick)")
            previous = units
        }
        XCTAssertLessThan(previous, ContinuedTurnProgress.total)
    }

    func testProgressNeverReachesTotalWithoutSuccess() {
        var progress = ContinuedTurnProgress()
        for _ in 0..<12_000 {
            _ = progress.tick(context: lesson, activity: activity(.verifyingCoursePage, written: 1), plan: nil)
        }
        XCTAssertEqual(progress.completed, ContinuedTurnProgress.total - 1)
    }

    func testPlanCreepStaysBelowTheNextStepFloor() {
        var progress = ContinuedTurnProgress()
        let secondStep = plan([.completed, .inProgress, .pending, .pending])
        // Step 2 of 4 in progress: 500 + 1.5 / 4 × 9000. The next step change
        // (step 2 completed) is at 500 + 2 / 4 × 9000.
        XCTAssertGreaterThanOrEqual(progress.tick(context: generic, activity: nil, plan: secondStep), 3_875)
        // Five minutes of 2 s ticks on one step.
        for _ in 0..<150 {
            XCTAssertLessThan(progress.tick(context: generic, activity: nil, plan: secondStep), 5_000)
        }

        let thirdStep = plan([.completed, .completed, .inProgress, .pending])
        XCTAssertGreaterThanOrEqual(progress.tick(context: generic, activity: nil, plan: thirdStep), 6_125)
    }

    func testLessonMilestonesWithoutAPlan() {
        var progress = ContinuedTurnProgress()
        let start = progress.tick(context: lesson, activity: nil, plan: nil)
        XCTAssertGreaterThanOrEqual(start, 300)
        XCTAssertLessThan(start, 1_500)

        let read = progress.tick(context: lesson, activity: activity(.readingCourse, read: 1), plan: nil)
        XCTAssertGreaterThanOrEqual(read, 1_500)
        XCTAssertLessThan(read, 6_000)

        let writing = progress.tick(
            context: lesson,
            activity: activity(.writingCoursePage, pageId: "page-light", read: 2),
            plan: nil
        )
        XCTAssertGreaterThanOrEqual(writing, 6_000)
        XCTAssertLessThan(writing, 8_500)

        let written = progress.tick(
            context: lesson,
            activity: activity(.thinking, isRunning: false, read: 2, written: 1),
            plan: nil
        )
        XCTAssertGreaterThanOrEqual(written, 8_500)
        XCTAssertLessThan(written, 9_000)

        let verifying = progress.tick(
            context: lesson,
            activity: activity(.verifyingCoursePage, pageId: "page-light", read: 2, written: 1),
            plan: nil
        )
        XCTAssertGreaterThanOrEqual(verifying, 9_000)
        XCTAssertLessThan(verifying, 9_500)
    }

    func testGenericTurnCreepsTowardSixtyPercent() {
        var progress = ContinuedTurnProgress()
        var units: Int64 = 0
        for _ in 0..<100 {
            units = progress.tick(context: generic, activity: activity(.runningCommand), plan: nil)
        }
        XCTAssertGreaterThan(units, 3_000)
        XCTAssertLessThan(units, 6_000)
    }

    // MARK: - Helpers

    private func plan(_ statuses: [AppPlanStepStatus]) -> AppPlanProgressSnapshot {
        AppPlanProgressSnapshot(
            turnId: "turn-1",
            explanation: nil,
            plan: statuses.enumerated().map { index, status in
                AppPlanStep(step: "Step \(index + 1)", status: status)
            }
        )
    }

    private func activity(
        _ kind: AppTurnActivityKind,
        pageId: String? = nil,
        isRunning: Bool = true,
        read: UInt32 = 0,
        written: UInt32 = 0
    ) -> AppTurnActivity {
        AppTurnActivity(
            kind: kind,
            subject: nil,
            pageId: pageId,
            isRunning: isRunning,
            unitCount: 0,
            stepCount: 1,
            coursePagesRead: read,
            coursePagesWritten: written
        )
    }
}
