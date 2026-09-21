import Foundation

public struct ChoreReminderItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var choreId: UUID
    public var title: String
    public var dueAt: Date
    public var expiresAt: Date
    public var offsets: [Int]
    public var location: ChoreLocation?
}

public struct ChoreReminderDelay: Codable, Equatable, Sendable {
    public var until: Date
    public var atHome: Bool

    public init(until: Date, atHome: Bool = false) {
        self.until = until
        self.atHome = atHome
    }
}

public struct ChoreReminderBatch: Equatable, Sendable {
    public var fireAt: Date
    public var items: [ChoreReminderItem]
}

public enum ChoreReminderPlanner {
    public static func items(
        chores: [ChoreDefinition], occurrences: [TaskOccurrence], childId: UUID,
        now: Date, calendar: Calendar = .current, days: Int = 14
    ) -> [ChoreReminderItem] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        var result: [ChoreReminderItem] = []
        let today = calendar.startOfDay(for: now)
        let known = Dictionary(grouping: occurrences.filter { $0.childId == childId }) {
            key(choreId: $0.choreDefinitionId, date: $0.dueAt, calendar: calendar)
        }
        for chore in chores where chore.childId == childId && !chore.isPaused && chore.archivedAt == nil {
            guard let time = formatter.date(from: chore.dueTime) else { continue }
            let clock = calendar.dateComponents([.hour, .minute], from: time)
            for dayOffset in 0..<max(0, days) {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                      chore.recurrence.occurs(on: day, calendar: calendar),
                      let dueAt = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                               second: 0, of: day) else { continue }
                let id = key(choreId: chore.id, date: day, calendar: calendar)
                let occurrence = known[id]?.max { $0.updatedAt < $1.updatedAt }
                guard occurrence?.status.isOpen ?? true else { continue }
                let actualDue = occurrence?.dueAt ?? dueAt
                let expiresAt = occurrence?.expiresAt ?? actualDue.addingTimeInterval(Double(chore.dueWindowMinutes) * 60)
                guard expiresAt > now else { continue }
                var offsets = chore.reminderOffsetsMinutes
                if let location = chore.location,
                   location.leaveReminderMinutes > 0,
                   !offsets.contains(location.leaveReminderMinutes) {
                    offsets.append(location.leaveReminderMinutes)
                }
                result.append(ChoreReminderItem(id: id, choreId: chore.id, title: chore.title,
                                                dueAt: actualDue, expiresAt: expiresAt,
                                                offsets: offsets,
                                                location: chore.location))
            }
        }
        return result.sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
    }

    public static func batches(
        items: [ChoreReminderItem], delays: [String: ChoreReminderDelay], now: Date,
        limit: Int = 56
    ) -> [ChoreReminderBatch] {
        var grouped: [Date: [String: ChoreReminderItem]] = [:]
        for item in items where item.expiresAt > now {
            let delay = delays[item.id]
            if delay?.atHome == true { continue }
            var dates = Set(item.offsets.filter { $0 >= 0 }.map { item.dueAt.addingTimeInterval(Double(-$0) * 60) })
            if let delay {
                dates = dates.filter { $0 >= delay.until }
                dates.insert(delay.until)
            }
            for date in dates where date > now && date < item.expiresAt {
                // Chores sharing a minute produce one notification, including snoozed chores.
                let rounded = Date(timeIntervalSince1970: ceil(date.timeIntervalSince1970 / 60) * 60)
                let minute = min(rounded, item.expiresAt.addingTimeInterval(-1))
                guard minute > now else { continue }
                grouped[minute, default: [:]][item.id] = item
            }
        }
        return grouped.keys.sorted().prefix(max(0, limit)).map { date in
            ChoreReminderBatch(fireAt: date, items: grouped[date, default: [:]].values.sorted {
                ($0.dueAt, $0.id) < ($1.dueAt, $1.id)
            })
        }
    }

    public static func key(choreId: UUID, date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(choreId.uuidString).\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }
}
