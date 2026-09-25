import CoreLocation
import SwiftUI
import UserNotifications

private struct ReminderSnapshot: Codable {
    var owner: String
    var items: [ChoreReminderItem]
    var goals: [SavingsGoal]? = nil
    var catchUpIds: [UUID]? = nil
    var allowance: AllowanceReminderSchedule? = nil
}

struct AllowanceReminderSchedule: Codable, Equatable {
    var familyId: UUID
    var childName: String
    var date: Date
    var repeatsWeekly: Bool
}

struct ReminderHome: Codable {
    var latitude: Double
    var longitude: Double
}

@MainActor
final class ChoreReminderCenter: NSObject, ObservableObject {
    static let shared = ChoreReminderCenter()
    private static let prefix = "chaching.reminder."
    private static let category = "CHORE_REMINDER"
    private static let homeCategory = "CHORE_REMINDER_HOME"
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private let location = CLLocationManager()
    private var snapshot: ReminderSnapshot?
    private var delays: [String: ChoreReminderDelay] = [:]
    private var scheduleTask: Task<Void, Error>?
    private var revision = 0
    private var alertedArrivalIDs: Set<String> = []
    private var immediateRequests: [String: UNNotificationRequest] = [:]
    private var lastScheduledIDs: Set<String> = []
    private var arrivalsInFlight: Set<String> = []
    private var wantsCurrentLocation = false
    private var onOpen: (([UUID]) -> Void)?
    private var onNudge: ((UUID) -> Void)?
    private var onCatchUp: (() -> Void)?
    @Published private(set) var home: ReminderHome?
    @Published private(set) var homeEnabled = false
    @Published private(set) var isLocating = false
    @Published private(set) var message: String?
    @Published private(set) var scheduledCount = 0
    @Published private(set) var nextReminderAt: Date?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        snapshot = read("snapshot")
        delays = read("delays") ?? [:]
        alertedArrivalIDs = Set(read("alertedArrivalIDs") as [String]? ?? [])
        home = read("home")
        homeEnabled = defaults.bool(forKey: Self.prefix + "homeEnabled")
        location.delegate = self
        locationAuthorization = location.authorizationStatus
    }

    func configure(onOpen: @escaping ([UUID]) -> Void, onNudge: @escaping (UUID) -> Void, onCatchUp: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onNudge = onNudge
        self.onCatchUp = onCatchUp
        center.delegate = self
        registerActions()
        Task {
            let currentUser = SupabaseClientProvider.shared.auth.currentSession?.user.id.uuidString
            if let owner = snapshot?.owner, !owner.hasPrefix((currentUser ?? "signed-out") + ".") {
                await clear()
            } else {
                try? await schedule()
            }
        }
    }

    func update(owner: String, items: [ChoreReminderItem], goals: [SavingsGoal] = [], catchUpIds: [UUID] = [], allowance: AllowanceReminderSchedule? = nil) {
        if snapshot?.owner != owner || snapshot?.items != items || snapshot?.goals != goals || snapshot?.catchUpIds != catchUpIds || snapshot?.allowance != allowance { revision += 1 }
        if let snapshot, snapshot.owner != owner {
            alertedArrivalIDs = []
            immediateRequests = [:]
            delays = [:]
            home = nil
            homeEnabled = false
            persistHome()
        }
        snapshot = ReminderSnapshot(owner: owner, items: items, goals: goals, catchUpIds: catchUpIds, allowance: allowance)
        let ids = Set(items.map(\.id))
        delays = delays.filter { ids.contains($0.key) }
        alertedArrivalIDs.formIntersection(ids)
        save(Array(alertedArrivalIDs), "alertedArrivalIDs")
        save(snapshot, "snapshot")
        save(delays, "delays")
    }

    func clear() async {
        revision += 1
        alertedArrivalIDs = []
        immediateRequests = [:]
        save([String](), "alertedArrivalIDs")
        snapshot = nil
        delays = [:]
        home = nil
        homeEnabled = false
        defaults.removeObject(forKey: Self.prefix + "snapshot")
        defaults.removeObject(forKey: Self.prefix + "delays")
        persistHome()
        for region in location.monitoredRegions where region.identifier.hasPrefix("chaching.region.") {
            location.stopMonitoring(for: region)
        }
        try? await schedule()
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.identifier.hasPrefix("chaching.")
        }.map { $0.request.identifier })
    }

    func schedule() async throws {
        // Serialize notification-center writes so a slower refresh cannot undo a snooze or completion.
        let previous = scheduleTask
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await self.replaceSchedule()
        }
        scheduleTask = task
        try await task.value
    }

    private func replaceSchedule() async throws {
        let revision = self.revision
        let now = Date()
        let items = snapshot?.items.filter { $0.expiresAt > now } ?? []
        let ids = Set(items.map(\.id))
        delays = delays.filter { ids.contains($0.key) }
        if !hasArrivalPermission || !homeEnabled || home == nil {
            // Restore a useful timed alert even when the original due-time reminders have passed.
            for (key, delay) in delays where delay.atHome {
                if let item = items.first(where: { $0.id == key }) {
                    delays[key] = ChoreReminderDelay(until: min(now.addingTimeInterval(60), item.expiresAt.addingTimeInterval(-1)))
                }
            }
        }
        save(delays, "delays")
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard revision == self.revision else { return }
        let managed = pending.filter { $0.identifier.hasPrefix("chaching.") }
        guard let snapshot,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: managed.map(\.identifier))
            stopArrivalRegions()
            lastScheduledIDs = []
            scheduledCount = 0
            nextReminderAt = nil
            return
        }

        let batches = ChoreReminderPlanner.batches(items: items, delays: delays, now: now,
                                                   limit: ChoreReminderPlanner.notificationBudget)
        var requests: [UNNotificationRequest] = batches.map { batch in
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: batch.fireAt)
            return UNNotificationRequest(identifier: Self.prefix + "time.\(Int(batch.fireAt.timeIntervalSince1970))",
                                         content: content(for: batch.items, at: batch.fireAt, home: false),
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        }
        if let allowance = snapshot.allowance {
            var components = Calendar.current.dateComponents(
                allowance.repeatsWeekly ? [.weekday] : [.year, .month, .day], from: allowance.date)
            components.hour = 9
            components.minute = 0
            components.second = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: allowance.repeatsWeekly)
            if trigger.nextTriggerDate() != nil {
                let content = UNMutableNotificationContent()
                content.title = "Allowance day"
                content.body = "\(allowance.childName)'s \(AppBrand.displayName) total is ready to review."
                content.sound = .default
                content.userInfo = ["owner": snapshot.owner, "kind": "allowance"]
                requests.append(UNNotificationRequest(identifier: "chaching.allowance.\(allowance.familyId)",
                    content: content, trigger: trigger))
            }
        }

        let catchUpIdentifier = Self.prefix + "catchup"
        if let missed = snapshot.catchUpIds, !missed.isEmpty {
            let existing = managed.first { $0.identifier == catchUpIdentifier && $0.content.userInfo["owner"] as? String == snapshot.owner }
            let lastAlert: Date? = read("catchup.\(snapshot.owner)")
            let existingDate = (existing?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            if let fireAt = existingDate ?? ChoreReminderPlanner.catchUpReminderDate(now: now, lastScheduledAt: lastAlert) {
                let content = UNMutableNotificationContent()
                content.title = "A little catch-up time"
                content.body = "\(missed.count) missed \(missed.count == 1 ? "chore is" : "chores are") waiting. Take them one at a time, then send them for review."
                content.sound = .default
                content.threadIdentifier = "chaching.catchup"
                content.userInfo = ["kind": "catch_up", "owner": snapshot.owner]
                requests.append(UNNotificationRequest(identifier: catchUpIdentifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt), repeats: false)))
            }
        }

        let deliveredIDs = Set(delivered.map { $0.request.identifier })
        immediateRequests = immediateRequests.filter { id, request in
            request.content.userInfo["owner"] as? String == snapshot.owner
                && !deliveredIDs.contains(id) && isCurrentImmediateRequest(request, now: now, itemIDs: ids)
        }
        var immediate = Dictionary(uniqueKeysWithValues: managed.filter {
            ["task_nudge", "arrival_reminder"].contains($0.content.userInfo["kind"] as? String ?? "")
                && $0.content.userInfo["owner"] as? String == snapshot.owner
                && isCurrentImmediateRequest($0, now: now, itemIDs: ids)
        }.map { ($0.identifier, $0) })
        immediate.merge(immediateRequests) { _, new in new }
        requests.append(contentsOf: immediate.values)

        let candidates = requests.map { request in
            let kind = request.content.userInfo["kind"] as? String
            let priority: ReminderQueueCandidate.Priority =
                kind == "allowance" ? .allowance : kind == "catch_up" ? .catchUp :
                (kind == "task_nudge" || kind == "arrival_reminder") ? .immediate : .chore
            return ReminderQueueCandidate(id: request.identifier,
                fireAt: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? now,
                priority: priority)
        }
        let desired = ChoreReminderPlanner.selectedNotificationIDs(candidates, otherPendingCount: pending.count - managed.count)
        requests = requests.filter { desired.contains($0.identifier) }
        center.removePendingNotificationRequests(withIdentifiers: managed.filter { !desired.contains($0.identifier) }.map(\.identifier))
        lastScheduledIDs = Set(managed.map(\.identifier)).intersection(desired)
        for request in requests {
            guard revision == self.revision else { return }
            if let existing = managed.first(where: { $0.identifier == request.identifier }),
               existing.content.isEqual(request.content), existing.trigger?.isEqual(request.trigger) == true {
                immediateRequests.removeValue(forKey: request.identifier)
                continue
            }
            try await center.add(request)
            lastScheduledIDs.insert(request.identifier)
            immediateRequests.removeValue(forKey: request.identifier)
            if request.identifier == catchUpIdentifier, let fireAt = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                save(fireAt, "catchup.\(snapshot.owner)")
            }
        }
        guard revision == self.revision else { return }
        synchronizeArrivalRegions(now: now)
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
            guard notification.request.identifier.hasPrefix("chaching.") else { return false }
            if notification.request.content.userInfo["owner"] as? String != snapshot.owner { return true }
            let kind = notification.request.content.userInfo["kind"] as? String
            if kind == "catch_up" { return snapshot.catchUpIds?.isEmpty != false }
            if kind == "allowance" || kind == "task_nudge" { return false }
            let keys = notification.request.content.userInfo["items"] as? [String] ?? []
            return !keys.contains(where: ids.contains)
        }.map { $0.request.identifier })
        scheduledCount = requests.count
        nextReminderAt = requests.compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }.min()
    }

    private func isCurrentImmediateRequest(_ request: UNNotificationRequest, now: Date, itemIDs: Set<String>) -> Bool {
        if let expiry = request.content.userInfo["expires_at"] as? Double, expiry <= now.timeIntervalSince1970 { return false }
        if request.content.userInfo["kind"] as? String == "arrival_reminder" {
            return (request.content.userInfo["items"] as? [String] ?? []).contains(where: itemIDs.contains)
        }
        return true
    }

    func enqueueImmediate(_ request: UNNotificationRequest) async throws {
        let owner = request.content.userInfo["owner"] as? String
        guard owner == snapshot?.owner else { throw URLError(.cancelled) }
        let delivered = await center.deliveredNotifications()
        guard owner == snapshot?.owner else { throw URLError(.cancelled) }
        if delivered.contains(where: { $0.request.identifier == request.identifier }) { return }
        immediateRequests[request.identifier] = request
        revision += 1
        try await schedule()
        guard owner == snapshot?.owner, lastScheduledIDs.contains(request.identifier) else {
            throw URLError(.resourceUnavailable)
        }
    }

    private func arrivalRegions(now: Date) -> [ChoreReminderRegion] {
        guard hasArrivalPermission else { return [] }
        let homeLocation = homeEnabled ? home.map {
            ChoreLocation(name: "Home", latitude: $0.latitude, longitude: $0.longitude, leaveReminderMinutes: 0)
        } : nil
        let otherCount = location.monitoredRegions.filter { !$0.identifier.hasPrefix("chaching.region.") }.count
        return ChoreReminderPlanner.regions(items: snapshot?.items ?? [], delays: delays, home: homeLocation,
            alertedIDs: alertedArrivalIDs, now: now, otherRegionCount: otherCount)
    }

    private func stopArrivalRegions() {
        for region in location.monitoredRegions where region.identifier.hasPrefix("chaching.region.") {
            location.stopMonitoring(for: region)
        }
    }

    private func synchronizeArrivalRegions(now: Date) {
        let desired = arrivalRegions(now: now)
        let ids = Set(desired.map(\.id))
        for existing in location.monitoredRegions where existing.identifier.hasPrefix("chaching.region.") && !ids.contains(existing.identifier) {
            location.stopMonitoring(for: existing)
        }
        for plan in desired {
            let maximum = location.maximumRegionMonitoringDistance
            let radius = maximum > 0 ? min(maximum, plan.location.radiusMeters) : plan.location.radiusMeters
            if let existing = location.monitoredRegions.first(where: { $0.identifier == plan.id }) as? CLCircularRegion,
               existing.center.latitude == plan.location.latitude, existing.center.longitude == plan.location.longitude,
               existing.radius == radius { continue }
            if let existing = location.monitoredRegions.first(where: { $0.identifier == plan.id }) {
                location.stopMonitoring(for: existing)
            }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: plan.location.latitude, longitude: plan.location.longitude),
                                          radius: radius, identifier: plan.id)
            region.notifyOnEntry = true
            region.notifyOnExit = false
            location.startMonitoring(for: region)
        }
    }

    private func arrived(in regionID: String) async {
        guard !arrivalsInFlight.contains(regionID), let owner = snapshot?.owner,
              let region = arrivalRegions(now: Date()).first(where: { $0.id == regionID }) else { return }
        let now = Date()
        let items = ChoreReminderPlanner.arrivalItems(in: region, delays: delays, now: now)
        guard !items.isEmpty else { return }
        arrivalsInFlight.insert(regionID)
        defer { arrivalsInFlight.remove(regionID) }
        let isHome = items.contains { region.homeItemIDs.contains($0.id) }
        let content = content(for: items, at: now, home: isHome, destinationArrival: !isHome)
        content.userInfo["kind"] = "arrival_reminder"
        content.userInfo["expires_at"] = items.map(\.expiresAt).max()!.timeIntervalSince1970
        // A repeated region callback or interrupted scheduling attempt reuses the same request.
        let identifier = Self.prefix + "arrival." + regionID + "." + items.map(\.id).sorted().joined(separator: ",")
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                           trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do {
            try await enqueueImmediate(request)
            guard snapshot?.owner == owner else { return }
            for item in items {
                alertedArrivalIDs.insert(item.id)
                if region.homeItemIDs.contains(item.id) { delays.removeValue(forKey: item.id) }
            }
            save(Array(alertedArrivalIDs), "alertedArrivalIDs")
            save(delays, "delays")
            revision += 1
            try await schedule()
        } catch { message = "Couldn't schedule the arrival reminder. Timed reminders remain available." }
    }

    private func content(for items: [ChoreReminderItem], at date: Date, home: Bool, destinationArrival: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if home {
            content.title = "Welcome home"
            content.body = "Check your remaining chores for today."
        } else if destinationArrival, let item = items.first, let destination = item.location {
            content.title = "You're here"
            content.body = "You're at \(destination.name). \(item.title) is due at \(item.dueAt.formatted(date: .omitted, time: .shortened))."
        } else if items.count == 1, let item = items.first {
            content.title = item.dueAt > date ? "Chore due soon" : "Chore reminder"
            if let destination = item.location, destination.leaveReminderMinutes > 0,
               date < item.dueAt, date <= item.dueAt.addingTimeInterval(-Double(destination.leaveReminderMinutes) * 60 + 1) {
                content.title = "Time to leave"
                content.body = "Leave for \(destination.name) soon · Due \(item.dueAt.formatted(date: .omitted, time: .shortened))"
            } else {
                content.body = "\(item.title) · Due \(item.dueAt.formatted(date: .omitted, time: .shortened))"
            }
        } else {
            content.title = "\(items.count) chores need your attention"
            content.body = items.prefix(3).map(\.title).joined(separator: ", ")
        }
        let goals = (snapshot?.goals ?? []).filter(\.isValid)
        if !goals.isEmpty {
            let index = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
            let goal = goals[index % goals.count]
            content.body += " Saving for \(goal.title) (\(Money.dollars(goal.targetCents)))? Every good habit counts."
        }
        content.sound = .default
        content.threadIdentifier = "chaching.chores"
        content.categoryIdentifier = homeEnabled && hasArrivalPermission && !home ? Self.homeCategory : Self.category
        content.userInfo = ["items": items.map(\.id), "owner": snapshot?.owner ?? "", "arrival": home, "destinationArrival": destinationArrival]
        return content
    }

    private func registerActions() {
        let snooze = UNNotificationAction(identifier: "SNOOZE_15", title: "Snooze 15 min")
        let hour = UNNotificationAction(identifier: "SNOOZE_60", title: "Snooze 1 hour")
        let open = UNNotificationAction(identifier: "OPEN_CHORES", title: "Open chores", options: .foreground)
        let home = UNNotificationAction(identifier: "AT_HOME", title: "When I get home")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [snooze, hour, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.homeCategory, actions: [snooze, hour, home, open], intentIdentifiers: [])
        ])
    }

    private func respond(action: String, keys: [String], owner: String, arrival: Bool) async {
        guard let snapshot, snapshot.owner == owner else { return }
        revision += 1
        let now = Date()
        let items = snapshot.items.filter { keys.contains($0.id) && $0.expiresAt > now }
        if action == "SNOOZE_15" || action == "SNOOZE_60" {
            let until = now.addingTimeInterval(action == "SNOOZE_15" ? 15 * 60 : 60 * 60)
            for item in items {
                delays[item.id] = ChoreReminderDelay(until: min(until, item.expiresAt.addingTimeInterval(-1)))
            }
        } else if action == "AT_HOME", homeEnabled, hasArrivalPermission {
            for item in items { delays[item.id] = ChoreReminderDelay(until: item.expiresAt, atHome: true) }
        } else if action == "OPEN_CHORES" || action == UNNotificationDefaultActionIdentifier {
            if arrival {
                for key in keys { delays.removeValue(forKey: key) }
            }
            onOpen?(items.map(\.choreId))
        }
        save(delays, "delays")
        do { try await schedule() } catch { message = error.localizedDescription }
    }

    private func openNudge(occurrenceId: String, owner: String) {
        guard snapshot?.owner == owner, let id = UUID(uuidString: occurrenceId) else { return }
        onNudge?(id)
    }

    private func openCatchUp(owner: String) {
        guard snapshot?.owner == owner else { return }
        onCatchUp?()
    }

    var hasLocationPermission: Bool {
        locationAuthorization == .authorizedWhenInUse || locationAuthorization == .authorizedAlways
    }

    var hasArrivalPermission: Bool {
        locationAuthorization == .authorizedAlways && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    func enableBackgroundArrivalReminders() {
        location.requestAlwaysAuthorization()
    }

    func setHomeEnabled(_ enabled: Bool) {
        revision += 1
        homeEnabled = enabled && home != nil
        persistHome()
        Task {
            do { try await schedule() } catch { message = error.localizedDescription }
        }
    }

    func useCurrentLocationAsHome() {
        message = nil
        wantsCurrentLocation = true
        isLocating = true
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: location.requestLocation()
        default:
            wantsCurrentLocation = false
            isLocating = false
            message = "Allow location access in Settings to save your home."
        }
    }

    func removeHome() {
        home = nil
        setHomeEnabled(false)
    }

    private func persistHome() {
        save(home, "home")
        defaults.set(homeEnabled, forKey: Self.prefix + "homeEnabled")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.prefix + key) }
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: Self.prefix + key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct ReminderChoreListView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var chores: [TaskOccurrence] {
        if store.showingCatchUp { return store.catchUpOccurrences }
        if let id = store.reminderOccurrenceId {
            return store.occurrences.filter { $0.id == id }
        }
        return store.occurrences.filter { occurrence in
            (occurrence.status.isOpen || occurrence.status == .missed)
                && (store.reminderChoreIds?.contains(occurrence.choreDefinitionId) == true)
        }.sorted { ($0.dueAt, $0.id.uuidString) < ($1.dueAt, $1.id.uuidString) }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.showingCatchUp {
                    ForEach(ChoreOccurrenceGroup.grouped(chores)) { group in
                        CatchUpChoreGroup(group: group)
                    }
                    if !store.awaitingReviewOccurrences.isEmpty {
                        Section("Awaiting review") {
                            ForEach(ChoreOccurrenceGroup.grouped(store.awaitingReviewOccurrences)) { group in
                                DisclosureGroup {
                                    ForEach(group.occurrences) { task in
                                        Text(task.dueAt.formatted(date: .abbreviated, time: .shortened))
                                            .foregroundStyle(.secondary)
                                    }
                                } label: {
                                    Text("\(store.chore(id: group.occurrences[0].choreDefinitionId)?.title ?? "Chore") · \(group.occurrences.count) pending")
                                }
                            }
                        }
                    }
                } else {
                ForEach(chores) { occurrence in
                    NavigationLink {
                        TaskDetailView(occurrenceId: occurrence.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.chore(for: occurrence).title).font(.headline)
                            Text(occurrence.dueAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                }
                }
            }
            .overlay {
                if chores.isEmpty && (!store.showingCatchUp || store.awaitingReviewOccurrences.isEmpty) {
                    if store.familySyncState.isWorking { ProgressView() }
                    else { ContentUnavailableView("Nothing waiting here", systemImage: "checkmark.circle") }
                }
            }
            .navigationTitle(store.showingCatchUp ? "Catch Up" : "Your Chores")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadRemoteFamilyStateIfSignedIn(force: true) }
        }
    }
}

