import CoreLocation
import SwiftUI
import UserNotifications

private struct ReminderSnapshot: Codable {
    var owner: String
    var items: [ChoreReminderItem]
    var goals: [SavingsGoal]? = nil
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
    private var armedHomeKeys: [String] = []
    private var wantsCurrentLocation = false
    private var onOpen: (([UUID]) -> Void)?
    private var onNudge: ((UUID) -> Void)?
    @Published private(set) var home: ReminderHome?
    @Published private(set) var homeEnabled = false
    @Published private(set) var isLocating = false
    @Published private(set) var message: String?
    @Published private(set) var scheduledCount = 0
    @Published private(set) var nextReminderAt: Date?

    private override init() {
        super.init()
        snapshot = read("snapshot")
        delays = read("delays") ?? [:]
        armedHomeKeys = read("armedHomeKeys") ?? []
        home = read("home")
        homeEnabled = defaults.bool(forKey: Self.prefix + "homeEnabled")
        location.delegate = self
    }

    func configure(onOpen: @escaping ([UUID]) -> Void, onNudge: @escaping (UUID) -> Void) {
        self.onOpen = onOpen
        self.onNudge = onNudge
        center.delegate = self
        registerActions()
    }

    func update(owner: String, items: [ChoreReminderItem], goals: [SavingsGoal] = []) {
        if snapshot?.owner != owner || snapshot?.items != items || snapshot?.goals != goals { revision += 1 }
        if let snapshot, snapshot.owner != owner {
            setArmedHomeKeys([])
            delays = [:]
            home = nil
            homeEnabled = false
            persistHome()
        }
        snapshot = ReminderSnapshot(owner: owner, items: items, goals: goals)
        let ids = Set(items.map(\.id))
        delays = delays.filter { ids.contains($0.key) }
        save(snapshot, "snapshot")
        save(delays, "delays")
    }

