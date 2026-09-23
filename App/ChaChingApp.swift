import BackgroundTasks
import SwiftUI

@main
struct ChaChingApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: AppStore
    @UIApplicationDelegateAdaptor(ChaChingAppDelegate.self) private var appDelegate

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        ChoreReminderCenter.shared.configure(onOpen: { [weak store] choreIds in
            store?.showingCatchUp = false
            store?.reminderOccurrenceId = nil
            store?.reminderChoreIds = choreIds
        }, onNudge: { [weak store] occurrenceId in
            store?.showingCatchUp = false
            store?.reminderOccurrenceId = occurrenceId
            store?.reminderChoreIds = []
        }, onCatchUp: { [weak store] in
            store?.showingCatchUp = true
            store?.reminderOccurrenceId = nil
            store?.reminderChoreIds = []
        })
        ChaChingBackgroundRefresh.shared.configure(store: store)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await store.loadRemoteFamilyStateIfSignedIn()
                        }
                    case .background:
                        ChaChingBackgroundRefresh.shared.schedule()
                    default:
                        break
                    }
                }
        }
    }
}

@MainActor
private final class ChaChingBackgroundRefresh {
    static let shared = ChaChingBackgroundRefresh()

    private static let identifier = "com.artofsullivan.chaching.refresh"
    private weak var store: AppStore?
    private var didRegister = false

    private init() {}

    func configure(store: AppStore) {
        self.store = store
        register()
    }

    func schedule(after interval: TimeInterval = 15 * 60) {
        guard store?.canAttemptRemoteRefresh == true else {
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugPrint("Unable to schedule background refresh: \(error)")
        }
    }

    private func register() {
        guard !didRegister else {
            return
        }

        // This callback inherits MainActor isolation; nil delivers it on a background queue.
        didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                self.handle(refreshTask)
            }
        }

        if !didRegister {
            debugPrint("Unable to register background refresh task.")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule(after: 30 * 60)

        let refreshTask = Task { @MainActor in
            guard let store, store.canAttemptRemoteRefresh else {
                task.setTaskCompleted(success: false)
                return
            }

            await store.loadRemoteFamilyStateIfSignedIn(force: true)
            await store.refreshNotificationScheduleIfAuthorized()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = { @Sendable in
            refreshTask.cancel()
        }
    }
}
