import XCTest
@testable import DoGoodCore

final class AllowanceEngineTests: XCTestCase {
    func testTrajectoryTracksBonusesDeductionsAndDebtWithoutClamping() {
        let start = Date(timeIntervalSince1970: 1000)
        let week = UUID()
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: week, amountCents: 1500, createdAt: start),
            AllowanceEngine.bonusEntry(weekId: week, title: "Helped", amountCents: 200, createdAt: start.addingTimeInterval(10)),
            AllowanceEngine.deductionEntry(weekId: week, occurrenceId: UUID(), choreTitle: "Chore", amountCents: 2000, createdAt: start.addingTimeInterval(20))
        ]
        let points = AllowanceEngine.trajectory(for: entries.reversed(), from: start, through: start.addingTimeInterval(30))
        XCTAssertEqual(points.map(\.balanceCents), [1500, 1700, -300, -300])
        XCTAssertEqual(points.last?.date, start.addingTimeInterval(30))
    }

    func testTrajectoryExcludesVoidedAndFutureEntries() {
        let start = Date(timeIntervalSince1970: 1000)
        let week = UUID()
        var voided = AllowanceEngine.deductionEntry(weekId: week, occurrenceId: UUID(), choreTitle: "Excused", amountCents: 500, createdAt: start)
        voided.isVoided = true
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: week, amountCents: 1500, createdAt: start),
            voided,
            AllowanceEngine.bonusEntry(weekId: week, title: "Future", amountCents: 200, createdAt: start.addingTimeInterval(100))
        ]
        XCTAssertEqual(AllowanceEngine.trajectory(for: entries, from: start, through: start.addingTimeInterval(50)).map(\.balanceCents), [1500, 1500])
        XCTAssertTrue(AllowanceEngine.trajectory(for: entries, from: start, through: start.addingTimeInterval(-1)).isEmpty)
    }

    func testSeedStateStartsAtThirteenFifty() {
        let snapshot = SeedData.snapshot()
        let summary = AllowanceEngine.summary(for: snapshot.ledger)

        XCTAssertEqual(summary.weeklyBaseCents, 1_500)
        XCTAssertEqual(summary.activeDeductionCents, 150)
        XCTAssertEqual(summary.bonusCents, 0)
        XCTAssertEqual(summary.currentTotalCents, 1_350)
    }

    func testSeedStateIncludesParentAndChildRoles() {
        let snapshot = SeedData.snapshot()

        XCTAssertTrue(snapshot.members.contains { $0.role == .parent && $0.displayName == "Daddy" })
        XCTAssertTrue(snapshot.members.contains { $0.role == .child && $0.displayName == "Zoe" })
        XCTAssertEqual(snapshot.childProfiles.first?.displayName, "Zoe")
    }

    func testChildInviteReportsExpiredWhenPastExpiration() {
        let now = Date()
        let invite = ChildInvite(
            familyId: SeedData.familyId,
            childProfileId: SeedData.childId,
            childName: "Zoe",
            createdByParentId: SeedData.parentId,
            token: "zoe-test",
            inviteURL: AppBrand.inviteURL(token: "zoe-test"),
            expiresAt: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(invite.resolvedStatus(now: now), .expired)
    }

    func testCompletingAChoreDoesNotIncreaseAllowance() {
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 1_500)
        ]

        XCTAssertEqual(AllowanceEngine.summary(for: entries).currentTotalCents, 1_500)
    }

    func testMissedChoreCreatesDeductionAndExcuseVoidsIt() throws {
        let occurrenceId = UUID()
        let entries = AllowanceEngine.addingDeductionIfNeeded(
            to: [AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 1_500)],
            weekId: SeedData.weekId,
            occurrenceId: occurrenceId,
            choreTitle: "Take dog out",
            amountCents: 50
        )

        XCTAssertEqual(AllowanceEngine.summary(for: entries).currentTotalCents, 1_450)

        let excused = AllowanceEngine.voidingDeduction(in: entries, for: occurrenceId)
        XCTAssertEqual(AllowanceEngine.summary(for: excused).currentTotalCents, 1_500)
    }

    func testDuplicateDeductionsAreIdempotent() {
        let occurrenceId = UUID()
        let base = [AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 1_500)]
        let once = AllowanceEngine.addingDeductionIfNeeded(
            to: base,
            weekId: SeedData.weekId,
            occurrenceId: occurrenceId,
            choreTitle: "Take dog out",
            amountCents: 50
        )
        let twice = AllowanceEngine.addingDeductionIfNeeded(
            to: once,
            weekId: SeedData.weekId,
            occurrenceId: occurrenceId,
            choreTitle: "Take dog out",
            amountCents: 50
        )

        XCTAssertEqual(once.count, twice.count)
        XCTAssertEqual(AllowanceEngine.summary(for: twice).activeDeductionCents, 50)
    }

    func testBonusCanRaiseTotalAboveBaseAllowance() {
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 1_500),
            AllowanceEngine.bonusEntry(weekId: SeedData.weekId, title: "Extra help", amountCents: 200)
        ]

        XCTAssertEqual(AllowanceEngine.summary(for: entries).currentTotalCents, 1_700)
    }

    func testDeductionsBeyondPeriodTotalRollIntoNextPeriod() {
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 500),
            AllowanceEngine.deductionEntry(
                weekId: SeedData.weekId,
                occurrenceId: UUID(),
                choreTitle: "Missed a big task",
                amountCents: 700
            )
        ]

        let summary = AllowanceEngine.summary(for: entries)

        XCTAssertEqual(summary.currentTotalCents, 0)
        XCTAssertEqual(summary.rolloverDebtCents, 200)
        XCTAssertEqual(summary.nextPeriodStartingTotalCents, 300)
    }

    func testDailyActivityKeepsExcusedDeductionsVisibleWithoutChargingThem() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let startsAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 14)))
        let endsAt = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: startsAt))
        let deductionDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startsAt))
        let bonusDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: startsAt))

        let entries = [
            AllowanceEngine.weeklyBaseEntry(
                weekId: SeedData.weekId,
                amountCents: 1_500,
                createdAt: startsAt
            ),
            AllowanceEngine.deductionEntry(
                weekId: SeedData.weekId,
                occurrenceId: UUID(),
                choreTitle: "Missed task",
                amountCents: 100,
                createdAt: deductionDay
            ),
            LedgerEntry(
                weekId: SeedData.weekId,
                type: .deduction,
                title: "Excused task",
                amountCents: 50,
                isVoided: true,
                createdAt: deductionDay
            ),
            AllowanceEngine.bonusEntry(
                weekId: SeedData.weekId,
                title: "Extra help",
                amountCents: 200,
                createdAt: bonusDay
            )
        ]

        let rows = AllowanceEngine.dailyActivity(
            for: entries,
            from: startsAt,
            to: endsAt,
            calendar: calendar
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].startingAllowanceCents, 1_500)
        XCTAssertEqual(rows[0].netChangeCents, 1_500)
        XCTAssertEqual(rows[1].deductionCents, 100)
        XCTAssertEqual(rows[1].excusedDeductionCents, 50)
        XCTAssertEqual(rows[1].netChangeCents, -100)
        XCTAssertEqual(rows[2].bonusCents, 200)
        XCTAssertEqual(rows[2].netChangeCents, 200)
    }

    func testArchivedPeriodPrefersServerFinalBalance() {
        let entries = [
            AllowanceEngine.weeklyBaseEntry(weekId: SeedData.weekId, amountCents: 1_500),
            AllowanceEngine.deductionEntry(
                weekId: SeedData.weekId,
                occurrenceId: UUID(),
                choreTitle: "Missed task",
                amountCents: 100
            )
        ]
        let period = AllowancePeriod(
            id: SeedData.weekId,
            familyId: SeedData.familyId,
            childId: SeedData.childId,
            startsAt: Date().addingTimeInterval(-7 * 24 * 60 * 60),
            endsAt: Date(),
            baseAllowanceCents: 1_500,
            archivedAt: Date(),
            finalBalanceCents: 1_350,
            entries: entries
        )

        XCTAssertTrue(period.isArchived)
        XCTAssertEqual(period.summary.currentTotalCents, 1_400)
        XCTAssertEqual(period.displayedBalanceCents, 1_350)
        XCTAssertEqual(period.closeoutAdjustmentCents, -50)
    }

    func testSeedStateIncludesArchivedAllowanceHistory() {
        let snapshot = SeedData.snapshot()

        XCTAssertEqual(snapshot.allowancePeriods.filter(\.isArchived).count, 1)
        XCTAssertEqual(snapshot.allowancePeriods.first { $0.id == snapshot.weekId }?.entries, snapshot.ledger)
    }

    func testEveryTwoWeekAllowanceUsesAnchorDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 3)))
        let current = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 13)))
        let settings = AllowanceSettings(
            familyId: SeedData.familyId,
            baseAllowanceCents: 1_500,
            cadence: .everyTwoWeeks,
            allowanceWeekday: .friday,
            nextAllowanceDate: anchor
        )

        let next = settings.nextScheduledAllowanceDate(after: current, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: next)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 17)
    }

    func testDailyChoreOccursEveryDay() throws {
        let calendar = Calendar(identifier: .gregorian)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20)))
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 25)))

        XCTAssertTrue(ChoreRecurrence.daily.occurs(on: monday, calendar: calendar))
        XCTAssertTrue(ChoreRecurrence.daily.occurs(on: saturday, calendar: calendar))
    }

    func testWeeklyChoreOnlyOccursOnSelectedDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20)))
        let tuesday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 21)))
        let recurrence = ChoreRecurrence(frequency: .weekly, weekdays: [.monday, .friday])

        XCTAssertTrue(recurrence.occurs(on: monday, calendar: calendar))
        XCTAssertFalse(recurrence.occurs(on: tuesday, calendar: calendar))
        XCTAssertEqual(recurrence.summary, "Mon, Fri")
    }

    func testOneTimeChoreOnlyOccursOnScheduledDate() throws {
        let calendar = Calendar(identifier: .gregorian)
        let scheduled = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 18)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: scheduled))
        let recurrence = ChoreRecurrence(frequency: .once, oneTimeDate: scheduled)

        XCTAssertTrue(recurrence.occurs(on: scheduled, calendar: calendar))
        XCTAssertFalse(recurrence.occurs(on: nextDay, calendar: calendar))
    }
}