    func clear() async {
        revision += 1
        setArmedHomeKeys([])
        snapshot = nil
        delays = [:]
        home = nil
        homeEnabled = false
        defaults.removeObject(forKey: Self.prefix + "snapshot")
        defaults.removeObject(forKey: Self.prefix + "delays")
        persistHome()
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
        let canUseHome = homeEnabled && home != nil && hasLocationPermission
        if !canUseHome {
            // Losing permission must restore timed reminders rather than silently suppressing them.
            delays = delays.filter { !$0.value.atHome }
        }
        save(delays, "delays")
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        guard revision == self.revision else { return }
        // A one-shot arrival alert may have been dismissed, so it is no longer delivered or pending.
        if !armedHomeKeys.isEmpty && !pending.contains(where: { $0.identifier == Self.prefix + "home" }) {
            for key in armedHomeKeys where delays[key]?.atHome == true { delays.removeValue(forKey: key) }
            setArmedHomeKeys([])
        }
        save(delays, "delays")
        if snapshot == nil {
            center.removePendingNotificationRequests(withIdentifiers: pending.filter {
                $0.identifier.hasPrefix("chaching.")
            }.map(\.identifier))
            scheduledCount = 0
            nextReminderAt = nil
            return
        }
        let managed = pending.filter {
            $0.identifier.hasPrefix(Self.prefix) || $0.identifier.hasPrefix("chaching.chore.")
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: managed.map(\.identifier))
            scheduledCount = 0
            nextReminderAt = nil
            return
        }
        let reserved = pending.count - managed.count
        let batches = ChoreReminderPlanner.batches(items: items, delays: delays, now: now,
                                                   limit: max(0, min(56, 62 - reserved)))
        var requests: [UNNotificationRequest] = batches.map { batch in
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: batch.fireAt)
            return UNNotificationRequest(identifier: Self.prefix + "time.\(Int(batch.fireAt.timeIntervalSince1970))",
                                         content: content(for: batch.items, at: batch.fireAt, home: false),
                                         trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        }
        let homeItems = items.filter { delays[$0.id]?.atHome == true }
        if canUseHome, let home, !homeItems.isEmpty {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude),
                                          radius: 200, identifier: "chaching.home")
            region.notifyOnEntry = true
            region.notifyOnExit = false
            requests.append(UNNotificationRequest(identifier: Self.prefix + "home",
                                                   content: content(for: homeItems, at: now, home: true),
                                                   trigger: UNLocationNotificationTrigger(region: region, repeats: false)))
        }
        // Region monitoring is intentionally limited to the nearest 20 destination chores.
        // The timed reminder remains the fallback when location access is unavailable.
        if hasLocationPermission {
            let destinationItems = items
                .filter { $0.location?.isValid == true && delays[$0.id]?.atHome != true }
                .sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
                .prefix(20)
            for item in destinationItems {
                guard let destination = item.location else { continue }
                let region = CLCircularRegion(
                    center: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude),
                    radius: destination.radiusMeters,
                    identifier: "chaching.destination.\(item.id)"
                )
                region.notifyOnEntry = true
                region.notifyOnExit = false
                requests.append(UNNotificationRequest(
                    identifier: Self.prefix + "destination.\(item.id)",
                    content: content(for: [item], at: now, home: false, destinationArrival: true),
                    trigger: UNLocationNotificationTrigger(region: region, repeats: false)
                ))
            }
        }
        let desired = Set(requests.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: managed.filter { !desired.contains($0.identifier) }.map(\.identifier))
        for request in requests {
            guard revision == self.revision else { return }
            // Do not re-arm a location trigger on every foreground poll.
            if let existing = managed.first(where: { $0.identifier == request.identifier }),
               existing.content.isEqual(request.content), existing.trigger?.isEqual(request.trigger) == true {
                continue
            }
            try await center.add(request)
        }
        guard revision == self.revision else { return }
        setArmedHomeKeys(desired.contains(Self.prefix + "home") ? homeItems.map(\.id) : [])
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
            guard notification.request.identifier.hasPrefix(Self.prefix) else { return false }
            if notification.request.content.userInfo["owner"] as? String != snapshot?.owner { return true }
            let keys = notification.request.content.userInfo["items"] as? [String] ?? []
            return !keys.contains(where: ids.contains)
        }.map { $0.request.identifier })
        scheduledCount = requests.count
        nextReminderAt = batches.first?.fireAt
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
            if let destination = item.location, item.location?.leaveReminderMinutes ?? 0 > 0 {
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
        content.categoryIdentifier = homeEnabled && hasLocationPermission && !home ? Self.homeCategory : Self.category
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
        } else if action == "AT_HOME", homeEnabled, hasLocationPermission {
            setArmedHomeKeys([])
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

    var hasLocationPermission: Bool {
        location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways
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

    private func setArmedHomeKeys(_ keys: [String]) {
        armedHomeKeys = keys
        save(keys, "armedHomeKeys")
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
        if let id = store.reminderOccurrenceId {
            return store.occurrences.filter { $0.id == id }
        }
        return store.todayOccurrences.filter { occurrence in
            (occurrence.status.isOpen || occurrence.status == .missed)
                && (store.reminderChoreIds?.contains(occurrence.choreDefinitionId) == true)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chores) { occurrence in
                    NavigationLink {
                        TaskDetailView(occurrenceId: occurrence.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.chore(for: occurrence).title).font(.headline)
                            Text(occurrence.dueAt, style: .time).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if chores.isEmpty {
                    if store.familySyncState.isWorking { ProgressView() }
                    else { ContentUnavailableView("Nothing waiting here", systemImage: "checkmark.circle") }
                }
            }
            .navigationTitle("Your Chores")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadRemoteFamilyStateIfSignedIn(force: true) }
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
        if info["kind"] as? String == "task_nudge", action == UNNotificationDefaultActionIdentifier {
            await openNudge(occurrenceId: info["task_occurrence_id"] as? String ?? "", owner: owner)
            return
        }
        await respond(action: action, keys: keys, owner: owner, arrival: arrival)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension ChoreReminderCenter: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if wantsCurrentLocation {
                if hasLocationPermission { location.requestLocation() }
                else if location.authorizationStatus != .notDetermined {
                    wantsCurrentLocation = false
                    isLocating = false
                    message = "Location access is off. Timed reminders are still available."
                }
            }
        }
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
                    Toggle("Arrival Reminders", isOn: Binding(get: { reminders.homeEnabled }, set: { reminders.setHomeEnabled($0) }))
                        .disabled(reminders.home == nil)
                    Button { confirmHome = true } label: {
                        Label(reminders.isLocating ? "Finding Location" : "Use Current Location as Home", systemImage: "house")
                    }
                    .disabled(reminders.isLocating)
                    if reminders.home != nil {
                        Button("Remove Home Location", role: .destructive) { reminders.removeHome() }
                    }
                    if let message = reminders.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                } header: { Text("When I Get Home") } footer: {
                    Text("Your home location stays on this iPhone. Arrival reminders are optional and may be delayed by iOS. Snoozing or waiting until home doesn't change a chore's deadline.")
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
