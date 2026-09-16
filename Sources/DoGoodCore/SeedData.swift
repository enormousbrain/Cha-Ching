import Foundation

public enum SeedData {
    public static let familyId = UUID(uuidString: "87D72069-308B-44CB-BBBE-0C27F5665B5B")!
    public static let parentId = UUID(uuidString: "E3C87538-7C70-4D20-86F3-F0E01E8AEE43")!
    public static let childId = UUID(uuidString: "A14615DD-424E-44FB-B2E6-C61DA3CE680C")!
    public static let weekId = UUID(uuidString: "AE85BD8B-335A-4444-A523-64B61EC5117E")!
    public static let familyName = "Barrueta Family"
    public static let childName = "Zoe"
    public static let parentName = "Daddy"
    public static let weeklyAllowanceCents = 1_500

    public static func snapshot(now: Date = Date()) -> SeedSnapshot {
        let chores = choreDefinitions(now: now)
        let occurrencePairs = chores.enumerated().map { index, chore in
            occurrence(for: chore, index: index, now: now)
        }

        var occurrences = occurrencePairs
        let feedEvening = occurrences.firstIndex { $0.choreDefinitionId == chores[1].id }
        let submissionId = UUID(uuidString: "5DE0C2E0-6991-4BC6-B35F-2F66F23E9118")!
        var feedEveningOccurrenceId = occurrences[1].id

        if let feedEvening {
            occurrences[feedEvening].status = .aiReviewed
            occurrences[feedEvening].submissionId = submissionId
            feedEveningOccurrenceId = occurrences[feedEvening].id
        }

        let submissions = [
            ChoreSubmission(
                id: submissionId,
                taskOccurrenceId: feedEveningOccurrenceId,
                childId: childId,
                imageName: "mock-dog-bowl",
                submittedAt: now.addingTimeInterval(-12 * 60),
                aiResult: AIReviewResult(
                    completed: true,
                    confidence: 0.92,
                    reason: "The photo appears to show a filled dog bowl.",
                    retakeSuggested: false,
                    reviewedAt: now.addingTimeInterval(-10 * 60)
                )
            )
        ]

        let priorMissedDogOut = UUID(uuidString: "E5EEEB1B-8657-4990-B913-E735EBEB0885")!
        let priorMissedBathroom = UUID(uuidString: "9754F28D-F0DB-4527-B224-69034F6F15C1")!

        let ledger = [
            AllowanceEngine.weeklyBaseEntry(weekId: weekId, amountCents: weeklyAllowanceCents, createdAt: now),
            AllowanceEngine.deductionEntry(
                weekId: weekId,
                occurrenceId: priorMissedDogOut,
                choreTitle: "Take dog out (PM)",
                amountCents: 50,
                createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60)
            ),
            AllowanceEngine.deductionEntry(
                weekId: weekId,
                occurrenceId: priorMissedBathroom,
                choreTitle: "Keep bathroom neat",
                amountCents: 100,
                createdAt: now.addingTimeInterval(-24 * 60 * 60)
            )
        ]