struct CatchUpChoreGroup: View {
    @EnvironmentObject private var store: AppStore
    let group: ChoreOccurrenceGroup
    @State private var selected: Set<UUID> = []
    @State private var showingClaim = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Button(selected.count == min(100, group.occurrences.count) ? "Deselect all" : (group.occurrences.count > 100 ? "Select first 100" : "Select all")) {
                selected = selected.count == min(100, group.occurrences.count) ? [] : Set(group.occurrences.prefix(100).map(\.id))
            }
            ForEach(group.occurrences) { task in
                HStack {
                    Button { if !selected.insert(task.id).inserted { selected.remove(task.id) } } label: {
                        Image(systemName: selected.contains(task.id) ? "checkmark.square.fill" : "square")
                            .font(.title2).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(task.dueAt.formatted(date: .abbreviated, time: .shortened))")
                    .accessibilityValue(selected.contains(task.id) ? "Selected" : "Not selected")
                    NavigationLink { TaskDetailView(occurrenceId: task.id) } label: {
                        Text(task.dueAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }
            if !selected.isEmpty {
                Button { showingClaim = true } label: {
                    Label("Report \(selected.count) as done", systemImage: "paperplane")
                }
                .disabled(selected.count > 100 || store.isMutationInFlight)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.chore(id: group.occurrences[0].choreDefinitionId)?.title ?? "Chore").font(.headline)
                Text("\(group.occurrences[0].dueAt.formatted(date: .omitted, time: .shortened)) · Missed \(group.occurrences.count) \(group.occurrences.count == 1 ? "time" : "times")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingClaim) {
            NoPhotoClaimSheet(tasks: group.occurrences.filter { selected.contains($0.id) })
        }
        .onChange(of: group.occurrences.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CHACHING_GROUPED_EXPANDED"] == "1" {
                expanded = true
                selected = Set(group.occurrences.prefix(2).map(\.id))
                showingClaim = ProcessInfo.processInfo.environment["CHACHING_GROUPED_CLAIM"] == "1"
            }
            #endif
        }
    }
}

struct NoPhotoClaimSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let tasks: [TaskOccurrence]
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let first = tasks.first, let chore = store.chore(id: first.choreDefinitionId) {
                        Text(chore.title).font(.headline)
                    }
                    Text("I did \(tasks.count == 1 ? "this chore" : "these chores"), but don't have a photo.")
                        .font(.headline)
                    ForEach(tasks) { task in
                        Text(task.dueAt.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: { Text("\(tasks.count) \(tasks.count == 1 ? "chore" : "chores") selected") }
                Section {
                    TextField("Optional note to your parent", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text(note.count > 1000 ? "Please keep your note under 1000 characters." : "Your parent will review your claim before any deduction is restored.")
                }
                Button {
                    Task { if await store.reportChoresDone(ids: tasks.map(\.id), note: note) { dismiss() } }
                } label: { Label("Submit selected as done", systemImage: "paperplane.fill") }
                    .disabled(tasks.isEmpty || tasks.count > 100 || note.count > 1000 || store.isMutationInFlight)
                if store.isMutationInFlight { ProgressView("Submitting...") }
            }
            .navigationTitle("Report Done")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isMutationInFlight) } }
            .interactiveDismissDisabled(store.isMutationInFlight)
            .alert(item: $store.mutationFailure) { failure in
                Alert(title: Text(failure.title), message: Text(failure.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

extension ChoreReminderCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let keys = info["items"] as? [String] ?? []
        let owner = info["owner"] as? String ?? ""
        let arrival = info["arrival"] as? Bool ?? false
        let action = response.actionIdentifier
        if info["kind"] as? String == "catch_up", action == UNNotificationDefaultActionIdentifier {
            await openCatchUp(owner: owner)
            return
        }
        if info["kind"] as? String == "task_nudge", action == UNNotificationDefaultActionIdentifier {
            await openNudge(occurrenceId: info["task_occurrence_id"] as? String ?? "", owner: owner)
            return
        }
        await respond(action: action, keys: keys, owner: owner, arrival: arrival)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        return await presentationOptions(identifier: notification.request.identifier,
            owner: info["owner"] as? String, kind: info["kind"] as? String, keys: info["items"] as? [String])
    }

    private func presentationOptions(identifier: String, owner: String?, kind: String?, keys: [String]?) -> UNNotificationPresentationOptions {
        guard identifier.hasPrefix("chaching.") else { return [.banner, .list, .sound] }
        guard let snapshot, owner == snapshot.owner else { return [] }
        if kind == "catch_up", snapshot.catchUpIds?.isEmpty != false { return [] }
        if let keys {
            let active = Set(snapshot.items.filter { $0.expiresAt > Date() }.map(\.id))
            guard keys.contains(where: active.contains) else { return [] }
        }
        return [.banner, .list, .sound]
    }
}

extension ChoreReminderCenter: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            locationAuthorization = location.authorizationStatus
            revision += 1
            if wantsCurrentLocation {
                if hasLocationPermission { location.requestLocation() }
                else if location.authorizationStatus != .notDetermined {
                    wantsCurrentLocation = false
                    isLocating = false
                    message = "Location access is off. Timed reminders are still available."
                }
            }
            do { try await schedule() } catch { message = "Couldn't update reminders after the permission change." }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor in await arrived(in: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in message = "Arrival reminders are unavailable. Timed reminders are still scheduled." }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let latitude = fix.coordinate.latitude
        let longitude = fix.coordinate.longitude
        let accuracy = fix.horizontalAccuracy
        let age = abs(fix.timestamp.timeIntervalSinceNow)
        Task { @MainActor in
            guard wantsCurrentLocation else { return }
            wantsCurrentLocation = false
            isLocating = false
            guard accuracy >= 0, accuracy <= 200, age < 120 else {
                message = "Couldn't get an accurate home location. Try again near a window."
                return
            }
            home = ReminderHome(latitude: latitude, longitude: longitude)
            setHomeEnabled(true)
            message = "Home saved on this iPhone."
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            wantsCurrentLocation = false
            isLocating = false
            message = description
        }
    }
}

