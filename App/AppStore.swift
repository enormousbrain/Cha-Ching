import Foundation
import SwiftUI
import UserNotifications
#if canImport(WidgetKit)
import WidgetKit
#endif

private struct OccurrenceTimeUpdate: Sendable {
    let id: UUID
    let scheduledAt: Date
    let dueAt: Date
    let expiresAt: Date
}

@MainActor
final class AppStore: ObservableObject {
    @Published var session: AppSession
    @Published var members: [FamilyMember]
    @Published var childProfiles: [ChildProfile]
    @Published var childInvites: [ChildInvite]
    @Published var parentInvites: [ParentInvite]
    @Published var pendingInvite: PendingInvite?
    @Published var inviteAcceptanceState: InviteAcceptanceState
    @Published var inviteCreationState: InviteCreationState
    @Published var chores: [ChoreDefinition]
    @Published var occurrences: [TaskOccurrence]
    @Published var submissions: [ChoreSubmission]
    @Published var ledger: [LedgerEntry]
    @Published var allowancePeriods: [AllowancePeriod]
    @Published private(set) var allowanceSettlements: [UUID: AllowanceSettlement] = [:]
    @Published var allowanceSettings: AllowanceSettings
    @Published var evidencePolicy: FamilyEvidencePolicy
    @Published var notificationState: NotificationState
    @Published var reminderChoreIds: [UUID]?
    @Published var reminderOccurrenceId: UUID?
    @Published private(set) var savingsGoals: [SavingsGoal] = []
    @Published var familySyncState: FamilySyncState
    @Published var mutationFailure: MutationFailure?
    @Published private(set) var activeMutationTitle: String?

    private let inviteAcceptanceService: InviteAcceptanceServicing
    private let remoteStore: SupabaseRemoteStore
    private let settingsStore: UserDefaults
    private let allowanceSettingsKey = "chaching.allowanceSettings"
    private let deliveredNudgeIdsKey = "chaching.deliveredNudgeIds"
    private var lastAutomaticRemoteRefreshAt: Date?
    private var remoteRefreshTask: Task<Void, Never>?
    private var remoteRefreshGeneration = UUID()
    private var reminderStateReady = false
    private var pushObserver: NSObjectProtocol?

    @Published private(set) var familyId: UUID
    @Published private(set) var parentId: UUID
    @Published private(set) var childId: UUID
    @Published private(set) var weekId: UUID
    @Published private(set) var familyName: String
    @Published private(set) var childName: String
    @Published private(set) var parentName: String