        let settings = allowanceSettings(now: now)
        let currentPeriodEnd = settings.nextScheduledAllowanceDate(after: now)
        let currentPeriodStart = Calendar.current.date(
            byAdding: .day,
            value: -settings.cadence.intervalDays,
            to: currentPeriodEnd
        ) ?? now.addingTimeInterval(-7 * 24 * 60 * 60)
        let archivedPeriodEnd = currentPeriodStart
        let archivedPeriodStart = Calendar.current.date(
            byAdding: .day,
            value: -settings.cadence.intervalDays,
            to: archivedPeriodEnd
        ) ?? currentPeriodStart.addingTimeInterval(-7 * 24 * 60 * 60)
        let archivedWeekId = UUID(uuidString: "E923C3B2-A00B-4DE0-AC31-34AB30BA7E56")!
        let archivedLedger = [
            AllowanceEngine.weeklyBaseEntry(
                weekId: archivedWeekId,
                amountCents: weeklyAllowanceCents,
                createdAt: archivedPeriodStart
            ),
            AllowanceEngine.deductionEntry(
                weekId: archivedWeekId,
                occurrenceId: UUID(uuidString: "7AC8BC81-B9D2-4D35-B2ED-733E7CD1E9BD")!,
                choreTitle: "Feed dog (Evening)",
                amountCents: 100,
                createdAt: archivedPeriodStart.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            AllowanceEngine.bonusEntry(
                weekId: archivedWeekId,
                title: "Helped with groceries",
                amountCents: 200,
                note: "Above and beyond",
                createdAt: archivedPeriodStart.addingTimeInterval(4 * 24 * 60 * 60)
            )
        ]
        let allowancePeriods = [
            AllowancePeriod(
                id: weekId,
                familyId: familyId,
                childId: childId,
                startsAt: currentPeriodStart,
                endsAt: currentPeriodEnd,
                baseAllowanceCents: weeklyAllowanceCents,
                entries: ledger
            ),
            AllowancePeriod(
                id: archivedWeekId,
                familyId: familyId,
                childId: childId,
                startsAt: archivedPeriodStart,
                endsAt: archivedPeriodEnd,
                baseAllowanceCents: weeklyAllowanceCents,
                archivedAt: archivedPeriodEnd,
                finalBalanceCents: 1_600,
                entries: archivedLedger
            )
        ]

        return SeedSnapshot(
            familyId: familyId,
            parentId: parentId,
            childId: childId,
            weekId: weekId,
            familyName: familyName,
            childName: childName,
            parentName: parentName,
            weeklyAllowanceCents: weeklyAllowanceCents,
            allowanceSettings: settings,
            members: members(now: now),
            childProfiles: childProfiles(now: now),
            childInvites: [],
            parentInvites: [],
            evidencePolicy: evidencePolicy(),
            chores: chores,
            occurrences: occurrences,
            submissions: submissions,
            ledger: ledger,
            allowancePeriods: allowancePeriods
        )
    }

    public static func snapshotWithBonus(now: Date = Date()) -> SeedSnapshot {
        var snapshot = snapshot(now: now)
        let bonus = AllowanceEngine.bonusEntry(
            weekId: weekId,
            title: "Helped without being asked",
            amountCents: 200,
            note: "Above and beyond",
            createdAt: now
        )
        snapshot.ledger.append(bonus)
        if let index = snapshot.allowancePeriods.firstIndex(where: { $0.id == weekId }) {
            snapshot.allowancePeriods[index].entries.append(bonus)
        }
        return snapshot
    }

    private static func members(now: Date) -> [FamilyMember] {
        [
            FamilyMember(
                familyId: familyId,
                userId: parentId,
                role: .parent,
                displayName: parentName,
                createdAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
            ),
            FamilyMember(
                familyId: familyId,
                userId: childId,
                role: .child,
                displayName: childName,
                createdAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
            )
        ]
    }

    private static func childProfiles(now: Date) -> [ChildProfile] {
        [
            ChildProfile(
                id: childId,
                familyId: familyId,
                displayName: childName,
                linkedUserId: childId,
                createdByParentId: parentId,
                createdAt: now.addingTimeInterval(-7 * 24 * 60 * 60),
                updatedAt: now.addingTimeInterval(-7 * 24 * 60 * 60)
            )
        ]
    }

    private static func allowanceSettings(now: Date) -> AllowanceSettings {
        AllowanceSettings(
            familyId: familyId,
            baseAllowanceCents: weeklyAllowanceCents,
            cadence: .weekly,
            allowanceWeekday: .friday,
            nextAllowanceDate: nextDate(for: .friday, after: now)
        )
    }

    private static func evidencePolicy() -> FamilyEvidencePolicy {
        FamilyEvidencePolicy(familyId: familyId)
    }

