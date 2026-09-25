import XCTest
@testable import DoGoodCore

final class ChorePlanningTests: XCTestCase {
    private let child = UUID()
    private let family = UUID()
    private let week = UUID()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))! }

    private func chore() -> ChoreDefinition {
        ChoreDefinition(familyId: family, childId: child, title: "Room", shortTitle: "Room", description: "",
            instructions: "", expectedEvidence: "", deductionCents: 100, recurrence: .daily, dueTime: "9:00 AM")
    }

    private func task(_ chore: ChoreDefinition, hour: Double) -> TaskOccurrence {
        let due = now.addingTimeInterval(hour * 3600)
        return TaskOccurrence(choreDefinitionId: chore.id, childId: child, weekId: week,
            scheduledAt: due, dueAt: due, expiresAt: due.addingTimeInterval(3600), status: .upcoming)
    }

    func testChoicesAreRealChronologicalAndLimitedToThree() {
        let chore = chore()
        let tasks = [4.0, 2, 1, 3].map { task(chore, hour: $0) }
        let result = ChorePlanning.choices(occurrences: tasks, chores: [chore], plans: [], childId: child, settledWeeks: [], now: now, calendar: calendar)
        XCTAssertEqual(result.map(\.dueAt), [1.0, 2, 3].map { now.addingTimeInterval($0 * 3600) })
    }

    func testChoicesExcludePastFutureReviewedSettledAndOtherChildren() {
        let chore = chore()
        var submitted = task(chore, hour: 1); submitted.status = .submitted
        var sibling = task(chore, hour: 2); sibling.childId = UUID()
        let tasks = [task(chore, hour: -1), task(chore, hour: 24), submitted, sibling]
        XCTAssertTrue(ChorePlanning.choices(occurrences: tasks, chores: [chore], plans: [], childId: child, settledWeeks: [], now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(ChorePlanning.choices(occurrences: [task(chore, hour: 1)], chores: [chore], plans: [], childId: child, settledWeeks: [week], now: now, calendar: calendar).isEmpty)
    }

    func testActivePlansAreExcludedButClearedPlansCanBeChosenAgain() {
        let chore = chore()
        let task = task(chore, hour: 1)
        var plan = ChildChorePlan(occurrenceId: task.id, childId: child, plannedFor: task.dueAt, createdAt: now, updatedAt: now)
        XCTAssertTrue(ChorePlanning.choices(occurrences: [task], chores: [chore], plans: [plan], childId: child, settledWeeks: [], now: now, calendar: calendar).isEmpty)
        plan.cancelledAt = now
        XCTAssertEqual(ChorePlanning.choices(occurrences: [task], chores: [chore], plans: [plan], childId: child, settledWeeks: [], now: now, calendar: calendar).count, 1)
    }

    func testPausedArchivedAndMissingChoresAreExcluded() {
        var chore = chore()
        let task = task(chore, hour: 1)
        chore.isPaused = true
        XCTAssertTrue(ChorePlanning.choices(occurrences: [task], chores: [chore], plans: [], childId: child, settledWeeks: [], now: now, calendar: calendar).isEmpty)
        chore.isPaused = false; chore.archivedAt = now
        XCTAssertTrue(ChorePlanning.choices(occurrences: [task], chores: [chore], plans: [], childId: child, settledWeeks: [], now: now, calendar: calendar).isEmpty)
        XCTAssertTrue(ChorePlanning.choices(occurrences: [task], chores: [], plans: [], childId: child, settledWeeks: [], now: now, calendar: calendar).isEmpty)
    }
}
