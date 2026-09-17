import Foundation

public enum MutationPersistenceMode: Equatable, Sendable {
    case localPreview
    case remoteRequired
}

@MainActor
public enum MutationCommitter {
    public static func commit(
        mode: MutationPersistenceMode,
        remoteSave: () async throws -> Void,
        localCommit: () -> Void
    ) async throws {
        if mode == .remoteRequired {
            try await remoteSave()
        }

        localCommit()
    }
}

public struct AllowanceSummary: Equatable {
    public var weeklyBaseCents: Int
    public var activeDeductionCents: Int
    public var bonusCents: Int
    public var adjustmentCents: Int
    public var currentTotalCents: Int
    public var rolloverDebtCents: Int

    public var progress: Double {
        guard weeklyBaseCents > 0 else { return 0 }
        return min(1, Double(currentTotalCents) / Double(weeklyBaseCents))
    }

    public var hasRolloverDebt: Bool {
        rolloverDebtCents > 0
    }

    public var nextPeriodStartingTotalCents: Int {
        max(0, weeklyBaseCents - rolloverDebtCents)
    }
}

public enum AllowanceEngine {
    public static func summary(for entries: [LedgerEntry]) -> AllowanceSummary {
        let active = entries.filter { !$0.isVoided }

        let base = active
            .filter { $0.type == .weeklyBase }
            .map(\.amountCents)
            .reduce(0, +)

        let deductions = active
            .filter { $0.type == .deduction }
            .map(\.amountCents)
            .reduce(0, +)

        let bonuses = active
            .filter { $0.type == .bonus }
            .map(\.amountCents)
            .reduce(0, +)

        let adjustments = active
            .filter { $0.type == .adjustment }
            .map(\.amountCents)
            .reduce(0, +)

        let rawTotal = base - deductions + bonuses + adjustments

        return AllowanceSummary(
            weeklyBaseCents: base,
            activeDeductionCents: deductions,
            bonusCents: bonuses,
            adjustmentCents: adjustments,
            currentTotalCents: max(0, rawTotal),
            rolloverDebtCents: max(0, -rawTotal)
        )
    }

    public static func dailyActivity(
        for entries: [LedgerEntry],
        from startsAt: Date,
        to endsAt: Date,
        calendar: Calendar = .current
    ) -> [AllowanceDayActivity] {
        guard startsAt < endsAt else {
            return []
        }

        let entriesByDay = Dictionary(grouping: entries) {
            calendar.startOfDay(for: $0.createdAt)
        }
        var day = calendar.startOfDay(for: startsAt)
        var rows: [AllowanceDayActivity] = []

        while day < endsAt {
            let dayEntries = entriesByDay[day] ?? []
            let activeEntries = dayEntries.filter { !$0.isVoided }
            rows.append(
                AllowanceDayActivity(
                    date: day,
                    startingAllowanceCents: activeEntries
                        .filter { $0.type == .weeklyBase }
                        .reduce(0) { $0 + $1.amountCents },
                    deductionCents: activeEntries
                        .filter { $0.type == .deduction }
                        .reduce(0) { $0 + $1.amountCents },
                    bonusCents: activeEntries
                        .filter { $0.type == .bonus }
                        .reduce(0) { $0 + $1.amountCents },
                    adjustmentCents: activeEntries
                        .filter { $0.type == .adjustment }
                        .reduce(0) { $0 + $1.amountCents },
                    excusedDeductionCents: dayEntries
                        .filter { $0.isVoided && $0.type == .deduction }
                        .reduce(0) { $0 + $1.amountCents },
                    entryCount: dayEntries.count
                )
            )

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = nextDay
        }

        return rows
    }

    public static func deductionExists(in entries: [LedgerEntry], for occurrenceId: UUID) -> Bool {
        entries.contains {
            !$0.isVoided &&
            $0.type == .deduction &&
            $0.relatedOccurrenceId == occurrenceId
        }
    }

    public static func deductionEntry(
        weekId: UUID,
        occurrenceId: UUID,
        choreTitle: String,
        amountCents: Int,
        createdAt: Date = Date()
    ) -> LedgerEntry {
        LedgerEntry(
            weekId: weekId,
            type: .deduction,
            title: "Missed: \(choreTitle)",
            amountCents: amountCents,
            relatedOccurrenceId: occurrenceId,
            createdAt: createdAt
        )
    }

    public static func addingDeductionIfNeeded(
        to entries: [LedgerEntry],
        weekId: UUID,
        occurrenceId: UUID,
        choreTitle: String,
        amountCents: Int,
        createdAt: Date = Date()
    ) -> [LedgerEntry] {
        guard !deductionExists(in: entries, for: occurrenceId) else {
            return entries
        }

        return entries + [
            deductionEntry(
                weekId: weekId,
                occurrenceId: occurrenceId,
                choreTitle: choreTitle,
                amountCents: amountCents,
                createdAt: createdAt
            )
        ]
    }

    public static func voidingDeduction(
        in entries: [LedgerEntry],
        for occurrenceId: UUID
    ) -> [LedgerEntry] {
        entries.map { entry in
            guard entry.type == .deduction, entry.relatedOccurrenceId == occurrenceId else {
                return entry
            }

            var updated = entry
            updated.isVoided = true
            return updated
        }
    }

    public static func weeklyBaseEntry(weekId: UUID, amountCents: Int, createdAt: Date = Date()) -> LedgerEntry {
        LedgerEntry(
            weekId: weekId,
            type: .weeklyBase,
            title: "Starting allowance",
            amountCents: amountCents,
            createdAt: createdAt
        )
    }

    public static func bonusEntry(
        weekId: UUID,
        title: String,
        amountCents: Int,
        note: String? = nil,
        createdAt: Date = Date()
    ) -> LedgerEntry {
        LedgerEntry(
            weekId: weekId,
            type: .bonus,
            title: title,
            amountCents: amountCents,
            note: note,
            createdAt: createdAt
        )
    }
}