    init(
        snapshot: SeedSnapshot = SeedData.snapshot(),
        inviteAcceptanceService: InviteAcceptanceServicing = SupabaseInviteAcceptanceService(),
        remoteStore: SupabaseRemoteStore = SupabaseRemoteStore(),
        settingsStore: UserDefaults = .standard
    ) {
        self.familyId = snapshot.familyId
        self.parentId = snapshot.parentId
        self.childId = snapshot.childId
        self.weekId = snapshot.weekId
        self.familyName = snapshot.familyName
        self.childName = snapshot.childName
        self.parentName = snapshot.parentName
        self.inviteAcceptanceService = inviteAcceptanceService
        self.remoteStore = remoteStore
        self.settingsStore = settingsStore
        self.session = AppSession(userId: snapshot.parentId, role: .parent, displayName: snapshot.parentName)
        self.members = snapshot.members
        self.childProfiles = snapshot.childProfiles
        self.childInvites = snapshot.childInvites
        self.parentInvites = snapshot.parentInvites
        self.pendingInvite = nil
        self.inviteAcceptanceState = .idle
        self.inviteCreationState = .idle
        self.chores = snapshot.chores
        self.occurrences = snapshot.occurrences
        self.submissions = snapshot.submissions
        self.ledger = snapshot.ledger
        self.allowancePeriods = snapshot.allowancePeriods
        self.evidencePolicy = snapshot.evidencePolicy
        if let savedSettings = Self.loadAllowanceSettings(from: settingsStore, key: allowanceSettingsKey),
           savedSettings.familyId == snapshot.familyId {
            self.allowanceSettings = savedSettings
        } else {
            self.allowanceSettings = snapshot.allowanceSettings
        }
        self.notificationState = .idle
        self.familySyncState = .localPreview
        self.allowanceSettlements = [:]
        self.mutationFailure = nil
        self.activeMutationTitle = nil
        #if DEBUG
        reminderStateReady = SupabaseClientProvider.shared.auth.currentSession == nil
        #endif
        publishWidgetSnapshot()
        pushObserver = NotificationCenter.default.addObserver(forName: .chachingAPNsTokenAvailable, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.syncAPNsDeviceToken() }
        }
    }

    var activeRole: FamilyMemberRole {
        session.role
    }

    var isParentSession: Bool {
        activeRole == .parent
    }

    var isChildSession: Bool {
        activeRole == .child
    }

    var isMutationInFlight: Bool {
        activeMutationTitle != nil
    }

    var activeChildProfile: ChildProfile? {
        childProfiles.first { $0.id == childId }
    }

    var latestInvite: ChildInvite? {
        childInvites.sorted { $0.createdAt > $1.createdAt }.first
    }

    var activeChores: [ChoreDefinition] {
        let referenceDate = Date()
        return chores.filter { $0.archivedAt == nil }
            .map { chore in
                (chore: chore, dueAt: Self.date(onSameDayAs: referenceDate, time: chore.dueTime) ?? .distantFuture)
            }
            .sorted {
                ($0.dueAt, $0.chore.id.uuidString) < ($1.dueAt, $1.chore.id.uuidString)
            }
            .map(\.chore)
    }

    var allowanceSummary: AllowanceSummary {
        AllowanceEngine.summary(for: ledger)
    }

    var allowanceTrend: [AllowanceTrendPoint] {
        guard let period = activeAllowancePeriod else { return [] }
        return AllowanceEngine.trajectory(for: ledger, from: period.startsAt, through: min(Date(), period.endsAt))
            .map { AllowanceTrendPoint(date: $0.date, cents: $0.balanceCents, title: $0.title) }
    }

    var activeAllowancePeriod: AllowancePeriod? {
        guard var period = allowancePeriods.first(where: { $0.id == weekId }) else {
            return nil
        }
        period.entries = ledger
        return period
    }

    var archivedAllowancePeriods: [AllowancePeriod] {
        allowancePeriods
            .filter(\.isArchived)
            .sorted { $0.startsAt > $1.startsAt }
    }

    var allowancePeriodTitle: String {
        allowanceSettings.cadence.periodTitle
    }

    var nextAllowanceDate: Date {
        allowanceSettings.nextScheduledAllowanceDate()
    }

    var requestableAllowancePeriods: [AllowancePeriod] {
        archivedAllowancePeriods.filter(\.canRequestPayment)
    }

    var todayOccurrences: [TaskOccurrence] {
        occurrences
            .filter { Calendar.current.isDateInToday($0.dueAt) }
            .sorted {
                ($0.dueAt, $0.id.uuidString) < ($1.dueAt, $1.id.uuidString)
            }
    }

    var remainingCount: Int {
        todayOccurrences.filter { $0.status == .upcoming || $0.status == .due }.count
    }

    var pendingReviewOccurrences: [TaskOccurrence] {
        occurrences.filter { $0.status.needsParentReview && allowanceSettlements[$0.weekId] == nil }
    }

    var nextDueOccurrence: TaskOccurrence? {
        todayOccurrences
            .filter { $0.status == .upcoming || $0.status == .due }
            .first
    }

    func chore(for occurrence: TaskOccurrence) -> ChoreDefinition {
        chores.first { $0.id == occurrence.choreDefinitionId } ?? chores[0]
    }

    func chore(id: UUID) -> ChoreDefinition? {
        chores.first { $0.id == id }
    }

    func submission(for occurrence: TaskOccurrence) -> ChoreSubmission? {
        submissions.first { $0.taskOccurrenceId == occurrence.id }
    }

    func switchSession(to role: FamilyMemberRole) {
        switch role {
        case .parent:
            session = AppSession(userId: parentId, role: .parent, displayName: parentName)
        case .child:
            session = AppSession(userId: childId, role: .child, displayName: childName)
        }
    }

    var canAttemptRemoteRefresh: Bool {
        SupabaseClientProvider.shared.auth.currentSession != nil
    }

    func loadRemoteFamilyStateIfSignedIn(force: Bool = false) async {
        guard SupabaseClientProvider.shared.auth.currentSession != nil else {
            familySyncState = .localPreview
            return
        }

        if !force,
           let lastAutomaticRemoteRefreshAt,
           Date().timeIntervalSince(lastAutomaticRemoteRefreshAt) < 20 {
            return
        }

        lastAutomaticRemoteRefreshAt = Date()

        await loadRemoteFamilyState()
    }

    func refreshRemoteFamilyState() async {
        await loadRemoteFamilyStateIfSignedIn(force: true)
    }

    func confirmAllowancePeriod(_ period: AllowancePeriod) async -> Bool {
        guard isParentSession, period.familyId == familyId, period.childId == childId,
              period.isArchived, canAttemptRemoteRefresh else { return false }
        var response: AllowanceSettlementRecord?
        let saved = await commitMutation(actionTitle: "Confirm allowance", successMessage: "Allowance amount locked across devices.", remoteSave: {
            response = try await self.remoteStore.confirmAllowancePeriod(weekId: period.id, amountCents: period.summary.currentTotalCents)
        }, localCommit: {
            if let response { self.applySettlement(response) }
        })
        if saved { await refreshRemoteFamilyState() }
        return saved
    }

    func markAllowancePaid(_ period: AllowancePeriod) async -> Bool {
        guard isParentSession, period.familyId == familyId, period.childId == childId,
              allowanceSettlements[period.id] != nil, canAttemptRemoteRefresh else { return false }
        var response: AllowanceSettlementRecord?
        return await commitMutation(actionTitle: "Record payment", successMessage: "Payment recorded across devices.", remoteSave: {
            response = try await self.remoteStore.markAllowancePaid(weekId: period.id)
        }, localCommit: {
            if let response { self.applySettlement(response) }
        })
    }

    func loadPeriodReviews(_ period: AllowancePeriod) async throws -> [TaskOccurrence] {
        guard period.familyId == familyId, period.childId == childId else { throw CancellationError() }
        let rows = try await remoteStore.fetchOccurrences(weekId: period.id)
        let photos = try await remoteStore.fetchChoreSubmissions(childId: period.childId)
        guard period.familyId == familyId, period.childId == childId else { throw CancellationError() }
        let tasks = rows.map { localOccurrence(from: $0) }
        let ids = Set(tasks.map(\.id))
        occurrences.removeAll { $0.weekId == period.id }
        occurrences.append(contentsOf: tasks)
        submissions.removeAll { ids.contains($0.taskOccurrenceId) }
        submissions.append(contentsOf: photos.filter { ids.contains($0.taskOccurrenceId) }.map { localSubmission(from: $0) })
        return tasks
    }

    func switchParentChild(to id: UUID) async {
        guard isParentSession, !isMutationInFlight,
              childProfiles.contains(where: { $0.id == id && $0.familyId == familyId }) else { return }
        guard SupabaseClientProvider.shared.auth.currentSession != nil else {
            if let profile = childProfiles.first(where: { $0.id == id }) {
                childId = profile.id
                childName = profile.displayName
                chores = chores.filter { $0.childId == id }
                occurrences = occurrences.filter { $0.childId == id }
                publishWidgetSnapshot()
            }
            return
        }
        await loadRemoteFamilyState(selectingChildId: id)
    }

    func loadRemoteFamilyState(selectingChildId: UUID? = nil) async {
        // Keep foreground, background, and child-switch refreshes in request order.
        let previous = remoteRefreshTask
        let generation = remoteRefreshGeneration
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.remoteRefreshGeneration == generation else { return }
            await self.performRemoteFamilyRefresh(selectingChildId: selectingChildId, generation: generation)
        }
        remoteRefreshTask = task
        await task.value
    }

    private func performRemoteFamilyRefresh(selectingChildId: UUID?, generation: UUID) async {
        familySyncState = .loading

        do {
            let authSession = try await remoteStore.currentSession()
            let memberships = try await remoteStore.fetchMembershipsForCurrentUser(userId: authSession.user.id)

            guard remoteRefreshGeneration == generation else { return }
            guard let membership = memberships.first else {
                familySyncState = .needsBootstrap("Signed in. Create your remote family to sync across devices.")
                return
            }

            guard remoteRefreshGeneration == generation else { return }
            try await applyRemoteFamilyState(for: membership, authUserId: authSession.user.id, selectingChildId: selectingChildId, generation: generation)
            guard remoteRefreshGeneration == generation else { return }
            familySyncState = .synced("Synced \(familyName) across devices.")
        } catch {
            guard remoteRefreshGeneration == generation else { return }
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func requestFamilySyncCode(phoneNumber: String) async {
        guard let normalizedPhoneNumber = Self.normalizedPhoneNumber(phoneNumber) else {
            familySyncState = .failed(InviteAcceptanceError.invalidPhoneNumber.localizedDescription)
            return
        }

        familySyncState = .loading

        do {
            try await inviteAcceptanceService.requestSMSCode(phoneNumber: normalizedPhoneNumber)
            familySyncState = .codeSent(phoneNumber: normalizedPhoneNumber)
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func verifyFamilySyncCode(phoneNumber: String, code: String) async {
        guard let normalizedPhoneNumber = Self.normalizedPhoneNumber(phoneNumber) else {
            familySyncState = .failed(InviteAcceptanceError.invalidPhoneNumber.localizedDescription)
            return
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            familySyncState = .failed(InviteAcceptanceError.invalidCode.localizedDescription)
            return
        }

        familySyncState = .loading

        do {
            _ = try await inviteAcceptanceService.verifySMSCode(
                phoneNumber: normalizedPhoneNumber,
                code: trimmedCode
            )
            await loadRemoteFamilyState()
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func requestFamilySyncEmailCode(email: String) async {
        guard let normalizedEmail = Self.normalizedEmail(email) else {
            familySyncState = .failed(InviteAcceptanceError.invalidEmail.localizedDescription)
            return
        }

        familySyncState = .loading

        do {
            try await inviteAcceptanceService.requestEmailCode(email: normalizedEmail)
            familySyncState = .emailCodeSent(email: normalizedEmail)
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func verifyFamilySyncEmailCode(email: String, code: String) async {
        guard let normalizedEmail = Self.normalizedEmail(email) else {
            familySyncState = .failed(InviteAcceptanceError.invalidEmail.localizedDescription)
            return
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            familySyncState = .failed(InviteAcceptanceError.invalidCode.localizedDescription)
            return
        }

        familySyncState = .loading

        do {
            _ = try await inviteAcceptanceService.verifyEmailCode(
                email: normalizedEmail,
                code: trimmedCode
            )
            await loadRemoteFamilyState()
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func signInWithApple(idToken: String, nonce: String?, fullName: String?) async {
        familySyncState = .loading

        do {
            _ = try await inviteAcceptanceService.signInWithApple(
                idToken: idToken,
                nonce: nonce,
                fullName: fullName
            )
            await loadRemoteFamilyState()
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func failFamilySync(message: String) {
        familySyncState = .failed(message)
    }

    func bootstrapRemoteFamily(parentName: String, childName: String) async {
        familySyncState = .loading

        do {
            _ = try await remoteStore.currentSession()
            _ = try await remoteStore.bootstrapPreviewFamily(
                parentName: parentName,
                childName: childName,
                familyName: "\(childName)'s Family"
            )
            await loadRemoteFamilyState()
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func signOutRemoteFamily() async {
        remoteRefreshGeneration = UUID()
        familySyncState = .loading

        do {
            try await remoteStore.signOut()
            reminderStateReady = false
            await ChoreReminderCenter.shared.clear()
            applyLocalPreviewState()
            familySyncState = .localPreview
        } catch {
            familySyncState = .failed(error.localizedDescription)
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard let token = inviteToken(from: url) else {
            return
        }

        pendingInvite = PendingInvite(token: token, url: url)
        inviteAcceptanceState = .idle
    }

    func clearPendingInvite() {
        pendingInvite = nil
        inviteAcceptanceState = .idle
    }

    func requestInviteSMSCode(phoneNumber: String) async {
        guard let normalizedPhoneNumber = Self.normalizedPhoneNumber(phoneNumber) else {
            inviteAcceptanceState = .failed(InviteAcceptanceError.invalidPhoneNumber.localizedDescription)
            return
        }

        inviteAcceptanceState = .requestingCode

        do {
            try await inviteAcceptanceService.requestSMSCode(phoneNumber: normalizedPhoneNumber)
            inviteAcceptanceState = .codeSent(phoneNumber: normalizedPhoneNumber)
        } catch {
            inviteAcceptanceState = .failed(error.localizedDescription)
        }
    }

    func acceptPendingInvite(phoneNumber: String, code: String) async {
        guard let pendingInvite else {
            inviteAcceptanceState = .failed(InviteAcceptanceError.missingInvite.localizedDescription)
            return
        }

        guard let normalizedPhoneNumber = Self.normalizedPhoneNumber(phoneNumber) else {
            inviteAcceptanceState = .failed(InviteAcceptanceError.invalidPhoneNumber.localizedDescription)
            return
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            inviteAcceptanceState = .failed(InviteAcceptanceError.invalidCode.localizedDescription)
            return
        }

        inviteAcceptanceState = .accepting

        do {
            _ = try await inviteAcceptanceService.verifySMSCode(
                phoneNumber: normalizedPhoneNumber,
                code: trimmedCode
            )

            switch pendingInvite.kind {
            case .parent:
                let acceptedInvite = try await inviteAcceptanceService.acceptParentInvite(token: pendingInvite.token)
                applyAcceptedParentInvite(acceptedInvite, token: pendingInvite.token)
                inviteAcceptanceState = .accepted(displayName: acceptedInvite.parentName, role: .parent)
            case .child:
                let acceptedInvite = try await inviteAcceptanceService.acceptChildInvite(token: pendingInvite.token)
                applyAcceptedChildInvite(acceptedInvite, token: pendingInvite.token)
                inviteAcceptanceState = .accepted(displayName: acceptedInvite.childName, role: .child)
            }
        } catch {
            inviteAcceptanceState = .failed(error.localizedDescription)
        }
    }

    func createChildInvite(
        id inviteId: UUID = UUID(),
        childName: String,
        phoneNumber: String?
    ) async -> Bool {
        let trimmedName = childName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            inviteCreationState = .failed("Add the child's name before creating an invite.")
            return failMutation(actionTitle: "Create child invite", message: "Add the child's name before creating an invite.")
        }

        let normalizedPhone = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePhone = normalizedPhone?.isEmpty == false ? normalizedPhone : nil
        let childProfileId = childProfiles.first {
            $0.displayName.caseInsensitiveCompare(trimmedName) == .orderedSame
        }?.id ?? inviteId
        let token = makeInviteToken(for: trimmedName, prefix: "child", nonce: inviteId)
        let now = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        let invite = ChildInvite(
            id: inviteId,
            familyId: familyId,
            childProfileId: childProfileId,
            childName: trimmedName,
            phoneNumber: usablePhone,
            createdByParentId: parentId,
            token: token,
            inviteURL: AppBrand.inviteURL(token: token),
            createdAt: now,
            expiresAt: expiresAt
        )

        inviteCreationState = .creating
        let mode = mutationPersistenceMode
        var profileRecord: ChildProfileRecord?
        var inviteRecord: ChildInviteRecord?
        let saved = await commitMutation(
            actionTitle: "Create child invite",
            successMessage: "Child invite saved across devices.",
            remoteSave: {
                profileRecord = try await remoteStore.upsertChildProfile(
                    id: childProfileId,
                    familyId: familyId,
                    displayName: trimmedName,
                    phoneNumber: usablePhone,
                    createdByParentId: nil
                )
                inviteRecord = try await remoteStore.createChildInvite(
                    id: invite.id,
                    familyId: familyId,
                    childProfileId: childProfileId,
                    childName: trimmedName,
                    phoneNumber: usablePhone,
                    createdByParentId: nil,
                    token: token,
                    expiresAt: expiresAt
                )
            },
            localCommit: {
                if let profileRecord, let inviteRecord {
                    applyChildProfileRecord(profileRecord)
                    applyChildInviteRecord(inviteRecord, token: token)
                } else {
                    upsertLocalChildProfile(
                        id: childProfileId,
                        childName: trimmedName,
                        phoneNumber: usablePhone,
                        updatedAt: now
                    )
                    childInvites.insert(invite, at: 0)
                }
            }
        )
        if saved {
            inviteCreationState = mode == .remoteRequired
                ? .synced("Child invite synced with Supabase.")
                : .localOnly("Preview invite is ready to share from this phone.")
        } else {
            inviteCreationState = .failed(mutationFailure?.message ?? "The child invite was not created. Try again.")
        }
        return saved
    }

    func createParentInvite(
        id inviteId: UUID = UUID(),
        parentName: String,
        phoneNumber: String?
    ) async -> Bool {
        let trimmedName = parentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            inviteCreationState = .failed("Add the parent's name before creating an invite.")
            return failMutation(actionTitle: "Create parent invite", message: "Add the parent's name before creating an invite.")
        }

        let normalizedPhone = phoneNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usablePhone = normalizedPhone?.isEmpty == false ? normalizedPhone : nil
        let token = makeInviteToken(for: trimmedName, prefix: "parent", nonce: inviteId)
        let now = Date()
        let expiresAt = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 60 * 60)
        let invite = ParentInvite(
            id: inviteId,
            familyId: familyId,
            parentName: trimmedName,
            phoneNumber: usablePhone,
            createdByParentId: session.userId,
            token: token,
            inviteURL: AppBrand.inviteURL(token: token),
            createdAt: now,
            expiresAt: expiresAt
        )

        inviteCreationState = .creating
        let mode = mutationPersistenceMode
        var inviteRecord: ParentInviteRecord?
        let saved = await commitMutation(
            actionTitle: "Create parent invite",
            successMessage: "Parent invite saved across devices.",
            remoteSave: {
                inviteRecord = try await remoteStore.createParentInvite(
                    id: invite.id,
                    familyId: familyId,
                    parentName: trimmedName,
                    phoneNumber: usablePhone,
                    createdByParentId: nil,
                    token: token,
                    expiresAt: expiresAt
                )
            },
            localCommit: {
                if let inviteRecord {
                    applyParentInviteRecord(inviteRecord, token: token)
                } else {
                    parentInvites.insert(invite, at: 0)
                }
            }
        )
        if saved {
            inviteCreationState = mode == .remoteRequired
                ? .synced("Parent invite synced with Supabase.")
                : .localOnly("Preview invite is ready to share from this phone.")
        } else {
            inviteCreationState = .failed(mutationFailure?.message ?? "The parent invite was not created. Try again.")
        }
        return saved
    }

    func revokeInvite(_ invite: ChildInvite) async -> Bool {
        await commitMutation(
            actionTitle: "Revoke invite",
            successMessage: "Child invite revoked across devices.",
            remoteSave: {
                _ = try await remoteStore.revokeChildInvite(id: invite.id)
            },
            localCommit: {
                updateInvite(invite.id) { invite in
                    invite.status = .revoked
                }
            }
        )
    }

    func revokeParentInvite(_ invite: ParentInvite) async -> Bool {
        await commitMutation(
            actionTitle: "Revoke invite",
            successMessage: "Parent invite revoked across devices.",
            remoteSave: {
                _ = try await remoteStore.revokeParentInvite(id: invite.id)
            },
            localCommit: {
                updateParentInvite(invite.id) { invite in
                    invite.status = .revoked
                }
            }
        )
    }

    func markInviteAccepted(_ invite: ChildInvite) {
        let now = Date()
        updateInvite(invite.id) { invite in
            invite.status = .accepted
            invite.acceptedAt = now
            invite.acceptedChildUserId = childId
        }

        if !members.contains(where: { $0.userId == childId && $0.role == .child }) {
            members.append(
                FamilyMember(
                    familyId: familyId,
                    userId: childId,
                    role: .child,
                    displayName: invite.childName
                )
            )
        }

        updateChildProfile(invite.childProfileId) { profile in
            profile.linkedUserId = childId
            profile.updatedAt = now
        }
    }

    func markParentInviteAccepted(_ invite: ParentInvite) {
        let now = Date()
        let acceptedParentId = UUID()
        updateParentInvite(invite.id) { invite in
            invite.status = .accepted
            invite.acceptedAt = now
            invite.acceptedParentUserId = acceptedParentId
        }

        if !members.contains(where: { $0.userId == acceptedParentId && $0.role == .parent }) {
            members.append(
                FamilyMember(
                    familyId: familyId,
                    userId: acceptedParentId,
                    role: .parent,
                    displayName: invite.parentName
                )
            )
        }
    }

    @discardableResult
    func submitEvidence(
        for occurrenceId: UUID,
        jpegData: Data? = nil
    ) async -> EvidenceSubmissionOutcome {
        if let jpegData {
            do {
                return try await submitRemoteEvidence(
                    for: occurrenceId,
                    jpegData: jpegData
                )
            } catch {
                debugPrint("Remote evidence submission failed:", error.localizedDescription)
                let message = "The photo could not be submitted. Check the connection and try again."
                familySyncState = .failed(message)
                return .failed(message)
            }
        }

        #if DEBUG
        submitMockEvidence(for: occurrenceId)
        return .reviewed
        #else
        let message = "Take a photo before submitting this chore."
        familySyncState = .failed(message)
        return .failed(message)
        #endif
    }

    func submitWithoutPhoto(for occurrenceId: UUID) async {
        do {
            guard SupabaseClientProvider.shared.auth.currentSession != nil else {
                #if DEBUG
                submitLocalCompletion(for: occurrenceId)
                #else
                familySyncState = .failed("Sign in before submitting this chore.")
                #endif
                return
            }

            _ = try await remoteStore.currentSession()
            let response = try await remoteStore.submitChoreWithoutPhoto(occurrenceId: occurrenceId)
            applyNoPhotoSubmission(
                submissionId: response.submissionId,
                occurrenceId: response.taskOccurrenceId,
                status: TaskOccurrenceStatus(rawValue: response.status) ?? .submitted,
                submittedAt: response.submittedAt
            )
        } catch {
            debugPrint("Remote no-photo submission failed:", error.localizedDescription)
            #if DEBUG
            submitLocalCompletion(for: occurrenceId)
            #else
            familySyncState = .failed("The chore could not be submitted. Check the connection and try again.")
            #endif
        }
    }

    private func submitRemoteEvidence(
        for occurrenceId: UUID,
        jpegData: Data
    ) async throws -> EvidenceSubmissionOutcome {
        guard let occurrence = occurrences.first(where: { $0.id == occurrenceId }) else {
            throw EvidenceSubmissionError.occurrenceNotFound
        }

        _ = try await remoteStore.currentSession()
        let submissionId = UUID()
        let imagePath = try await remoteStore.uploadEvidenceJPEG(
            familyId: familyId,
            occurrenceId: occurrenceId,
            submissionId: submissionId,
            jpegData: jpegData
        )

        let registration = try await remoteStore.registerPhotoSubmission(
            id: submissionId,
            occurrenceId: occurrenceId,
            imagePath: imagePath
        )

        let pendingSubmission = ChoreSubmission(
            id: registration.submissionId,
            taskOccurrenceId: registration.taskOccurrenceId,
            childId: occurrence.childId,
            imageName: imagePath,
            submittedAt: registration.submittedAt
        )
        upsertSubmission(pendingSubmission)
        updateOccurrence(occurrenceId) { task in
            task.submissionId = registration.submissionId
            task.status = .submitted
            task.updatedAt = Date()
        }
        publishWidgetSnapshot()

        do {
            let reviewResponse = try await remoteStore.reviewEvidence(
                submissionId: registration.submissionId
            )
            let submission = ChoreSubmission(
                id: reviewResponse.submissionId,
                taskOccurrenceId: reviewResponse.taskOccurrenceId,
                childId: occurrence.childId,
                imageName: imagePath,
                submittedAt: registration.submittedAt,
                aiResult: reviewResponse.aiResult.localResult
            )

            upsertSubmission(submission)
            updateOccurrence(occurrenceId) { task in
                task.submissionId = submission.id
                task.status = .aiReviewed
                task.updatedAt = Date()
            }
            publishWidgetSnapshot()
            return .reviewed
        } catch {
            debugPrint("AI review unavailable after photo submission:", error.localizedDescription)
            return .awaitingParentReview
        }
    }

    func evidenceImageData(for submission: ChoreSubmission) async throws -> Data? {
        let path = submission.imageName
        let familyPrefix = "\(familyId.uuidString)/".lowercased()
        guard path.lowercased().hasPrefix(familyPrefix) else {
            return nil
        }

        _ = try await remoteStore.currentSession()
        return try await remoteStore.downloadEvidence(path: path)
    }

    private func submitMockEvidence(for occurrenceId: UUID) {
        guard let index = occurrences.firstIndex(where: { $0.id == occurrenceId }) else {
            return
        }

        let chore = chore(for: occurrences[index])
        let result = mockAIResult(for: chore)
        let submission = ChoreSubmission(
            taskOccurrenceId: occurrenceId,
            childId: childId,
            imageName: "mock-\(chore.shortTitle.lowercased().replacingOccurrences(of: " ", with: "-"))",
            aiResult: result
        )

        upsertSubmission(submission)
        occurrences[index].submissionId = submission.id
        occurrences[index].status = .aiReviewed
        occurrences[index].updatedAt = Date()
        publishWidgetSnapshot()
    }

    private func submitLocalCompletion(for occurrenceId: UUID) {
        applyNoPhotoSubmission(
            submissionId: UUID(),
            occurrenceId: occurrenceId,
            status: .submitted,
            submittedAt: Date()
        )
    }

    private func applyNoPhotoSubmission(
        submissionId: UUID,
        occurrenceId: UUID,
        status: TaskOccurrenceStatus,
        submittedAt: Date
    ) {
        guard let index = occurrences.firstIndex(where: { $0.id == occurrenceId }) else {
            return
        }

        let submission = ChoreSubmission(
            id: submissionId,
            taskOccurrenceId: occurrenceId,
            childId: occurrences[index].childId,
            imageName: "no-photo",
            submittedAt: submittedAt
        )

        upsertSubmission(submission)
        occurrences[index].submissionId = submission.id
        occurrences[index].status = status
        occurrences[index].updatedAt = Date()
        publishWidgetSnapshot()
    }

    func approve(_ occurrence: TaskOccurrence) async -> Bool {
        await commitParentDecision(for: occurrence, decision: .approved)
    }

    func reject(_ occurrence: TaskOccurrence) async -> Bool {
        await commitParentDecision(for: occurrence, decision: .rejected)
    }

    func excuse(_ occurrence: TaskOccurrence, reason: String? = nil) async -> Bool {
        await commitParentDecision(for: occurrence, decision: .excused, note: reason)
    }

    func requestRetake(_ occurrence: TaskOccurrence) async -> Bool {
        let note = "Please send one clearer photo."
        return await commitParentDecision(for: occurrence, decision: .retakeRequested, note: note)
    }

    func requestExcuse(_ occurrence: TaskOccurrence) async -> Bool {
        let reason = "Child asked for a parent check."
        return await commitMutation(
            actionTitle: "Request parent review",
            successMessage: "Parent review requested across devices.",
            remoteSave: {
                _ = try await remoteStore.requestChoreExcuse(occurrenceId: occurrence.id, reason: reason)
            },
            localCommit: {
                updateOccurrence(occurrence.id) { task in
                    task.status = .submitted
                    task.excuseReason = reason
                    task.updatedAt = Date()
                }
                publishWidgetSnapshot()
            }
        )
    }

    func sendNudge(for occurrence: TaskOccurrence) async -> Bool {
        guard isParentSession, occurrence.childId == childId,
              occurrence.status.isOpen || occurrence.status == .missed else {
            return false
        }

        guard SupabaseClientProvider.shared.auth.currentSession != nil else {
            familySyncState = .failed("Sign in before sending a nudge.")
            return false
        }

        let chore = chore(for: occurrence)
        let dueTime = Self.widgetTimeFormatter.string(from: occurrence.dueAt)
        let message = occurrence.status == .missed
            ? "This chore was missed. Please check in with your parent about what to do next."
            : "This chore is still waiting. Due \(dueTime)."

        do {
            _ = try await remoteStore.currentSession()
            _ = try await remoteStore.createTaskNudge(
                familyId: familyId,
                occurrenceId: occurrence.id,
                childId: occurrence.childId,
                createdBy: session.userId,
                message: message
            )
            familySyncState = .synced("Alert queued for \(chore.shortTitle).")
            return true
        } catch {
            familySyncState = .failed("Nudge did not send: \(error.localizedDescription)")
            return false
        }
    }

    func addBonus(
        id: UUID = UUID(),
        title: String,
        amountCents: Int,
        note: String?
    ) async -> Bool {
        guard isParentSession, amountCents > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let entry = LedgerEntry(
            id: id,
            weekId: weekId,
            type: .bonus,
            title: title,
            amountCents: amountCents,
            note: note
        )
        return await commitMutation(
            actionTitle: "Add bonus",
            successMessage: "Bonus saved across devices.",
            remoteSave: {
                _ = try await remoteStore.createBonusLedgerEntry(
                    id: entry.id,
                    weekId: entry.weekId,
                    childId: childId,
                    createdBy: session.userId,
                    title: entry.title,
                    amountCents: entry.amountCents,
                    note: entry.note,
                    createdAt: entry.createdAt
                )
            },
            localCommit: {
                ledger.append(entry)
                publishWidgetSnapshot()
            }
        )
    }

    func saveSavingsGoals(_ goals: [SavingsGoal]) async -> Bool {
        guard isChildSession, goals.count <= 5, goals.allSatisfy(\.isValid) else { return false }
        return await commitMutation(
            actionTitle: "Save savings goals", successMessage: "Savings goals saved.",
            remoteSave: { try await remoteStore.saveSavingsGoals(childId: childId, goals: goals) },
            localCommit: {
                savingsGoals = goals
                publishWidgetSnapshot()
            }
        )
    }

    func updateAllowanceSettings(
        cadence: AllowanceCadence,
        allowanceWeekday: AllowanceWeekday,
        nextAllowanceDate: Date,
        baseAllowanceCents: Int? = nil
    ) async -> Bool {
        let updatedSettings = AllowanceSettings(
            familyId: familyId,
            baseAllowanceCents: max(0, baseAllowanceCents ?? allowanceSettings.baseAllowanceCents),
            cadence: cadence,
            allowanceWeekday: allowanceWeekday,
            nextAllowanceDate: Calendar.current.startOfDay(for: nextAllowanceDate)
        )
        let saved = await commitMutation(
            actionTitle: "Save allowance schedule",
            successMessage: "Allowance settings saved across devices.",
            remoteSave: {
                _ = try await remoteStore.updateFamilyAllowanceSettings(
                    familyId: updatedSettings.familyId,
                    settings: updatedSettings
                )
            },
            localCommit: {
                allowanceSettings = updatedSettings
                saveAllowanceSettings()
                publishWidgetSnapshot()
            }
        )
        if saved {
            await refreshNotificationScheduleIfAuthorized()
        }
        return saved
    }

    func updateEvidencePolicy(
        photoEvidenceEnabled: Bool,
        defaultVerificationMode: VerificationMode,
        blockPeopleInPhotos: Bool,
        evidenceRetentionMode: EvidenceRetentionMode,
        deleteGraceMinutes: Int,
        deleteAfterPeriodCloseDays: Int
    ) async -> Bool {
        let updatedPolicy = FamilyEvidencePolicy(
            familyId: familyId,
            photoEvidenceEnabled: photoEvidenceEnabled,
            defaultVerificationMode: defaultVerificationMode,
            blockPeopleInPhotos: blockPeopleInPhotos,
            evidenceRetentionMode: evidenceRetentionMode,
            deleteGraceMinutes: deleteGraceMinutes,
            deleteAfterPeriodCloseDays: deleteAfterPeriodCloseDays
        )
        return await commitMutation(
            actionTitle: "Save evidence settings",
            successMessage: "Evidence settings saved across devices.",
            remoteSave: {
                _ = try await remoteStore.upsertFamilyEvidencePolicy(updatedPolicy)
            },
            localCommit: {
                evidencePolicy = updatedPolicy
            }
        )
    }

    func allowsPhotoEvidence(for chore: ChoreDefinition) -> Bool {
        guard evidencePolicy.photoEvidenceEnabled else {
            return false
        }

        switch chore.verificationMode {
        case .photoRequired, .photoOptional:
            return true
        case .parentOnly, .noVerification:
            return false
        }
    }

    func blocksPeopleInEvidence(for chore: ChoreDefinition) -> Bool {
        allowsPhotoEvidence(for: chore)
            && (chore.blockPeopleInPhotos ?? evidencePolicy.blockPeopleInPhotos)
    }

    func allowsNoPhotoSubmission(for chore: ChoreDefinition) -> Bool {
        guard evidencePolicy.photoEvidenceEnabled else {
            return true
        }

        switch chore.verificationMode {
        case .photoRequired:
            return false
        case .photoOptional, .parentOnly, .noVerification:
            return true
        }
    }

    func enableLocalNotifications() async {
        notificationState = .requesting

        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])

            guard granted else {
                notificationState = .denied
                return
            }

            try await scheduleLocalNotifications()
            UIApplication.shared.registerForRemoteNotifications()
            notificationState = .scheduled
        } catch {
            notificationState = .failed(error.localizedDescription)
        }
    }

    private func syncAPNsDeviceToken() async {
        guard reminderStateReady,
              let token = UserDefaults.standard.string(forKey: PushTokenStore.key),
              !token.isEmpty,
              SupabaseClientProvider.shared.auth.currentSession != nil else { return }
        do {
            #if DEBUG
            let environment = "sandbox"
            #else
            let environment = "production"
            #endif
            try await remoteStore.upsertAPNsDeviceToken(familyId: familyId, token: token, environment: environment)
        } catch { debugPrint("Unable to register APNs token:", error.localizedDescription) }
    }

    func refreshNotificationScheduleIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        do {
            try await scheduleLocalNotifications()
            notificationState = .scheduled
        } catch {
            notificationState = .failed(error.localizedDescription)
        }
    }

    private func scheduleLocalNotifications() async throws {
        let center = UNUserNotificationCenter.current()
        guard reminderStateReady else {
            throw FamilySyncError.missingChildProfile
        }
        updateChoreReminders()
        let owner = session.userId
        let pending = await center.pendingNotificationRequests()
        guard reminderStateReady, session.userId == owner else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix("chaching.allowance.")
        }.map(\.identifier))

        let allowanceDate = nextAllowanceDate
        var allowanceComponents: DateComponents
        if allowanceSettings.cadence == .weekly {
            allowanceComponents = Calendar.current.dateComponents([.weekday], from: allowanceDate)
        } else {
            allowanceComponents = Calendar.current.dateComponents([.year, .month, .day], from: allowanceDate)
        }
        allowanceComponents.hour = 9
        allowanceComponents.minute = 0
        allowanceComponents.second = 0

        let allowanceContent = UNMutableNotificationContent()
        allowanceContent.title = "Allowance day"
        allowanceContent.body = "\(childName)'s \(AppBrand.displayName) total is ready to review."
        allowanceContent.sound = .default

        let allowanceTrigger = UNCalendarNotificationTrigger(
            dateMatching: allowanceComponents,
            repeats: allowanceSettings.cadence == .weekly
        )
        let allowanceRequest = UNNotificationRequest(
            identifier: allowanceNotificationIdentifier,
            content: allowanceContent,
            trigger: allowanceTrigger
        )
        try await center.add(allowanceRequest)
        try await ChoreReminderCenter.shared.schedule()
    }

    private func updateChoreReminders() {
        let items = ChoreReminderPlanner.items(chores: chores, occurrences: occurrences, childId: childId, now: Date())
        ChoreReminderCenter.shared.update(owner: "\(session.userId).\(familyId).\(childId)", items: items,
                                         goals: isChildSession ? savingsGoals : [])
    }

    private func processPendingTaskNudges(familyId: UUID, childId: UUID) async {
        guard isChildSession else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        do {
            let nudges = try await remoteStore.fetchPendingTaskNudges(familyId: familyId, childId: childId)
            var deliveredIds = deliveredNudgeIds()

            for nudge in nudges where !deliveredIds.contains(nudge.id.uuidString) {
                try await scheduleNudgeNotification(nudge)
                deliveredIds.insert(nudge.id.uuidString)
                saveDeliveredNudgeIds(deliveredIds)
                _ = try? await remoteStore.markTaskNudgeDelivered(id: nudge.id)
            }
        } catch {
            debugPrint("Unable to process task nudges:", error.localizedDescription)
        }
    }

    private func scheduleNudgeNotification(_ nudge: TaskNudgeRecord) async throws {
        let choreTitle = occurrences
            .first { $0.id == nudge.taskOccurrenceId }
            .flatMap { occurrence in chores.first { $0.id == occurrence.choreDefinitionId }?.shortTitle }

        let content = UNMutableNotificationContent()
        content.title = "\(parentName) sent a nudge"
        content.body = choreTitle.map { "\($0): \(nudge.message)" } ?? nudge.message
        content.sound = .default
        content.userInfo = [
            "owner": "\(session.userId).\(familyId).\(childId)",
            "chore_id": occurrences.first { $0.id == nudge.taskOccurrenceId }?.choreDefinitionId.uuidString ?? "",
            "kind": "task_nudge",
            "nudge_id": nudge.id.uuidString,
            "task_occurrence_id": nudge.taskOccurrenceId.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: nudgeNotificationIdentifier(nudgeId: nudge.id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    private var allowanceNotificationIdentifier: String {
        "chaching.allowance.\(familyId.uuidString)"
    }

    private func nudgeNotificationIdentifier(nudgeId: UUID) -> String {
        "chaching.nudge.\(nudgeId.uuidString)"
    }

    private func deliveredNudgeIds() -> Set<String> {
        Set(settingsStore.stringArray(forKey: deliveredNudgeIdsKey) ?? [])
    }

    private func saveDeliveredNudgeIds(_ ids: Set<String>) {
        settingsStore.set(Array(ids), forKey: deliveredNudgeIdsKey)
    }

    func addChore(
        id: UUID = UUID(),
        title: String,
        description: String,
        instructions: String,
        expectedEvidence: String,
        deductionCents: Int,
        dueTime: String,
        recurrence: ChoreRecurrence,
        verificationMode: VerificationMode,
        blockPeopleInPhotos: Bool,
        parentAlertEnabled: Bool = false,
        parentAlertDelayMinutes: Int = 0,
        location: ChoreLocation? = nil
    ) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDueTime = dueTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return failMutation(actionTitle: "Save chore", message: "Add a chore title.")
        }
        guard let dueAt = Self.dateToday(for: trimmedDueTime) else {
            return failMutation(actionTitle: "Save chore", message: "Use a due time like 8:00 PM.")
        }

        let now = Date()
        let dueWindowMinutes = 90
        let chore = ChoreDefinition(
            id: id,
            familyId: familyId,
            childId: childId,
            title: trimmedTitle,
            shortTitle: Self.shortTitle(from: trimmedTitle),
            description: Self.nonEmptyTrimmed(description, fallback: trimmedTitle),
            instructions: Self.nonEmptyTrimmed(instructions, fallback: "Complete \(trimmedTitle)."),
            expectedEvidence: Self.nonEmptyTrimmed(expectedEvidence, fallback: "A clear photo showing the completed chore."),
            deductionCents: max(0, deductionCents),
            verificationMode: verificationMode,
            blockPeopleInPhotos: blockPeopleInPhotos,
            recurrence: recurrence,
            dueTime: trimmedDueTime,
            dueWindowMinutes: dueWindowMinutes
            , parentAlertEnabled: parentAlertEnabled
            , parentAlertDelayMinutes: parentAlertDelayMinutes
            , location: location
        )
        let occurrence: TaskOccurrence? = recurrence.occurs(on: now) ? TaskOccurrence(
            id: chore.id,
            choreDefinitionId: chore.id,
            childId: childId,
            weekId: weekId,
            scheduledAt: dueAt,
            dueAt: dueAt,
            expiresAt: Calendar.current.date(byAdding: .minute, value: dueWindowMinutes, to: dueAt) ?? dueAt,
            status: dueAt <= now ? .due : .upcoming,
            createdAt: now,
            updatedAt: now
        ) : nil

        let saved = await commitMutation(
            actionTitle: "Save chore",
            successMessage: "Chore saved across devices.",
            remoteSave: {
                _ = try await remoteStore.createChore(chore)
                if let occurrence {
                    _ = try await remoteStore.createTaskOccurrence(occurrence)
                }
            },
            localCommit: {
                chores.removeAll { $0.id == chore.id }
                chores.append(chore)
                chores.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                if let occurrence {
                    occurrences.removeAll { $0.id == occurrence.id }
                    occurrences.append(occurrence)
                }
                publishWidgetSnapshot()
            }
        )
        if saved {
            await refreshNotificationScheduleIfAuthorized()
        }
        return saved
    }

    func updateChore(
        _ chore: ChoreDefinition,
        title: String,
        description: String,
        instructions: String,
        expectedEvidence: String,
        deductionCents: Int,
        dueTime: String,
        recurrence: ChoreRecurrence,
        verificationMode: VerificationMode,
        blockPeopleInPhotos: Bool,
        parentAlertEnabled: Bool = false,
        parentAlertDelayMinutes: Int = 0,
        location: ChoreLocation? = nil
    ) async -> Bool {
        guard let index = chores.firstIndex(where: { $0.id == chore.id }) else {
            return failMutation(actionTitle: "Save chore", message: "This chore is no longer available. Refresh and try again.")
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDueTime = dueTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return failMutation(actionTitle: "Save chore", message: "Add a chore title.")
        }
        guard Self.dateToday(for: trimmedDueTime) != nil else {
            return failMutation(actionTitle: "Save chore", message: "Use a due time like 8:00 PM.")
        }

        let choreId = chore.id
        let shortTitle = Self.shortTitle(from: trimmedTitle)
        let trimmedDescription = Self.nonEmptyTrimmed(description, fallback: trimmedTitle)
        let trimmedInstructions = Self.nonEmptyTrimmed(instructions, fallback: "Complete \(trimmedTitle).")
        let trimmedExpectedEvidence = Self.nonEmptyTrimmed(expectedEvidence, fallback: "A clear photo showing the completed chore.")
        let occurrenceUpdates = occurrenceTimeUpdates(
            for: choreId,
            dueTime: trimmedDueTime,
            dueWindowMinutes: chore.dueWindowMinutes,
            recurrence: recurrence
        )

        var updatedChore = chores[index]
        updatedChore.title = trimmedTitle
        updatedChore.shortTitle = shortTitle
        updatedChore.description = trimmedDescription
        updatedChore.instructions = trimmedInstructions
        updatedChore.expectedEvidence = trimmedExpectedEvidence
        updatedChore.deductionCents = max(0, deductionCents)
        updatedChore.recurrence = recurrence
        updatedChore.dueTime = trimmedDueTime
        updatedChore.verificationMode = verificationMode
        updatedChore.blockPeopleInPhotos = blockPeopleInPhotos
        updatedChore.parentAlertEnabled = parentAlertEnabled
        updatedChore.parentAlertDelayMinutes = max(0, parentAlertDelayMinutes)
        updatedChore.location = location
        updatedChore.updatedAt = Date()

        let saved = await commitMutation(
            actionTitle: "Save chore",
            successMessage: "Chore saved across devices.",
            remoteSave: {
                _ = try await remoteStore.updateChore(
                    id: choreId,
                    title: trimmedTitle,
                    shortTitle: shortTitle,
                    description: trimmedDescription,
                    instructions: trimmedInstructions,
                    expectedEvidence: trimmedExpectedEvidence,
                    deductionCents: max(0, deductionCents),
                    dueTime: trimmedDueTime,
                    recurrence: recurrence,
                    verificationMode: verificationMode,
                    blockPeopleInPhotos: blockPeopleInPhotos,
                    parentAlertEnabled: parentAlertEnabled,
                    parentAlertDelayMinutes: parentAlertDelayMinutes,
                    location: location
                )
                for update in occurrenceUpdates {
                    _ = try await remoteStore.updateOccurrenceTiming(
                        id: update.id,
                        scheduledAt: update.scheduledAt,
                        dueAt: update.dueAt,
                        expiresAt: update.expiresAt
                    )
                }
            },
            localCommit: {
                chores[index] = updatedChore
                for update in occurrenceUpdates {
                    updateOccurrence(update.id) { task in
                        task.scheduledAt = update.scheduledAt
                        task.dueAt = update.dueAt
                        task.expiresAt = update.expiresAt
                        if task.status == .upcoming || task.status == .due {
                            task.status = update.dueAt <= Date() ? .due : .upcoming
                        }
                        task.updatedAt = Date()
                    }
                }
                publishWidgetSnapshot()
            }
        )
        if saved {
            await refreshNotificationScheduleIfAuthorized()
        }
        return saved
    }

    func setChorePaused(_ chore: ChoreDefinition, isPaused: Bool) async -> Bool {
        guard let index = chores.firstIndex(where: { $0.id == chore.id }),
              chores[index].archivedAt == nil else {
            return failMutation(actionTitle: "Change chore status", message: "This chore is no longer available. Refresh and try again.")
        }

        let saved = await commitMutation(
            actionTitle: isPaused ? "Pause chore" : "Resume chore",
            successMessage: isPaused ? "Chore paused across devices." : "Chore resumed across devices.",
            remoteSave: {
                _ = try await remoteStore.setChoreLifecycle(
                    id: chore.id,
                    isPaused: isPaused,
                    archive: false
                )
            },
            localCommit: {
                chores[index].isPaused = isPaused
                chores[index].updatedAt = Date()
                if isPaused {
                    excuseOpenOccurrences(for: chore.id, reason: "Paused by parent.")
                }
                publishWidgetSnapshot()
            }
        )
        if saved {
            await refreshNotificationScheduleIfAuthorized()
        }
        return saved
    }

    func archiveChore(_ chore: ChoreDefinition) async -> Bool {
        guard let index = chores.firstIndex(where: { $0.id == chore.id }),
              chores[index].archivedAt == nil else {
            return failMutation(actionTitle: "Archive chore", message: "This chore is no longer available. Refresh and try again.")
        }

        let archivedAt = Date()
        let saved = await commitMutation(
            actionTitle: "Archive chore",
            successMessage: "Chore archived across devices.",
            remoteSave: {
                _ = try await remoteStore.setChoreLifecycle(
                    id: chore.id,
                    isPaused: true,
                    archive: true
                )
            },
            localCommit: {
                chores[index].isPaused = true
                chores[index].archivedAt = archivedAt
                chores[index].updatedAt = archivedAt
                excuseOpenOccurrences(for: chore.id, reason: "Archived by parent.")
                publishWidgetSnapshot()
            }
        )
        if saved {
            await refreshNotificationScheduleIfAuthorized()
        }
        return saved
    }

    private func applyLocalPreviewState() {
        savingsGoals = []
        let snapshot = SeedData.snapshot()
        familyId = snapshot.familyId
        parentId = snapshot.parentId
        childId = snapshot.childId
        weekId = snapshot.weekId
        familyName = snapshot.familyName
        childName = snapshot.childName
        parentName = snapshot.parentName
        session = AppSession(userId: snapshot.parentId, role: .parent, displayName: snapshot.parentName)
        members = snapshot.members
        childProfiles = snapshot.childProfiles
        childInvites = snapshot.childInvites
        parentInvites = snapshot.parentInvites
        pendingInvite = nil
        inviteAcceptanceState = .idle
        inviteCreationState = .idle
        chores = snapshot.chores
        occurrences = snapshot.occurrences
        submissions = snapshot.submissions
        ledger = snapshot.ledger
        allowancePeriods = snapshot.allowancePeriods
        allowanceSettlements = [:]
        evidencePolicy = snapshot.evidencePolicy

        if let savedSettings = Self.loadAllowanceSettings(from: settingsStore, key: allowanceSettingsKey),
           savedSettings.familyId == snapshot.familyId {
            allowanceSettings = savedSettings
        } else {
            allowanceSettings = snapshot.allowanceSettings
        }

        publishWidgetSnapshot()
    }

    private func applyRemoteFamilyState(for membership: FamilyMemberRecord, authUserId: UUID, selectingChildId: UUID? = nil, generation: UUID) async throws {
        let role = FamilyMemberRole(rawValue: membership.role) ?? .parent
        let familyRecord = try await remoteStore.fetchFamily(id: membership.familyId)
        let memberRecords = try await remoteStore.fetchFamilyMembers(familyId: membership.familyId)
        let profileRecords = try await remoteStore.fetchChildProfiles(familyId: membership.familyId)
        let evidencePolicyRecord = try await remoteStore.fetchFamilyEvidencePolicy(familyId: membership.familyId)

        let selectionKey = "chaching.selectedChild.\(authUserId).\(membership.familyId)"
        let savedChildId = settingsStore.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
        guard let selectedChildProfile = ChildProfile.selected(
            from: profileRecords.map { localChildProfile(from: $0) },
            familyId: membership.familyId,
            role: role,
            userId: authUserId,
            preferredId: selectingChildId ?? savedChildId
        ) else {
            throw FamilySyncError.missingChildProfile
        }

        _ = try await remoteStore.processTaskOccurrenceDeadlines(
            familyId: membership.familyId,
            childProfileId: selectedChildProfile.id
        )
        _ = try await remoteStore.ensureCurrentTaskOccurrences(
            familyId: membership.familyId,
            childProfileId: selectedChildProfile.id
        )

        let weekRecords = try await remoteStore.fetchWeeks(
            familyId: membership.familyId,
            childId: selectedChildProfile.id
        )
        let settlementRecords = try await remoteStore.fetchAllowanceSettlements(weekIds: weekRecords.map(\.id))
        let settlements = Dictionary(uniqueKeysWithValues: settlementRecords.map {
            ($0.weekId, AllowanceSettlement(amountCents: $0.amountCents, confirmedAt: $0.confirmedAt, paidAt: $0.paidAt))
        })

        guard let weekRecord = weekRecords.first(where: { $0.archivedAt == nil }) ?? weekRecords.first else {
            throw FamilySyncError.missingCurrentWeek
        }

        let choreRecords = try await remoteStore.fetchChores(familyId: membership.familyId)
        let reviewWeekIds = weekRecords.filter { $0.id == weekRecord.id || settlements[$0.id] == nil }.map(\.id)
        let occurrenceRecords = try await remoteStore.fetchOccurrences(weekIds: reviewWeekIds)
        let submissionRecords = try await remoteStore.fetchChoreSubmissions(childId: selectedChildProfile.id)
        let ledgerRecords = try await remoteStore.fetchLedger(childId: selectedChildProfile.id)
        let localLedgerEntries = ledgerRecords.map { localLedgerEntry(from: $0) }
        let entriesByWeek = Dictionary(grouping: localLedgerEntries, by: \.weekId)

        let remoteOccurrences = occurrenceRecords.map { localOccurrence(from: $0) }
        let occurrenceIds = Set(remoteOccurrences.map(\.id))
        let remoteSubmissions = submissionRecords
            .filter { occurrenceIds.contains($0.taskOccurrenceId) }
            .map { localSubmission(from: $0) }

        guard remoteRefreshGeneration == generation,
              SupabaseClientProvider.shared.auth.currentSession?.user.id == authUserId else {
            throw CancellationError()
        }
        if role == .parent {
            settingsStore.set(selectedChildProfile.id.uuidString, forKey: selectionKey)
        }
        familyId = familyRecord.id
        childId = selectedChildProfile.id
        weekId = weekRecord.id
        familyName = familyRecord.name
        childName = selectedChildProfile.displayName
        savingsGoals = profileRecords.first { $0.id == selectedChildProfile.id }?.savingsGoals ?? []

        let parentMember = memberRecords.first { $0.role == FamilyMemberRole.parent.rawValue }
        parentId = parentMember?.userId ?? (role == .parent ? authUserId : parentId)
        parentName = parentMember?.displayName ?? (role == .parent ? membership.displayName : parentName)
        session = AppSession(userId: authUserId, role: role, displayName: membership.displayName)

        members = memberRecords.map { localFamilyMember(from: $0) }
        childProfiles = profileRecords.map { localChildProfile(from: $0) }
        childInvites = []
        parentInvites = []
        chores = choreRecords
            .filter { $0.childId == selectedChildProfile.id }
            .map { localChoreDefinition(from: $0) }
        occurrences = remoteOccurrences
        reminderStateReady = true
        submissions = remoteSubmissions
        ledger = entriesByWeek[weekRecord.id] ?? []
        allowancePeriods = weekRecords.map {
            localAllowancePeriod(from: $0, entries: entriesByWeek[$0.id] ?? [], settlement: settlements[$0.id])
        }
        allowanceSettlements = settlements
        evidencePolicy = evidencePolicyRecord.map { localEvidencePolicy(from: $0) }
            ?? FamilyEvidencePolicy(familyId: familyRecord.id)

        if let remoteSettings = Self.allowanceSettings(from: familyRecord) {
            allowanceSettings = remoteSettings
            saveAllowanceSettings()
        } else if let savedSettings = Self.loadAllowanceSettings(from: settingsStore, key: allowanceSettingsKey),
                  savedSettings.familyId == familyRecord.id {
            allowanceSettings = savedSettings
        } else {
            allowanceSettings = AllowanceSettings(
                familyId: familyRecord.id,
                baseAllowanceCents: familyRecord.weeklyBaseAllowanceCents,
                cadence: .weekly,
                allowanceWeekday: .friday,
                nextAllowanceDate: Self.nextAllowanceDate(for: .friday)
            )
            saveAllowanceSettings()
        }

        publishWidgetSnapshot()
        await syncAPNsDeviceToken()
        guard remoteRefreshGeneration == generation else { return }
        await processPendingTaskNudges(familyId: familyRecord.id, childId: selectedChildProfile.id)
        await refreshNotificationScheduleIfAuthorized()
    }

    private func localFamilyMember(from record: FamilyMemberRecord) -> FamilyMember {
        FamilyMember(
            familyId: record.familyId,
            userId: record.userId,
            role: FamilyMemberRole(rawValue: record.role) ?? .parent,
            displayName: record.displayName,
            createdAt: record.createdAt
        )
    }

    private func localChildProfile(from record: ChildProfileRecord) -> ChildProfile {
        ChildProfile(
            id: record.id,
            familyId: record.familyId,
            displayName: record.displayName,
            phoneNumber: record.phoneE164,
            linkedUserId: record.linkedUserId,
            createdByParentId: record.createdByParentId ?? parentId,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func localChoreDefinition(from record: ChoreDefinitionRecord) -> ChoreDefinition {
        let frequency = ChoreRepeatFrequency(rawValue: record.recurrence.type) ?? .daily
        let weekdays = record.recurrence.weekdays?.compactMap(ChoreWeekday.init(rawValue:)) ?? []

        return ChoreDefinition(
            id: record.id,
            familyId: record.familyId,
            childId: record.childId,
            title: record.title,
            shortTitle: record.shortTitle,
            description: record.description ?? "",
            instructions: record.instructions ?? "",
            expectedEvidence: record.expectedEvidence ?? "A clear photo showing the completed chore.",
            deductionCents: record.deductionCents,
            verificationMode: VerificationMode(rawValue: record.verificationMode) ?? .photoRequired,
            blockPeopleInPhotos: record.blockPeopleInPhotos,
            evidenceRetentionMode: record.evidenceRetentionMode.flatMap { EvidenceRetentionMode(rawValue: $0) },
            evidenceDeleteGraceMinutes: record.evidenceDeleteGraceMinutes,
            recurrence: ChoreRecurrence(
                frequency: frequency,
                weekdays: weekdays,
                oneTimeDate: record.recurrence.dueAt
            ),
            dueTime: record.recurrence.times?.first ?? "8:00 PM",
            dueWindowMinutes: record.dueWindowMinutes,
            reminderOffsetsMinutes: record.reminderOffsetsMinutes,
            parentAlertEnabled: record.parentAlertEnabled,
            parentAlertDelayMinutes: record.parentAlertDelayMinutes,
            location: {
                guard let name = record.locationName,
                      let latitude = record.locationLatitude,
                      let longitude = record.locationLongitude else { return nil }
                return ChoreLocation(
                    name: name,
                    latitude: latitude,
                    longitude: longitude,
                    radiusMeters: record.locationRadiusMeters ?? 200,
                    leaveReminderMinutes: record.locationLeaveReminderMinutes ?? 30
                )
            }(),
            isPaused: record.isPaused,
            archivedAt: record.archivedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func localOccurrence(from record: TaskOccurrenceRecord) -> TaskOccurrence {
        TaskOccurrence(
            id: record.id,
            choreDefinitionId: record.choreDefinitionId,
            childId: record.childId,
            weekId: record.weekId,
            scheduledAt: record.scheduledAt,
            dueAt: record.dueAt,
            expiresAt: record.expiresAt,
            status: TaskOccurrenceStatus(rawValue: record.status) ?? .upcoming,
            submissionId: record.submissionId,
            deductionLedgerEntryId: record.deductionLedgerEntryId,
            excuseReason: record.excuseReason,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func localSubmission(from record: ChoreSubmissionRecord) -> ChoreSubmission {
        ChoreSubmission(
            id: record.id,
            taskOccurrenceId: record.taskOccurrenceId,
            childId: record.childId,
            imageName: record.imagePath ?? "no-photo",
            submittedAt: record.submittedAt,
            aiResult: record.aiResult.map { localAIReviewResult(from: $0) },
            parentDecision: record.parentDecision.flatMap { localParentDecision(from: $0) }
        )
    }

    private func localEvidencePolicy(from record: FamilyEvidencePolicyRecord) -> FamilyEvidencePolicy {
        FamilyEvidencePolicy(
            familyId: record.familyId,
            photoEvidenceEnabled: record.photoEvidenceEnabled,
            defaultVerificationMode: VerificationMode(rawValue: record.defaultVerificationMode) ?? .photoOptional,
            blockPeopleInPhotos: record.blockPeopleInPhotos,
            evidenceRetentionMode: EvidenceRetentionMode(rawValue: record.evidenceRetentionMode) ?? .afterParentReview,
            deleteGraceMinutes: record.deleteGraceMinutes,
            deleteAfterPeriodCloseDays: record.deleteAfterPeriodCloseDays
        )
    }

    private func localAIReviewResult(from record: RemoteAIReviewResult) -> AIReviewResult {
        AIReviewResult(
            completed: record.completed,
            confidence: record.confidence,
            reason: record.reason,
            retakeSuggested: record.retakeSuggested,
            retakeInstruction: record.retakeInstruction,
            parentReviewPriority: record.parentReviewPriority,
            modelName: record.modelName,
            reviewedAt: record.reviewedAt
        )
    }

    private func localParentDecision(from record: RemoteParentDecision) -> ParentDecision? {
        guard let decision = ParentDecision.Decision(rawValue: record.decision),
              let parentId = record.parentId else {
            return nil
        }

        return ParentDecision(
            decision: decision,
            note: record.note,
            decidedAt: record.decidedAt ?? Date(),
            parentId: parentId
        )
    }

    private func localLedgerEntry(from record: LedgerEntryRecord) -> LedgerEntry {
        LedgerEntry(
            id: record.id,
            weekId: record.weekId,
            type: LedgerEntryType(rawValue: record.entryType) ?? .adjustment,
            title: record.title,
            amountCents: record.amountCents,
            relatedOccurrenceId: record.relatedOccurrenceId,
            note: record.note,
            isVoided: record.isVoided,
            createdAt: record.createdAt
        )
    }

    private func localAllowancePeriod(
        from record: WeekRecord,
        entries: [LedgerEntry],
        settlement: AllowanceSettlement? = nil
    ) -> AllowancePeriod {
        AllowancePeriod(
            id: record.id,
            familyId: record.familyId,
            childId: record.childId,
            startsAt: record.startsAt,
            endsAt: record.endsAt,
            baseAllowanceCents: record.baseAllowanceCents,
            archivedAt: record.archivedAt,
            finalBalanceCents: record.finalBalanceCents,
            entries: entries,
            settlement: settlement
        )
    }

    private func updateSettlement(periodId: UUID, amountCents: Int, confirmedAt: Date, paidAt: Date?) {
        allowanceSettlements[periodId] = AllowanceSettlement(amountCents: amountCents, confirmedAt: confirmedAt, paidAt: paidAt)
        allowancePeriods = allowancePeriods.map { period in
            var updated = period
            if updated.id == periodId { updated.settlement = allowanceSettlements[periodId] }
            return updated
        }
    }

    private func applySettlement(_ record: AllowanceSettlementRecord) {
        updateSettlement(periodId: record.weekId, amountCents: record.amountCents, confirmedAt: record.confirmedAt, paidAt: record.paidAt)
    }

    private static func allowanceSettings(from record: FamilyRecord) -> AllowanceSettings? {
        guard let cadenceRawValue = record.allowanceCadence,
              let cadence = AllowanceCadence(rawValue: cadenceRawValue),
              let weekdayRawValue = record.allowanceWeekday,
              let weekday = AllowanceWeekday(rawValue: weekdayRawValue) else {
            return nil
        }

        return AllowanceSettings(
            familyId: record.id,
            baseAllowanceCents: record.weeklyBaseAllowanceCents,
            cadence: cadence,
            allowanceWeekday: weekday,
            nextAllowanceDate: record.nextAllowanceAt ?? nextAllowanceDate(for: weekday)
        )
    }

    private func updateOccurrence(_ id: UUID, mutation: (inout TaskOccurrence) -> Void) {
        guard let index = occurrences.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&occurrences[index])
    }

    private func excuseOpenOccurrences(for choreId: UUID, reason: String) {
        let now = Date()
        for index in occurrences.indices where
            occurrences[index].choreDefinitionId == choreId && occurrences[index].status.isOpen {
            occurrences[index].status = .excused
            occurrences[index].excuseReason = reason
            occurrences[index].updatedAt = now
        }
    }

    private func updateInvite(_ id: UUID, mutation: (inout ChildInvite) -> Void) {
        guard let index = childInvites.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&childInvites[index])
    }

    private func updateParentInvite(_ id: UUID, mutation: (inout ParentInvite) -> Void) {
        guard let index = parentInvites.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&parentInvites[index])
    }

    private func updateChildProfile(_ id: UUID, mutation: (inout ChildProfile) -> Void) {
        guard let index = childProfiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&childProfiles[index])
    }

    private func occurrenceTimeUpdates(
        for choreId: UUID,
        dueTime: String,
        dueWindowMinutes: Int,
        recurrence: ChoreRecurrence
    ) -> [OccurrenceTimeUpdate] {
        occurrences.compactMap { occurrence in
            guard occurrence.choreDefinitionId == choreId,
                  occurrence.status.isOpen,
                  recurrence.occurs(on: occurrence.dueAt),
                  let dueAt = Self.date(onSameDayAs: occurrence.dueAt, time: dueTime) else {
                return nil
            }

            return OccurrenceTimeUpdate(
                id: occurrence.id,
                scheduledAt: dueAt,
                dueAt: dueAt,
                expiresAt: Calendar.current.date(
                    byAdding: .minute,
                    value: dueWindowMinutes,
                    to: dueAt
                ) ?? dueAt
            )
        }
    }

    private func upsertSubmission(_ submission: ChoreSubmission) {
        if let index = submissions.firstIndex(where: { $0.id == submission.id }) {
            submissions[index] = submission
        } else if let index = submissions.firstIndex(where: { $0.taskOccurrenceId == submission.taskOccurrenceId }) {
            submissions[index] = submission
        } else {
            submissions.append(submission)
        }
    }

    private func applyChildProfileRecord(_ record: ChildProfileRecord) {
        let profile = ChildProfile(
            id: record.id,
            familyId: record.familyId,
            displayName: record.displayName,
            phoneNumber: record.phoneE164,
            linkedUserId: record.linkedUserId,
            createdByParentId: record.createdByParentId ?? parentId,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )

        if let index = childProfiles.firstIndex(where: { $0.id == record.id }) {
            childProfiles[index] = profile
        } else {
            childProfiles.append(profile)
        }
    }

    private func applyChildInviteRecord(_ record: ChildInviteRecord, token: String) {
        let invite = ChildInvite(
            id: record.id,
            familyId: record.familyId,
            childProfileId: record.childProfileId,
            childName: record.childName,
            phoneNumber: record.phoneE164,
            createdByParentId: record.createdByParentId ?? parentId,
            token: token,
            inviteURL: AppBrand.inviteURL(token: token),
            status: ChildInviteStatus(rawValue: record.status) ?? .pending,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            acceptedAt: record.acceptedAt,
            acceptedChildUserId: record.acceptedChildUserId
        )

        if let index = childInvites.firstIndex(where: { $0.id == record.id }) {
            childInvites[index] = invite
        } else {
            childInvites.insert(invite, at: 0)
        }
    }

    private func applyParentInviteRecord(_ record: ParentInviteRecord, token: String) {
        let invite = ParentInvite(
            id: record.id,
            familyId: record.familyId,
            parentName: record.parentName,
            phoneNumber: record.phoneE164,
            createdByParentId: record.createdByParentId ?? parentId,
            token: token,
            inviteURL: AppBrand.inviteURL(token: token),
            status: ParentInviteStatus(rawValue: record.status) ?? .pending,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            acceptedAt: record.acceptedAt,
            acceptedParentUserId: record.acceptedParentUserId
        )

        if let index = parentInvites.firstIndex(where: { $0.id == record.id }) {
            parentInvites[index] = invite
        } else {
            parentInvites.insert(invite, at: 0)
        }
    }

    private func applyAcceptedChildInvite(_ acceptedInvite: AcceptedChildInvite, token: String) {
        let now = Date()

        if let index = childInvites.firstIndex(where: { $0.token == token }) {
            childInvites[index].status = .accepted
            childInvites[index].acceptedAt = now
            childInvites[index].acceptedChildUserId = acceptedInvite.acceptedChildUserId
        }

        if let index = childProfiles.firstIndex(where: { $0.id == acceptedInvite.childProfileId }) {
            childProfiles[index].linkedUserId = acceptedInvite.acceptedChildUserId
            childProfiles[index].updatedAt = now
        } else {
            childProfiles.append(
                ChildProfile(
                    id: acceptedInvite.childProfileId,
                    familyId: acceptedInvite.familyId,
                    displayName: acceptedInvite.childName,
                    linkedUserId: acceptedInvite.acceptedChildUserId,
                    createdByParentId: parentId,
                    updatedAt: now
                )
            )
        }

        if !members.contains(where: { $0.userId == acceptedInvite.acceptedChildUserId && $0.role == .child }) {
            members.append(
                FamilyMember(
                    familyId: acceptedInvite.familyId,
                    userId: acceptedInvite.acceptedChildUserId,
                    role: .child,
                    displayName: acceptedInvite.childName
                )
            )
        }

        session = AppSession(
            userId: acceptedInvite.acceptedChildUserId,
            role: .child,
            displayName: acceptedInvite.childName
        )
    }

    private func applyAcceptedParentInvite(_ acceptedInvite: AcceptedParentInvite, token: String) {
        let now = Date()

        if let index = parentInvites.firstIndex(where: { $0.token == token }) {
            parentInvites[index].status = .accepted
            parentInvites[index].acceptedAt = now
            parentInvites[index].acceptedParentUserId = acceptedInvite.acceptedParentUserId
        }

        if !members.contains(where: { $0.userId == acceptedInvite.acceptedParentUserId && $0.role == .parent }) {
            members.append(
                FamilyMember(
                    familyId: acceptedInvite.familyId,
                    userId: acceptedInvite.acceptedParentUserId,
                    role: .parent,
                    displayName: acceptedInvite.parentName
                )
            )
        }

        session = AppSession(
            userId: acceptedInvite.acceptedParentUserId,
            role: .parent,
            displayName: acceptedInvite.parentName
        )
    }

    private func upsertLocalChildProfile(
        id: UUID,
        childName: String,
        phoneNumber: String?,
        updatedAt: Date
    ) {
        if let index = childProfiles.firstIndex(where: { $0.id == id }) {
            childProfiles[index].displayName = childName
            childProfiles[index].phoneNumber = phoneNumber
            childProfiles[index].updatedAt = updatedAt
            return
        }

        let profile = ChildProfile(
            id: id,
            familyId: familyId,
            displayName: childName,
            phoneNumber: phoneNumber,
            createdByParentId: parentId,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
        childProfiles.append(profile)
    }

    private func makeInviteToken(for inviteeName: String, prefix: String, nonce: UUID) -> String {
        let namePrefix = inviteeName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .prefix(12)
        return "\(prefix)-\(namePrefix)-\(nonce.uuidString.lowercased())"
    }

    private func inviteToken(from url: URL) -> String? {
        guard url.host == "enormousbrain.com" else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 3,
              pathComponents[0] == "cha-ching",
              pathComponents[1] == "invite" else {
            return nil
        }

        let token = pathComponents[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func normalizedPhoneNumber(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("+") {
            let digits = trimmed.dropFirst().filter(\.isNumber)
            return digits.count >= 8 ? "+\(digits)" : nil
        }

        let digits = trimmed.filter(\.isNumber)
        if digits.count == 10 {
            return "+1\(digits)"
        }
        if digits.count == 11, digits.first == "1" {
            return "+\(digits)"
        }
        return nil
    }

    private static func normalizedEmail(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains("@"),
              trimmed.contains("."),
              !trimmed.hasPrefix("@"),
              !trimmed.hasSuffix("@") else {
            return nil
        }

        return trimmed
    }

    private static func dateToday(for time: String) -> Date? {
        date(onSameDayAs: Date(), time: time)
    }

    private static func date(onSameDayAs date: Date, time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        guard let parsedTime = formatter.date(from: time) else {
            return nil
        }

        let calendar = Calendar.current
        let timeComponents = calendar.dateComponents([.hour, .minute], from: parsedTime)
        var dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        dayComponents.hour = timeComponents.hour
        dayComponents.minute = timeComponents.minute
        return calendar.date(from: dayComponents)
    }

    private static func shortTitle(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Chore"
        }

        guard trimmed.count > 18 else {
            return trimmed
        }

        return String(trimmed.prefix(18)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmptyTrimmed(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func nextAllowanceDate(for weekday: AllowanceWeekday, after date: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        let currentWeekday = calendar.component(.weekday, from: today)
        let daysUntil = (weekday.rawValue - currentWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: daysUntil, to: today) ?? today
    }

    private static let widgetTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static func loadAllowanceSettings(from store: UserDefaults, key: String) -> AllowanceSettings? {
        guard let data = store.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(AllowanceSettings.self, from: data)
    }

    private func saveAllowanceSettings() {
        guard let data = try? JSONEncoder().encode(allowanceSettings) else {
            return
        }

        settingsStore.set(data, forKey: allowanceSettingsKey)
    }

    private func publishWidgetSnapshot() {
        if reminderStateReady {
            updateChoreReminders()
            Task { await refreshNotificationScheduleIfAuthorized() }
        }
        let summary = allowanceSummary
        let nextOccurrence = nextDueOccurrence
        let nextChore = nextOccurrence.map { chore(for: $0) }
        let snapshot = ChaChingWidgetSnapshot(
            updatedAt: Date(),
            periodTitle: allowancePeriodTitle,
            childName: childName,
            currentCents: summary.currentTotalCents,
            baseCents: summary.weeklyBaseCents,
            rolloverDebtCents: summary.rolloverDebtCents,
            choresLeft: remainingCount,
            nextChoreTitle: nextChore?.shortTitle ?? "All done",
            nextChoreTime: nextOccurrence.map { Self.widgetTimeFormatter.string(from: $0.dueAt) } ?? "Nice work",
            trend: allowanceTrend,
            periodEndsAt: activeAllowancePeriod?.endsAt
        )

        guard ChaChingWidgetSharedState.saveSnapshot(snapshot) else {
            return
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: ChaChingWidgetSharedState.widgetKind)
        #endif
    }

    private func decideSubmission(for occurrence: TaskOccurrence, decision: ParentDecision.Decision, note: String? = nil) {
        guard let index = submissions.firstIndex(where: { $0.taskOccurrenceId == occurrence.id }) else {
            return
        }

        submissions[index].parentDecision = ParentDecision(
            decision: decision,
            note: note,
            parentId: parentId
        )
    }

    private var mutationPersistenceMode: MutationPersistenceMode {
        SupabaseClientProvider.shared.auth.currentSession == nil ? .localPreview : .remoteRequired
    }

    @discardableResult
    private func commitMutation(
        actionTitle: String,
        successMessage: String,
        remoteSave: () async throws -> Void,
        localCommit: () -> Void
    ) async -> Bool {
        guard activeMutationTitle == nil else {
            return false
        }

        let mode = mutationPersistenceMode
        mutationFailure = nil
        activeMutationTitle = actionTitle

        do {
            try await MutationCommitter.commit(
                mode: mode,
                remoteSave: {
                    _ = try await remoteStore.currentSession()
                    try await remoteSave()
                },
                localCommit: localCommit
            )
            activeMutationTitle = nil
            if mode == .remoteRequired {
                familySyncState = .synced(successMessage)
            }
            return true
        } catch {
            activeMutationTitle = nil
            let message = "Your current data was kept. Check the connection and try again. \(error.localizedDescription)"
            mutationFailure = MutationFailure(title: "Couldn't \(actionTitle.lowercased())", message: message)
            familySyncState = .failed(message)
            return false
        }
    }

    @discardableResult
    private func failMutation(actionTitle: String, message: String) -> Bool {
        mutationFailure = MutationFailure(title: "Couldn't \(actionTitle.lowercased())", message: message)
        familySyncState = .failed(message)
        return false
    }

    private func commitParentDecision(
        for occurrence: TaskOccurrence,
        decision: ParentDecision.Decision,
        note: String? = nil
    ) async -> Bool {
        let historical = occurrence.weekId != weekId
        let saved = await commitMutation(
            actionTitle: "Save review",
            successMessage: "Review saved across devices.",
            remoteSave: {
                _ = try await remoteStore.decideSubmission(
                    occurrenceId: occurrence.id,
                    decision: decision,
                    note: note
                )
            },
            localCommit: {
                if !historical { applyParentDecisionLocally(for: occurrence, decision: decision, note: note) }
            }
        )
        if saved && historical { await refreshRemoteFamilyState() }
        return saved
    }

    private func applyParentDecisionLocally(
        for occurrence: TaskOccurrence,
        decision: ParentDecision.Decision,
        note: String?
    ) {
        let updatedStatus: TaskOccurrenceStatus
        switch decision {
        case .approved:
            updatedStatus = .approved
        case .rejected:
            updatedStatus = .rejected
        case .excused:
            updatedStatus = .excused
        case .retakeRequested:
            updatedStatus = .due
        }

        updateOccurrence(occurrence.id) { task in
            task.status = updatedStatus
            if decision == .excused {
                task.excuseReason = note
            }
            task.updatedAt = Date()
        }
        decideSubmission(for: occurrence, decision: decision, note: note)

        switch decision {
        case .approved, .excused:
            ledger = AllowanceEngine.voidingDeduction(in: ledger, for: occurrence.id)
        case .rejected:
            addDeductionIfNeeded(for: occurrence, chore: chore(for: occurrence))
        case .retakeRequested:
            break
        }
        publishWidgetSnapshot()
    }

    private func addDeductionIfNeeded(for occurrence: TaskOccurrence, chore: ChoreDefinition) {
        guard !AllowanceEngine.deductionExists(in: ledger, for: occurrence.id) else {
            return
        }

        let entry = AllowanceEngine.deductionEntry(
            weekId: weekId,
            occurrenceId: occurrence.id,
            choreTitle: chore.title,
            amountCents: chore.deductionCents
        )
        ledger.append(entry)
        updateOccurrence(occurrence.id) { task in
            task.deductionLedgerEntryId = entry.id
        }
    }

    private func mockAIResult(for chore: ChoreDefinition) -> AIReviewResult {
        if chore.title.contains("Bathroom") {
            return AIReviewResult(
                completed: nil,
                confidence: 0.62,
                reason: "The photo is partly clear, but the whole counter is not visible.",
                retakeSuggested: false
            )
        }

        return AIReviewResult(
            completed: true,
            confidence: 0.92,
            reason: "The image appears to show the expected chore evidence.",
            retakeSuggested: false
        )
    }

}

private extension RemoteAIReviewResult {
    var localResult: AIReviewResult {
        AIReviewResult(
            completed: completed,
            confidence: confidence,
            reason: reason,
            retakeSuggested: retakeSuggested,
            retakeInstruction: retakeInstruction,
            parentReviewPriority: parentReviewPriority,
            modelName: modelName,
            reviewedAt: reviewedAt
        )
    }
}

enum EvidenceSubmissionOutcome: Equatable {
    case reviewed
    case awaitingParentReview
    case failed(String)
}

private enum EvidenceSubmissionError: LocalizedError {
    case occurrenceNotFound

    var errorDescription: String? {
        "The chore is no longer available. Refresh and try again."
    }
}

struct AppSession: Equatable {
    var userId: UUID
    var role: FamilyMemberRole
    var displayName: String
}

struct PendingInvite: Identifiable, Equatable {
    var token: String
    var url: URL

    var id: String { token }

    var kind: PendingInviteKind {
        token.hasPrefix("parent-") ? .parent : .child
    }
}

enum PendingInviteKind: Equatable {
    case child
    case parent
}

struct MutationFailure: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

enum InviteAcceptanceState: Equatable {
    case idle
    case requestingCode
    case codeSent(phoneNumber: String)
    case accepting
    case accepted(displayName: String, role: FamilyMemberRole)
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .requestingCode, .accepting:
            return true
        case .idle, .codeSent, .accepted, .failed:
            return false
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    var acceptedDisplayName: String? {
        if case .accepted(let displayName, _) = self {
            return displayName
        }
        return nil
    }

    var acceptedRole: FamilyMemberRole? {
        if case .accepted(_, let role) = self {
            return role
        }
        return nil
    }
}

enum InviteCreationState: Equatable {
    case idle
    case creating
    case synced(String)
    case localOnly(String)
    case failed(String)

    var isWorking: Bool {
        if case .creating = self {
            return true
        }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .creating:
            return nil
        case .synced(let message), .localOnly(let message), .failed(let message):
            return message
        }
    }

    var iconName: String {
        switch self {
        case .idle, .creating:
            return "arrow.triangle.2.circlepath"
        case .synced:
            return "checkmark.icloud.fill"
        case .localOnly:
            return "icloud.slash.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var isSynced: Bool {
        if case .synced = self {
            return true
        }
        return false
    }
}

enum NotificationState: Equatable {
    case idle
    case requesting
    case scheduled
    case denied
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "Reminders are not enabled yet."
        case .requesting:
            return "Requesting notification permission..."
        case .scheduled:
            return "Chore and allowance reminders are scheduled."
        case .denied:
            return "Notifications are off. You can enable them in iOS Settings."
        case .failed(let message):
            return message
        }
    }
}

enum FamilySyncState: Equatable {
    case localPreview
    case loading
    case codeSent(phoneNumber: String)
    case emailCodeSent(email: String)
    case needsBootstrap(String)
    case synced(String)
    case failed(String)

    var message: String {
        switch self {
        case .localPreview:
            return "Using preview data on this phone. Sign in to sync this family across devices."
        case .loading:
            return "Working on family sync..."
        case .codeSent(let phoneNumber):
            return "Code sent to \(phoneNumber)."
        case .emailCodeSent(let email):
            return "Code sent to \(email)."
        case .needsBootstrap(let message):
            return message
        case .synced(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    var isWorking: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var isSynced: Bool {
        if case .synced = self {
            return true
        }
        return false
    }

    var needsBootstrap: Bool {
        if case .needsBootstrap = self {
            return true
        }
        return false
    }

    var codePhoneNumber: String? {
        if case .codeSent(let phoneNumber) = self {
            return phoneNumber
        }
        return nil
    }

    var codeEmail: String? {
        if case .emailCodeSent(let email) = self {
            return email
        }
        return nil
    }

    var hasPendingCode: Bool {
        codePhoneNumber != nil || codeEmail != nil
    }

    var iconName: String {
        switch self {
        case .localPreview:
            return "iphone"
        case .loading:
            return "arrow.triangle.2.circlepath"
        case .codeSent, .emailCodeSent:
            return "message.badge"
        case .needsBootstrap:
            return "icloud.and.arrow.up"
        case .synced:
            return "checkmark.icloud.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum FamilySyncError: LocalizedError {
    case missingChildProfile
    case missingCurrentWeek

    var errorDescription: String? {
        switch self {
        case .missingChildProfile:
            return "This family does not have a child profile yet."
        case .missingCurrentWeek:
            return "This child does not have a current allowance week yet."
        }
    }
}
