import XCTest
@testable import DoGoodCore

final class ChoreReminderPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private var now: Date { date(2026, 9, 20, 8, 0) }
    private let child = UUID()
    private let family = UUID()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func chore(_ title: String = "Feed dog", time: String = "9:00 AM", recurrence: ChoreRecurrence = .daily) -> ChoreDefinition {
        ChoreDefinition(familyId: family, childId: child, title: title, shortTitle: title, description: "",
                        instructions: "", expectedEvidence: "", deductionCents: 100, recurrence: recurrence, dueTime: time)
    }

    private func occurrence(_ chore: ChoreDefinition, status: TaskOccurrenceStatus) -> TaskOccurrence {
        TaskOccurrence(choreDefinitionId: chore.id, childId: child, weekId: UUID(), scheduledAt: now,
                       dueAt: date(2026, 9, 20, 9, 0), expiresAt: date(2026, 9, 20, 10, 30), status: status)
    }

    func testCompletionCancelsOnlyTodaysOccurrence() {
        let chore = chore()
        for status in [TaskOccurrenceStatus.submitted, .aiReviewed, .approved, .excused, .rejected, .missed] {
            let items = ChoreReminderPlanner.items(chores: [chore], occurrences: [occurrence(chore, status: status)],
                                                   childId: child, now: now, calendar: calendar, days: 2)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.dueAt, date(2026, 9, 21, 9, 0))
        }
    }

    func testCatchUpReminderIsOncePerDayAndRespectsQuietHours() {
        XCTAssertEqual(ChoreReminderPlanner.catchUpReminderDate(now: now, lastScheduledAt: nil, calendar: calendar), date(2026, 9, 20, 17, 0))
        let evening = date(2026, 9, 20, 18, 0)
        XCTAssertEqual(ChoreReminderPlanner.catchUpReminderDate(now: evening, lastScheduledAt: nil, calendar: calendar), date(2026, 9, 20, 18, 1))
        XCTAssertNil(ChoreReminderPlanner.catchUpReminderDate(now: evening, lastScheduledAt: date(2026, 9, 20, 17, 0), calendar: calendar))
        XCTAssertEqual(ChoreReminderPlanner.catchUpReminderDate(now: date(2026, 9, 20, 21, 0), lastScheduledAt: nil, calendar: calendar), date(2026, 9, 21, 17, 0))
        XCTAssertNil(ChoreReminderPlanner.catchUpReminderDate(now: evening, lastScheduledAt: date(2026, 9, 21, 17, 0), calendar: calendar))
        XCTAssertEqual(ChoreReminderPlanner.catchUpReminderDate(now: now, lastScheduledAt: date(2026, 9, 19, 17, 0), calendar: calendar), date(2026, 9, 20, 17, 0))
    }

    func testPausedArchivedAndOtherChildAreExcluded() {
        var paused = chore(); paused.isPaused = true
        var archived = chore(); archived.archivedAt = now
        var otherChild = chore(); otherChild.childId = UUID()
        XCTAssertTrue(ChoreReminderPlanner.items(chores: [paused, archived, otherChild], occurrences: [],
                                                childId: child, now: now, calendar: calendar).isEmpty)
    }

    func testWeeklyAndOneTimeSchedules() {
        let monday = chore(recurrence: ChoreRecurrence(frequency: .weekly, weekdays: [.monday]))
        let once = chore(recurrence: ChoreRecurrence(frequency: .once, oneTimeDate: now))
        let items = ChoreReminderPlanner.items(chores: [monday, once], occurrences: [], childId: child,
                                               now: now, calendar: calendar, days: 7)
        XCTAssertEqual(items.map(\.dueAt), [date(2026, 9, 20, 9, 0), date(2026, 9, 21, 9, 0)])
    }

    func testOverlappingAlertsGroupAndSortChronologically() {
        let chores = [chore("B"), chore("A")]
        let items = ChoreReminderPlanner.items(chores: chores, occurrences: [], childId: child,
                                               now: now, calendar: calendar, days: 1)
        let batches = ChoreReminderPlanner.batches(items: items, delays: [:], now: now)
        XCTAssertEqual(batches.map(\.fireAt), [date(2026, 9, 20, 8, 45), date(2026, 9, 20, 9, 0)])
        XCTAssertEqual(batches.map { $0.items.count }, [2, 2])
    }

    func testSnoozeSurvivesReplanningAndDoesNotChangeDueDate() {
        let items = ChoreReminderPlanner.items(chores: [chore()], occurrences: [], childId: child,
                                               now: now, calendar: calendar, days: 1)
        let delay = [items[0].id: ChoreReminderDelay(until: date(2026, 9, 20, 9, 15))]
        let batches = ChoreReminderPlanner.batches(items: items, delays: delay, now: date(2026, 9, 20, 8, 46))
        XCTAssertEqual(batches.map(\.fireAt), [date(2026, 9, 20, 9, 15)])
        XCTAssertEqual(batches[0].items[0].dueAt, date(2026, 9, 20, 9, 0))
        XCTAssertTrue(ChoreReminderPlanner.batches(items: [], delays: delay, now: now).isEmpty)
        let lastSecond = items[0].expiresAt.addingTimeInterval(-1)
        let finalDelay = [items[0].id: ChoreReminderDelay(until: lastSecond)]
        let finalBatches = ChoreReminderPlanner.batches(items: items, delays: finalDelay,
                                                       now: items[0].expiresAt.addingTimeInterval(-30))
        XCTAssertEqual(finalBatches.map(\.fireAt), [lastSecond])
    }

    func testHomeDeferralDoesNotSuppressTomorrow() {
        let items = ChoreReminderPlanner.items(chores: [chore()], occurrences: [], childId: child,
                                               now: now, calendar: calendar, days: 2)
        let delays = [items[0].id: ChoreReminderDelay(until: items[0].expiresAt, atHome: true)]
        let batches = ChoreReminderPlanner.batches(items: items, delays: delays, now: now)
        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { $0.items[0].id == items[1].id })
    }

    func testPendingBudgetKeepsEarliestAlerts() {
        let items = ChoreReminderPlanner.items(chores: [chore()], occurrences: [], childId: child,
                                               now: now, calendar: calendar)
        let batches = ChoreReminderPlanner.batches(items: items, delays: [:], now: now, limit: 3)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.last?.fireAt, date(2026, 9, 21, 8, 45))
    }

    func testReminderBeforeMidnightAndDaylightSavingTime() {
        let early = chore(time: "12:05 AM")
        let items = ChoreReminderPlanner.items(chores: [early], occurrences: [], childId: child,
                                               now: now, calendar: calendar, days: 2)
        let batches = ChoreReminderPlanner.batches(items: items, delays: [:], now: now)
        XCTAssertEqual(batches.first?.fireAt, date(2026, 9, 20, 23, 50))
        let fall = date(2026, 10, 31, 8, 0)
        let dstItems = ChoreReminderPlanner.items(chores: [chore()], occurrences: [], childId: child,
                                                  now: fall, calendar: calendar, days: 3)
        XCTAssertEqual(dstItems.map { calendar.component(.hour, from: $0.dueAt) }, [9, 9, 9])
    }
}
