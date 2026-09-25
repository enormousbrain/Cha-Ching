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

public struct ReminderQueueCandidate: Equatable, Sendable {
    public enum Priority: Int, Sendable { case immediate, allowance, catchUp, chore }
    public var id: String
    public var fireAt: Date
    public var priority: Priority

    public init(id: String, fireAt: Date, priority: Priority) {
        self.id = id; self.fireAt = fireAt; self.priority = priority
    }
}

public struct ChoreReminderRegion: Equatable, Sendable, Identifiable {
    public var id: String
    public var location: ChoreLocation
    public var items: [ChoreReminderItem]
    public var homeItemIDs: Set<String>
}

public enum ChoreReminderPlanner {
    // Leave headroom below iOS's historical pending-request limit.
    public static let notificationBudget = 60
    public static let regionBudget = 20

    public static func selectedNotificationIDs(_ candidates: [ReminderQueueCandidate], otherPendingCount: Int) -> Set<String> {
        let remaining = max(0, notificationBudget - max(0, otherPendingCount))
        let unique = Dictionary(grouping: candidates, by: \.id).compactMap { _, values in
            values.min { ($0.priority.rawValue, $0.fireAt) < ($1.priority.rawValue, $1.fireAt) }
        }
        return Set(unique.sorted {
            ($0.priority.rawValue, $0.fireAt, $0.id) < ($1.priority.rawValue, $1.fireAt, $1.id)
        }.prefix(remaining).map(\.id))
    }

    public static func regions(items: [ChoreReminderItem], delays: [String: ChoreReminderDelay], home: ChoreLocation?,
                               alertedIDs: Set<String>, now: Date, otherRegionCount: Int = 0) -> [ChoreReminderRegion] {
        var grouped: [String: ChoreReminderRegion] = [:]
        func add(_ item: ChoreReminderItem, location: ChoreLocation, isHome: Bool) {
            // Nearby coordinate fixes for the same destination share one region (about 11 m precision).
            let id = "chaching.region.\(Int((location.latitude * 10000).rounded())).\(Int((location.longitude * 10000).rounded()))"
            var region = grouped[id] ?? ChoreReminderRegion(id: id, location: location, items: [], homeItemIDs: [])
            region.location.radiusMeters = max(region.location.radiusMeters, location.radiusMeters)
            region.items.append(item)
            if isHome { region.homeItemIDs.insert(item.id) }
            grouped[id] = region
        }
        for item in items where item.expiresAt > now {
            if delays[item.id]?.atHome == true {
                if let home, home.isValid { add(item, location: home, isHome: true) }
            } else if !alertedIDs.contains(item.id), let location = item.location, location.isValid {
                add(item, location: location, isHome: false)
            }
        }
        return grouped.values.sorted {
            let lhs = ($0.homeItemIDs.isEmpty ? 1 : 0, $0.items.map(\.dueAt).min() ?? .distantFuture, $0.id)
            let rhs = ($1.homeItemIDs.isEmpty ? 1 : 0, $1.items.map(\.dueAt).min() ?? .distantFuture, $1.id)
            return lhs < rhs
        }.prefix(max(0, regionBudget - max(0, otherRegionCount))).map { $0 }
    }

    public static func arrivalItems(in region: ChoreReminderRegion, delays: [String: ChoreReminderDelay], now: Date) -> [ChoreReminderItem] {
        region.items.filter { item in
            guard item.expiresAt > now else { return false }
            if region.homeItemIDs.contains(item.id) { return delays[item.id]?.atHome == true }
            if let delay = delays[item.id], delay.atHome || delay.until > now { return false }
            let leadMinutes = max(15, item.location?.leaveReminderMinutes ?? 0)
            return now >= item.dueAt.addingTimeInterval(-Double(leadMinutes) * 60)
        }.sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
    }

    public static func catchUpReminderDate(now: Date, lastScheduledAt: Date?, calendar: Calendar = .current) -> Date? {
        if let lastScheduledAt, lastScheduledAt >= calendar.startOfDay(for: now) { return nil }
        let today = calendar.startOfDay(for: now)
        guard let evening = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: today),
              let quietTime = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: today) else { return nil }
        let soon = now.addingTimeInterval(60)
        if soon >= quietTime { return calendar.date(byAdding: .day, value: 1, to: evening) }
        return max(evening, soon)
    }

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