@MainActor
final class ChoreDestinationLocationCapture: NSObject, ObservableObject {
    @Published private(set) var isLocating = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var message: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        message = nil
        isLocating = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            isLocating = false
            message = "Allow location access in Settings to use the current place."
        }
    }
}

extension ChoreDestinationLocationCapture: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.isLocating else { return }
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.requestLocation()
            } else if status != .notDetermined {
                self.isLocating = false
                self.message = "Location access is off. You can still use timed reminders."
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        let coordinate = fix.coordinate
        let accuracy = fix.horizontalAccuracy
        let age = abs(fix.timestamp.timeIntervalSinceNow)
        Task { @MainActor in
            self.isLocating = false
            guard accuracy >= 0, accuracy <= 200, age < 120 else {
                self.message = "Couldn't get an accurate location. Try again."
                return
            }
            self.coordinate = coordinate
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.isLocating = false
            self.message = error.localizedDescription
        }
    }
}

struct ReminderSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reminders = ChoreReminderCenter.shared
    @State private var confirmHome = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Button { Task { await store.enableLocalNotifications() } } label: {
                        Label("Enable Reminders", systemImage: "bell.badge")
                    }
                    Text(store.notificationState.message).font(.subheadline).foregroundStyle(.secondary)
                    if let next = reminders.nextReminderAt {
                        LabeledContent("Next reminder", value: next.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("iPhone Notification Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section {
                    if !reminders.hasArrivalPermission {
                        Button("Enable Background Arrival Reminders") { reminders.enableBackgroundArrivalReminders() }
                        Button("iPhone Location Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        Text("Choose Always location access for home and chore-destination reminders while the app is closed. Timed reminders work without it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("When I Get Home", isOn: Binding(get: { reminders.homeEnabled }, set: { reminders.setHomeEnabled($0) }))
                        .disabled(reminders.home == nil)
                    Button { confirmHome = true } label: {
                        Label(reminders.isLocating ? "Finding Location" : "Use Current Location as Home", systemImage: "house")
                    }
                    .disabled(reminders.isLocating)
                    if reminders.home != nil {
                        Button("Remove Home Location", role: .destructive) { reminders.removeHome() }
                    }
                    if let message = reminders.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                } header: { Text("Location Reminders") } footer: {
                    Text("Your home location stays on this iPhone. Arrival reminders check whether a chore is still due using the latest data on this device. They are optional and may be delayed by iOS. No continuous location tracking is used. Snoozing doesn't change a chore's deadline.")
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Are you at home now?", isPresented: $confirmHome, titleVisibility: .visible) {
                Button("Save This Location as Home") { reminders.useCurrentLocationAsHome() }
            }
            .task { await store.refreshNotificationScheduleIfAuthorized() }
        }
    }
}