    private static func choreDefinitions(now: Date) -> [ChoreDefinition] {
        [
            ChoreDefinition(
                id: UUID(uuidString: "3854A6A8-2492-4C01-938F-3141F43A151D")!,
                familyId: familyId,
                childId: childId,
                title: "Feed Dog (AM)",
                shortTitle: "Feed dog",
                description: "One full bowl of food in the morning.",
                instructions: "Give the dog one full bowl of food. Make sure the bowl is full and the area is clean.",
                expectedEvidence: "A full dog bowl and the surrounding floor area.",
                deductionCents: 100,
                dueTime: "7:30 AM"
            ),
            ChoreDefinition(
                id: UUID(uuidString: "E6ED5751-E087-4032-86D5-7E0673C9DF95")!,
                familyId: familyId,
                childId: childId,
                title: "Feed Dog (Evening)",
                shortTitle: "Feed dog",
                description: "One full bowl of food in the evening.",
                instructions: "Give the dog one full bowl of food. Show the full bowl and a clean area around it.",
                expectedEvidence: "A full dog bowl and nearby floor.",
                deductionCents: 100,
                dueTime: "6:00 PM"
            ),
            ChoreDefinition(
                id: UUID(uuidString: "2D6B5F5C-D309-4B9C-965E-E80D5F2F935D")!,
                familyId: familyId,
                childId: childId,
                title: "Take Dog Out (AM)",
                shortTitle: "Dog outing",
                description: "Morning dog outing.",
                instructions: "Take the dog outside and make sure the door is secure when you come back.",
                expectedEvidence: "Dog leash or door area after the outing.",
                deductionCents: 50,
                dueTime: "8:00 AM"
            ),
            ChoreDefinition(
                id: UUID(uuidString: "42AE975A-C1AE-406B-B8F2-F58F4B59379B")!,
                familyId: familyId,
                childId: childId,
                title: "Take Dog Out (PM)",
                shortTitle: "Dog outing",
                description: "Evening dog outing.",
                instructions: "Take the dog outside before the evening gets late.",
                expectedEvidence: "Dog leash or door area after the outing.",
                deductionCents: 50,
                dueTime: "8:00 PM"
            ),
            ChoreDefinition(
                id: UUID(uuidString: "96F10B79-B340-455D-983F-15B26C5799CB")!,
                familyId: familyId,
                childId: childId,
                title: "Keep Bedroom Floor Clean",
                shortTitle: "Bedroom floor",
                description: "Daily bedroom floor check.",
                instructions: "Pick up trash, clothes, and anything that blocks the floor.",
                expectedEvidence: "A clear bedroom floor.",
                deductionCents: 100,
                dueTime: "8:30 PM"
            ),
            ChoreDefinition(
                id: UUID(uuidString: "87E5EF9C-7F27-42C9-97ED-A905E87D616A")!,
                familyId: familyId,
                childId: childId,
                title: "Keep Bathroom Neat",
                shortTitle: "Bathroom neat",
                description: "Daily bathroom check.",
                instructions: "Clear the sink, hang towels, and make sure the counter is tidy.",
                expectedEvidence: "A tidy bathroom sink and counter.",
                deductionCents: 100,
                dueTime: "8:30 PM"
            )
        ]
    }

    private static func occurrence(for chore: ChoreDefinition, index: Int, now: Date) -> TaskOccurrence {
        let due = date(onSameDayAs: now, time: chore.dueTime)
        let statuses: [TaskOccurrenceStatus] = [.approved, .aiReviewed, .approved, .due, .approved, .upcoming]

        return TaskOccurrence(
            id: UUID(uuidString: [
                "C9D7976D-238C-41E8-BA39-4BE6C4486C35",
                "AFD9B680-A35F-481D-87F4-7A4F21D26B06",
                "264F6398-A2EA-4C34-9E1D-8D23182A4607",
                "861D5A5B-602E-492C-AE91-9A8F42664D30",
                "8534408B-1E9B-4462-9696-A0C99E1EF62F",
                "24D71C45-5AC4-4701-A406-54F4E9846E16"
            ][index])!,
            choreDefinitionId: chore.id,
            childId: childId,
            weekId: weekId,
            scheduledAt: due,
            dueAt: due,
            expiresAt: Calendar.current.date(byAdding: .minute, value: chore.dueWindowMinutes, to: due) ?? due,
            status: statuses[index],
            createdAt: now,
            updatedAt: now
        )
    }

    private static func date(onSameDayAs date: Date, time: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let parsedTime = formatter.date(from: time) else {
            return date
        }

        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dayComponents.hour = timeComponents.hour
        dayComponents.minute = timeComponents.minute
        return calendar.date(from: dayComponents) ?? date
    }

    private static func nextDate(for weekday: AllowanceWeekday, after date: Date) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysUntil = (weekday.rawValue - currentWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntil, to: today) ?? today
    }
}
