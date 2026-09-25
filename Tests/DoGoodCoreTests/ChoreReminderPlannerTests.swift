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

    func testCombinedBudgetReservesCriticalAlertsAndOtherRequests() {
        let chores = (0..<70).map {
            ReminderQueueCandidate(id: "chore\($0)", fireAt: now.addingTimeInterval(Double($0)), priority: .chore)
        }
        let special: [ReminderQueueCandidate] = [
            .init(id: "nudge", fireAt: now, priority: .immediate),
            .init(id: "payday", fireAt: now.addingTimeInterval(604800), priority: .allowance),
            .init(id: "catchup", fireAt: now.addingTimeInterval(3600), priority: .catchUp)
        ]
        let result = ChoreReminderPlanner.selectedNotificationIDs(chores + special, otherPendingCount: 5)
        XCTAssertEqual(result.count, 55)
        XCTAssertTrue(Set(special.map(\.id)).isSubset(of: result))
        XCTAssertTrue(result.contains("chore51"))
        XCTAssertFalse(result.contains("chore52"))
        XCTAssertTrue(ChoreReminderPlanner.selectedNotificationIDs(chores, otherPendingCount: 60).isEmpty)
    }

    func testQueueDeduplicatesAndBreaksTiesDeterministically() {
        let candidates: [ReminderQueueCandidate] = [
            .init(id: "b", fireAt: now, priority: .chore),
            .init(id: "a", fireAt: now, priority: .chore),
            .init(id: "b", fireAt: now, priority: .chore)
        ]
        XCTAssertEqual(ChoreReminderPlanner.selectedNotificationIDs(candidates, otherPendingCount: 59), ["a"])
        XCTAssertEqual(ChoreReminderPlanner.selectedNotificationIDs(candidates.reversed(), otherPendingCount: 58), ["a", "b"])
    }

    private func locationItem(_ id: String, due: Date? = nil, latitude: Double = 34) -> ChoreReminderItem {
        let due = due ?? date(2026, 9, 20, 9, 0)
        return ChoreReminderItem(id: id, choreId: UUID(), title: id, dueAt: due,
            expiresAt: due.addingTimeInterval(5400), offsets: [15, 0],
            location: ChoreLocation(name: "School", latitude: latitude, longitude: -118, leaveReminderMinutes: 30))
    }

    func testColocatedDestinationsShareOneRegionAndLargestRadius() {
        let first = locationItem("first")
        var second = locationItem("second", latitude: 34.000001)
        second.location?.radiusMeters = 500
        let regions = ChoreReminderPlanner.regions(items: [first, second], delays: [:], home: nil, alertedIDs: [], now: now)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].items.count, 2)
        XCTAssertEqual(regions[0].location.radiusMeters, 500)
    }

    func testRegionBudgetReservesHomeAheadOfDestinations() {
        let items = (0..<25).map { locationItem("item\($0)", latitude: 34 + Double($0) / 100) }
        let last = items.last!
        let delays = [last.id: ChoreReminderDelay(until: last.expiresAt, atHome: true)]
        let home = ChoreLocation(name: "Home", latitude: 35, longitude: -118)
        let regions = ChoreReminderPlanner.regions(items: items, delays: delays, home: home,
            alertedIDs: [], now: now, otherRegionCount: 2)
        XCTAssertEqual(regions.count, 18)
        XCTAssertEqual(regions.first?.homeItemIDs, [last.id])
        XCTAssertTrue(ChoreReminderPlanner.regions(items: items, delays: delays, home: home,
            alertedIDs: [], now: now, otherRegionCount: 20).isEmpty)
    }

    func testArrivalChecksTimeWindowAndSnoozeAtActualEntry() {
        let current = locationItem("today")
        let future = locationItem("tomorrow", due: date(2026, 9, 21, 9, 0))
        let region = ChoreReminderPlanner.regions(items: [current, future], delays: [:], home: nil,
            alertedIDs: [], now: now)[0]
        XCTAssertTrue(ChoreReminderPlanner.arrivalItems(in: region, delays: [:], now: now).isEmpty)
        let arrival = date(2026, 9, 20, 8, 30)
        XCTAssertEqual(ChoreReminderPlanner.arrivalItems(in: region, delays: [:], now: arrival).map(\.id), ["today"])
        let delays = [current.id: ChoreReminderDelay(until: arrival.addingTimeInterval(600))]
        XCTAssertTrue(ChoreReminderPlanner.arrivalItems(in: region, delays: delays, now: arrival).isEmpty)
        XCTAssertTrue(ChoreReminderPlanner.arrivalItems(in: region, delays: [:], now: current.expiresAt).isEmpty)
    }

    func testHomeArrivalRequiresUnexpiredActiveDeferral() {
        let item = locationItem("home")
        let delays = [item.id: ChoreReminderDelay(until: item.expiresAt, atHome: true)]
        let region = ChoreReminderPlanner.regions(items: [item], delays: delays, home: item.location,
            alertedIDs: [], now: now)[0]
        XCTAssertEqual(ChoreReminderPlanner.arrivalItems(in: region, delays: delays, now: now).map(\.id), [item.id])
        XCTAssertTrue(ChoreReminderPlanner.arrivalItems(in: region, delays: [:], now: now).isEmpty)
        XCTAssertTrue(ChoreReminderPlanner.arrivalItems(in: region, delays: delays, now: item.expiresAt).isEmpty)
    }

    func testExpiredAlreadyAlertedAndInvalidDestinationsAreNotMonitored() {
        let expired = locationItem("expired", due: now.addingTimeInterval(-7200))
        let alerted = locationItem("alerted")
        var invalid = locationItem("invalid")
        invalid.location?.latitude = 100
        XCTAssertTrue(ChoreReminderPlanner.regions(items: [expired, alerted, invalid], delays: [:], home: nil,
            alertedIDs: [alerted.id], now: now).isEmpty)
    }
}
