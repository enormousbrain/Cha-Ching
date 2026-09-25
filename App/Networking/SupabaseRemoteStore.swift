import Foundation
import CryptoKit
import Supabase

struct SupabaseRemoteStore: Sendable {
    var client: SupabaseClient = SupabaseClientProvider.shared

    func fetchChorePlans(occurrenceIds: [UUID]) async throws -> [ChildChorePlan] {
        var result: [ChildChorePlan] = []
        for start in stride(from: 0, to: occurrenceIds.count, by: 100) {
            let ids = occurrenceIds[start..<min(start + 100, occurrenceIds.count)].map(\.uuidString)
            let batch: [ChildChorePlan] = try await client.from("child_chore_plans").select()
                .in("occurrence_id", values: ids).execute().value
            result.append(contentsOf: batch)
        }
        return result
    }

    func saveChorePlan(occurrenceId: UUID, plannedFor: Date?) async throws {
        struct Parameters: Encodable { let target_occurrence_id: UUID; let target_planned_for: Date? }
        try await client.rpc("set_child_chore_plan", params: Parameters(target_occurrence_id: occurrenceId, target_planned_for: plannedFor)).execute()
    }

    func fetchInitiativeStars(childId: UUID) async throws -> [InitiativeStar] {
        try await client.from("initiative_stars").select().eq("child_id", value: childId.uuidString)
            .order("created_at", ascending: false).limit(100).execute().value
    }

    func fetchStarBalance(childId: UUID) async throws -> Int {
        try await client.rpc("initiative_star_balance", params: ["target_child_id": childId.uuidString]).execute().value
    }

    func fetchStarCreditRequests(childId: UUID) async throws -> [StarCreditRequest] {
        try await client.from("star_credit_requests").select().eq("child_id", value: childId.uuidString)
            .order("created_at", ascending: false).execute().value
    }

    func awardInitiativeStar(id: UUID, childId: UUID, reason: String, occurrenceId: UUID?) async throws {
        struct Parameters: Encodable {
            let target_id: UUID; let target_child_id: UUID; let target_reason: String; let target_occurrence_id: UUID?
        }
        try await client.rpc("award_initiative_star", params: Parameters(target_id: id, target_child_id: childId,
            target_reason: reason, target_occurrence_id: occurrenceId)).execute()
    }

    func requestStarCredit(id: UUID, occurrenceId: UUID) async throws {
        try await client.rpc("request_star_credit", params: ["target_id": id.uuidString, "target_occurrence_id": occurrenceId.uuidString]).execute()
    }

    func decideStarCredit(id: UUID, approve: Bool) async throws {
        struct Parameters: Encodable { let target_id: UUID; let approve: Bool }
        try await client.rpc("decide_star_credit", params: Parameters(target_id: id, approve: approve)).execute()
    }

    func saveSavingsGoals(childId: UUID, goals: [SavingsGoal]) async throws {
        struct Parameters: Encodable {
            var target_child_id: UUID
            var goals: [SavingsGoal]
        }
        try await client.rpc("set_child_savings_goals", params: Parameters(target_child_id: childId, goals: goals)).execute()
    }

    func currentSession() async throws -> Session {
        let session = try await client.auth.session
        client.functions.setAuth(token: session.accessToken)
        return session
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    func photoSharingStatus(familyId: UUID) async throws -> PhotoSharingStatus {
        try await client.rpc("photo_sharing_status", params: ["target_family_id": familyId.uuidString]).execute().value
    }

    func setPhotoSharingConsent(familyId: UUID, accepted: Bool) async throws {
        struct Parameters: Encodable { let target_family_id: UUID; let accepted: Bool }
        try await client.rpc("set_photo_sharing_consent", params: Parameters(target_family_id: familyId, accepted: accepted)).execute()
    }

    func deleteAccount(appleAuthorizationCode: String?) async throws -> Bool {
        _ = try await currentSession()
        struct Response: Decodable { let accepted: Bool; let appleRevoked: Bool }
        var body = ["confirmation": "DELETE"]
        body["appleAuthorizationCode"] = appleAuthorizationCode
        let response: Response = try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(body: body))
        guard response.accepted else { throw URLError(.badServerResponse) }
        try? await client.auth.signOut(scope: .local)
        return response.appleRevoked
    }

    func fetchMembershipsForCurrentUser(userId: UUID) async throws -> [FamilyMemberRecord] {
        try await client
            .from("family_members")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchFamilies() async throws -> [FamilyRecord] {
        try await client
            .from("families")
            .select()
            .execute()
            .value
    }

    func fetchFamily(id: UUID) async throws -> FamilyRecord {
        try await client
            .from("families")
            .select()
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    func fetchFamilyMembers(familyId: UUID) async throws -> [FamilyMemberRecord] {
        try await client
            .from("family_members")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .execute()
            .value
    }

    func fetchChildProfiles(familyId: UUID) async throws -> [ChildProfileRecord] {
        try await client
            .from("child_profiles")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .order("created_at")
            .execute()
            .value
    }

    func fetchChildInvites(familyId: UUID) async throws -> [ChildInviteRecord] {
        try await client
            .from("child_invites")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchParentInvites(familyId: UUID) async throws -> [ParentInviteRecord] {
        try await client
            .from("parent_invites")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchFamilyEvidencePolicy(familyId: UUID) async throws -> FamilyEvidencePolicyRecord? {
        let records: [FamilyEvidencePolicyRecord] = try await client
            .from("family_evidence_policies")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .limit(1)
            .execute()
            .value

        return records.first
    }

    func fetchWeeks(familyId: UUID, childId: UUID) async throws -> [WeekRecord] {
        try await client
            .from("weeks")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .eq("child_id", value: childId.uuidString)
            .order("starts_at", ascending: false)
            .execute()
            .value
    }

    func fetchAllowanceSettlements(weekIds: [UUID]) async throws -> [AllowanceSettlementRecord] {
        guard !weekIds.isEmpty else { return [] }
        return try await client.from("allowance_settlements").select()
            .in("week_id", values: weekIds.map(\.uuidString)).execute().value
    }

    func confirmAllowancePeriod(weekId: UUID, amountCents: Int) async throws -> AllowanceSettlementRecord {
        let rows: [AllowanceSettlementRecord] = try await client.rpc(
            "confirm_allowance_period",
            params: ConfirmAllowanceParams(targetWeekId: weekId, expectedAmountCents: amountCents)
        ).execute().value
        guard let row = rows.first else { throw SupabaseRemoteStoreError.emptySettlementResponse }
        return row
    }

    func markAllowancePaid(weekId: UUID) async throws -> AllowanceSettlementRecord {
        let rows: [AllowanceSettlementRecord] = try await client.rpc(
            "mark_allowance_paid", params: MarkAllowancePaidParams(targetWeekId: weekId)
        ).execute().value
        guard let row = rows.first else { throw SupabaseRemoteStoreError.emptySettlementResponse }
        return row
    }

    func fetchChores(familyId: UUID) async throws -> [ChoreDefinitionRecord] {
        try await client
            .from("chore_definitions")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .order("title")
            .execute()
            .value
    }

    func fetchOccurrences(weekId: UUID) async throws -> [TaskOccurrenceRecord] {
        try await client
            .from("task_occurrences")
            .select()
            .eq("week_id", value: weekId.uuidString)
            .order("due_at")
            .execute()
            .value
    }

    func fetchOccurrences(weekIds: [UUID]) async throws -> [TaskOccurrenceRecord] {
        guard !weekIds.isEmpty else { return [] }
        return try await client.from("task_occurrences").select()
            .in("week_id", values: weekIds.map(\.uuidString)).order("due_at").execute().value
    }

    func fetchChoreSubmissions(childId: UUID) async throws -> [ChoreSubmissionRecord] {
        try await client
            .from("chore_submissions")
            .select()
            .eq("child_id", value: childId.uuidString)
            .order("submitted_at", ascending: false)
            .execute()
            .value
    }

    func fetchLedger(childId: UUID) async throws -> [LedgerEntryRecord] {
        try await client
            .from("ledger_entries")
            .select()
            .eq("child_id", value: childId.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchPendingTaskNudges(familyId: UUID, childId: UUID) async throws -> [TaskNudgeRecord] {
        try await client
            .from("task_nudges")
            .select()
            .eq("family_id", value: familyId.uuidString)
            .eq("child_id", value: childId.uuidString)
            .eq("status", value: "pending")
            .order("created_at")
            .execute()
            .value
    }

    func upsertAPNsDeviceToken(familyId: UUID, token: String, environment: String) async throws {
        struct Payload: Encodable {
            let userId: UUID
            let familyId: UUID
            let token: String
            let environment: String
            let lastSeenAt: String
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case familyId = "family_id"
                case token, environment
                case lastSeenAt = "last_seen_at"
            }
        }
        let session = try await currentSession()
        let payload = Payload(userId: session.user.id, familyId: familyId, token: token,
                              environment: environment, lastSeenAt: iso8601String(from: Date()))
        try await client.from("apns_device_tokens").upsert(payload, onConflict: "user_id,token").execute()
    }

    func bootstrapPreviewFamily(
        parentName: String,
        childName: String,
        familyName: String?
    ) async throws -> BootstrapFamilyResponse {
        let responses: [BootstrapFamilyResponse] = try await client
            .rpc(
                "bootstrap_preview_family",
                params: BootstrapFamilyParams(
                    parentDisplayName: parentName,
                    childDisplayName: childName,
                    familyDisplayName: familyName
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyBootstrapResponse
        }

        return response
    }

    func ensureCurrentTaskOccurrences(
        familyId: UUID,
        childProfileId: UUID
    ) async throws -> EnsureTaskOccurrencesResponse {
        let responses: [EnsureTaskOccurrencesResponse] = try await client
            .rpc(
                "ensure_current_task_occurrences",
                params: EnsureTaskOccurrencesParams(
                    familyId: familyId,
                    childProfileId: childProfileId
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyTaskOccurrenceResponse
        }

        return response
    }

    func processTaskOccurrenceDeadlines(
        familyId: UUID,
        childProfileId: UUID
    ) async throws -> ProcessTaskDeadlinesResponse {
        let responses: [ProcessTaskDeadlinesResponse] = try await client
            .rpc(
                "process_task_occurrence_deadlines",
                params: EnsureTaskOccurrencesParams(
                    familyId: familyId,
                    childProfileId: childProfileId
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyTaskDeadlinesResponse
        }

        return response
    }

    func setChoreLifecycle(
        id: UUID,
        isPaused: Bool,
        archive: Bool
    ) async throws -> ChoreLifecycleResponse {
        let responses: [ChoreLifecycleResponse] = try await client
            .rpc(
                "set_chore_lifecycle",
                params: ChoreLifecycleParams(
                    choreId: id,
                    isPaused: isPaused,
                    archive: archive
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyChoreLifecycleResponse
        }

        return response
    }

    func upsertChildProfile(
        id: UUID,
        familyId: UUID,
        displayName: String,
        phoneNumber: String?,
        createdByParentId: UUID?
    ) async throws -> ChildProfileRecord {
        let payload = ChildProfileUpsert(
            id: id,
            familyId: familyId,
            displayName: displayName,
            phoneE164: normalizedPhoneNumber(phoneNumber),
            createdByParentId: createdByParentId
        )

        return try await client
            .from("child_profiles")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func createChildInvite(
        id: UUID,
        familyId: UUID,
        childProfileId: UUID,
        childName: String,
        phoneNumber: String?,
        createdByParentId: UUID?,
        token: String,
        expiresAt: Date
    ) async throws -> ChildInviteRecord {
        let payload = ChildInviteInsert(
            id: id,
            familyId: familyId,
            childProfileId: childProfileId,
            childName: childName,
            phoneE164: normalizedPhoneNumber(phoneNumber),
            createdByParentId: createdByParentId,
            tokenHash: sha256Hex(token),
            expiresAt: iso8601String(from: expiresAt)
        )

        return try await client
            .from("child_invites")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func createParentInvite(
        id: UUID,
        familyId: UUID,
        parentName: String,
        phoneNumber: String?,
        createdByParentId: UUID?,
        token: String,
        expiresAt: Date
    ) async throws -> ParentInviteRecord {
        let payload = ParentInviteInsert(
            id: id,
            familyId: familyId,
            parentName: parentName,
            phoneE164: normalizedPhoneNumber(phoneNumber),
            createdByParentId: createdByParentId,
            tokenHash: sha256Hex(token),
            expiresAt: iso8601String(from: expiresAt)
        )

        return try await client
            .from("parent_invites")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func revokeChildInvite(id: UUID) async throws -> ChildInviteRecord {
        try await client
            .from("child_invites")
            .update(InviteStatusUpdate(status: ChildInviteStatus.revoked.rawValue))
            .eq("id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    func revokeParentInvite(id: UUID) async throws -> ParentInviteRecord {
        try await client
            .from("parent_invites")
            .update(InviteStatusUpdate(status: ParentInviteStatus.revoked.rawValue))
            .eq("id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    func updateFamilyAllowanceSettings(
        familyId: UUID,
        settings: AllowanceSettings
    ) async throws -> FamilyRecord {
        let payload = FamilyAllowanceSettingsUpdate(
            weeklyBaseAllowanceCents: settings.baseAllowanceCents,
            allowanceCadence: settings.cadence.rawValue,
            allowanceWeekday: settings.allowanceWeekday.rawValue,
            nextAllowanceAt: iso8601String(from: settings.nextAllowanceDate)
        )

        return try await client
            .from("families")
            .update(payload)
            .eq("id", value: familyId.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    func upsertFamilyEvidencePolicy(_ policy: FamilyEvidencePolicy) async throws -> FamilyEvidencePolicyRecord {
        let payload = FamilyEvidencePolicyUpsert(
            familyId: policy.familyId,
            photoEvidenceEnabled: policy.photoEvidenceEnabled,
            defaultVerificationMode: policy.defaultVerificationMode.rawValue,
            blockPeopleInPhotos: policy.blockPeopleInPhotos,
            evidenceRetentionMode: policy.evidenceRetentionMode.rawValue,
            deleteGraceMinutes: policy.deleteGraceMinutes,
            deleteAfterPeriodCloseDays: policy.deleteAfterPeriodCloseDays
        )

        return try await client
            .from("family_evidence_policies")
            .upsert(payload, onConflict: "family_id")
            .select()
            .single()
            .execute()
            .value
    }

    func createChore(_ chore: ChoreDefinition) async throws -> ChoreDefinitionRecord {
        let payload = ChoreDefinitionInsert(
            id: chore.id,
            familyId: chore.familyId,
            childId: chore.childId,
            title: chore.title,
            shortTitle: chore.shortTitle,
            description: chore.description,
            instructions: chore.instructions,
            expectedEvidence: chore.expectedEvidence,
            deductionCents: chore.deductionCents,
            verificationMode: chore.verificationMode.rawValue,
            blockPeopleInPhotos: chore.blockPeopleInPhotos,
            recurrence: recurrencePayload(for: chore),
            dueWindowMinutes: chore.dueWindowMinutes,
            reminderOffsetsMinutes: chore.reminderOffsetsMinutes,
            parentAlertEnabled: chore.parentAlertEnabled,
            parentAlertDelayMinutes: chore.parentAlertDelayMinutes,
            locationName: chore.location?.name,
            locationLatitude: chore.location?.latitude,
            locationLongitude: chore.location?.longitude,
            locationRadiusMeters: chore.location?.radiusMeters,
            locationLeaveReminderMinutes: chore.location?.leaveReminderMinutes,
            isPaused: chore.isPaused
        )

        return try await client
            .from("chore_definitions")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func updateChore(
        id: UUID,
        title: String,
        shortTitle: String,
        description: String,
        instructions: String,
        expectedEvidence: String,
        deductionCents: Int,
        dueTime: String,
        recurrence: ChoreRecurrence,
        verificationMode: VerificationMode,
        blockPeopleInPhotos: Bool?,
        parentAlertEnabled: Bool,
        parentAlertDelayMinutes: Int,
        location: ChoreLocation?
    ) async throws -> ChoreDefinitionRecord {
        let payload = ChoreDefinitionUpdate(
            title: title,
            shortTitle: shortTitle,
            description: description,
            instructions: instructions,
            expectedEvidence: expectedEvidence,
            deductionCents: deductionCents,
            verificationMode: verificationMode.rawValue,
            blockPeopleInPhotos: blockPeopleInPhotos,
            recurrence: recurrencePayload(for: recurrence, dueTime: dueTime),
            parentAlertEnabled: parentAlertEnabled,
            parentAlertDelayMinutes: parentAlertDelayMinutes,
            locationName: location?.name,
            locationLatitude: location?.latitude,
            locationLongitude: location?.longitude,
            locationRadiusMeters: location?.radiusMeters,
            locationLeaveReminderMinutes: location?.leaveReminderMinutes
        )

        return try await client
            .from("chore_definitions")
            .update(payload)
            .eq("id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    private func recurrencePayload(for chore: ChoreDefinition) -> RecurrencePayload {
        recurrencePayload(for: chore.recurrence, dueTime: chore.dueTime)
    }

    private func recurrencePayload(
        for recurrence: ChoreRecurrence,
        dueTime: String
    ) -> RecurrencePayload {
        RecurrencePayload(
            type: recurrence.frequency.rawValue,
            times: [dueTime],
            weekdays: recurrence.frequency == .weekly ? recurrence.weekdays.map(\.rawValue) : nil,
            rule: nil,
            dueAt: recurrence.frequency == .once ? recurrence.oneTimeDate : nil
        )
    }

    func createTaskOccurrence(_ occurrence: TaskOccurrence) async throws -> TaskOccurrenceRecord {
        let payload = TaskOccurrenceInsert(
            id: occurrence.id,
            choreDefinitionId: occurrence.choreDefinitionId,
            childId: occurrence.childId,
            weekId: occurrence.weekId,
            scheduledAt: iso8601String(from: occurrence.scheduledAt),
            dueAt: iso8601String(from: occurrence.dueAt),
            expiresAt: iso8601String(from: occurrence.expiresAt),
            status: occurrence.status.rawValue
        )

        return try await client
            .from("task_occurrences")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func updateOccurrenceTiming(
        id: UUID,
        scheduledAt: Date,
        dueAt: Date,
        expiresAt: Date
    ) async throws -> TaskOccurrenceRecord {
        let payload = TaskOccurrenceTimingUpdate(
            scheduledAt: iso8601String(from: scheduledAt),
            dueAt: iso8601String(from: dueAt),
            expiresAt: iso8601String(from: expiresAt)
        )

        return try await client
            .from("task_occurrences")
            .update(payload)
            .eq("id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    func createBonusLedgerEntry(
        id: UUID,
        weekId: UUID,
        childId: UUID,
        createdBy: UUID?,
        title: String,
        amountCents: Int,
        note: String?,
        createdAt: Date
    ) async throws -> LedgerEntryRecord {
        let payload = LedgerEntryInsert(
            id: id,
            weekId: weekId,
            childId: childId,
            createdBy: createdBy,
            entryType: LedgerEntryType.bonus.rawValue,
            title: title,
            amountCents: amountCents,
            relatedOccurrenceId: nil,
            note: note,
            isVoided: false,
            createdAt: iso8601String(from: createdAt)
        )

        return try await client
            .from("ledger_entries")
            .upsert(payload, onConflict: "id")
            .select()
            .single()
            .execute()
            .value
    }

    func createTaskNudge(
        id: UUID = UUID(),
        familyId: UUID,
        occurrenceId: UUID,
        childId: UUID,
        createdBy: UUID,
        message: String,
        createdAt: Date = Date()
    ) async throws -> TaskNudgeRecord {
        let payload = TaskNudgeInsert(
            id: id,
            familyId: familyId,
            taskOccurrenceId: occurrenceId,
            childId: childId,
            createdBy: createdBy,
            message: message,
            createdAt: iso8601String(from: createdAt)
        )

        return try await client
            .from("task_nudges")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
    }

    func markTaskNudgeDelivered(id: UUID, deliveredAt: Date = Date()) async throws -> TaskNudgeRecord {
        let payload = TaskNudgeDeliveryUpdate(
            status: "delivered",
            deliveredAt: iso8601String(from: deliveredAt)
        )

        return try await client
            .from("task_nudges")
            .update(payload)
            .eq("id", value: id.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    func uploadEvidenceJPEG(
        familyId: UUID,
        occurrenceId: UUID,
        submissionId: UUID,
        jpegData: Data
    ) async throws -> String {
        let path = [familyId, occurrenceId, submissionId]
            .map { $0.uuidString.lowercased() }
            .joined(separator: "/") + ".jpg"
        let response = try await client.storage
            .from(SupabaseConfig.evidenceBucketName)
            .upload(
                path,
                data: jpegData,
                options: FileOptions(
                    cacheControl: "3600",
                    contentType: "image/jpeg",
                    upsert: false
                )
            )

        return response.path
    }

    func downloadEvidence(path: String) async throws -> Data {
        try await client.storage
            .from(SupabaseConfig.evidenceBucketName)
            .download(path: path)
    }

    func registerPhotoSubmission(
        id: UUID,
        occurrenceId: UUID,
        imagePath: String
    ) async throws -> PhotoSubmissionResponse {
        let responses: [PhotoSubmissionResponse] = try await client
            .rpc(
                "register_chore_photo_submission",
                params: PhotoSubmissionParams(
                    targetSubmissionId: id,
                    targetOccurrenceId: occurrenceId,
                    targetImagePath: imagePath
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyPhotoSubmissionResponse
        }

        return response
    }

    func submitChoreWithoutPhoto(occurrenceId: UUID) async throws -> NoPhotoSubmissionResponse {
        let responses: [NoPhotoSubmissionResponse] = try await client
            .rpc(
                "submit_chore_without_photo",
                params: NoPhotoSubmissionParams(targetOccurrenceId: occurrenceId)
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyNoPhotoSubmissionResponse
        }

        return response
    }

    func reportChoresDone(ids: [UUID], note: String) async throws {
        struct Params: Encodable { let target_occurrence_ids: [UUID]; let target_note: String }
        _ = try await client.rpc("report_chores_done", params: Params(target_occurrence_ids: ids, target_note: note)).execute()
    }

    func reviewChoreBatch(ids: [UUID], decision: ParentDecision.Decision) async throws {
        struct Params: Encodable { let target_occurrence_ids: [UUID]; let target_decision: String }
        _ = try await client.rpc("review_chore_batch", params: Params(target_occurrence_ids: ids, target_decision: decision.rawValue)).execute()
    }

    func fetchPendingOccurrences(childIds: [UUID]) async throws -> [TaskOccurrenceRecord] {
        guard !childIds.isEmpty else { return [] }
        var result: [TaskOccurrenceRecord] = []
        while true {
            let page: [TaskOccurrenceRecord] = try await client.from("task_occurrences").select()
                .in("child_id", values: childIds.map(\.uuidString))
                .in("status", values: ["submitted", "ai_reviewed"])
                .order("due_at").order("id").range(from: result.count, to: result.count + 499).execute().value
            result.append(contentsOf: page)
            if page.count < 500 { return result }
        }
    }

    func fetchSubmissions(ids: [UUID]) async throws -> [ChoreSubmissionRecord] {
        guard !ids.isEmpty else { return [] }
        var result: [ChoreSubmissionRecord] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let page: [ChoreSubmissionRecord] = try await client.from("chore_submissions").select()
                .in("id", values: ids[start..<min(start + 100, ids.count)].map(\.uuidString)).execute().value
            result.append(contentsOf: page)
        }
        return result
    }

    func reviewEvidence(submissionId: UUID) async throws -> ReviewEvidenceResponse {
        try await client.functions.invoke(
            "review-evidence",
            options: FunctionInvokeOptions(
                method: .post,
                body: ReviewEvidenceRequest(submissionId: submissionId)
            )
        )
    }

    func decideSubmission(
        occurrenceId: UUID,
        decision: ParentDecision.Decision,
        note: String?
    ) async throws -> ParentReviewDecisionResponse {
        let responses: [ParentReviewDecisionResponse] = try await client
            .rpc(
                "decide_chore_submission",
                params: ParentReviewDecisionParams(
                    targetOccurrenceId: occurrenceId,
                    targetDecision: decision.rawValue,
                    targetNote: note
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyParentReviewDecisionResponse
        }

        return response
    }

    func requestChoreExcuse(
        occurrenceId: UUID,
        reason: String
    ) async throws -> ChoreExcuseRequestResponse {
        let responses: [ChoreExcuseRequestResponse] = try await client
            .rpc(
                "request_chore_excuse",
                params: ChoreExcuseRequestParams(
                    targetOccurrenceId: occurrenceId,
                    targetReason: reason
                )
            )
            .execute()
            .value

        guard let response = responses.first else {
            throw SupabaseRemoteStoreError.emptyChoreExcuseRequestResponse
        }

        return response
    }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func normalizedPhoneNumber(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }

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

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum SupabaseRemoteStoreError: LocalizedError {
    case emptyBootstrapResponse
    case emptyTaskOccurrenceResponse
    case emptyTaskDeadlinesResponse
    case emptyChoreLifecycleResponse
    case emptyParentReviewDecisionResponse
    case emptyChoreExcuseRequestResponse
    case emptyNoPhotoSubmissionResponse
    case emptyPhotoSubmissionResponse
    case emptySettlementResponse

    var errorDescription: String? {
        switch self {
        case .emptyBootstrapResponse:
            return "Supabase did not return a family after bootstrapping."
        case .emptyTaskOccurrenceResponse:
            return "Supabase did not return a task schedule after refreshing."
        case .emptyTaskDeadlinesResponse:
            return "Supabase did not return task deadline updates after refreshing."
        case .emptyChoreLifecycleResponse:
            return "Supabase did not return the updated chore status."
        case .emptyParentReviewDecisionResponse:
            return "Supabase did not return the reviewed task."
        case .emptyChoreExcuseRequestResponse:
            return "Supabase did not return the parent review request."
        case .emptyNoPhotoSubmissionResponse:
            return "Supabase did not return the submitted task."
        case .emptyPhotoSubmissionResponse:
            return "Supabase did not register the photo submission."
        case .emptySettlementResponse:
            return "Supabase did not return the allowance settlement."
        }
    }
}

private struct BootstrapFamilyParams: Encodable {
    let parentDisplayName: String
    let childDisplayName: String
    let familyDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case parentDisplayName = "parent_display_name"
        case childDisplayName = "child_display_name"
        case familyDisplayName = "family_display_name"
    }
}

private struct EnsureTaskOccurrencesParams: Encodable {
    let familyId: UUID
    let childProfileId: UUID

    enum CodingKeys: String, CodingKey {
        case familyId = "target_family_id"
        case childProfileId = "target_child_profile_id"
    }
}

private struct ChildProfileUpsert: Encodable {
    let id: UUID
    let familyId: UUID
    let displayName: String
    let phoneE164: String?
    let createdByParentId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case displayName = "display_name"
        case phoneE164 = "phone_e164"
        case createdByParentId = "created_by_parent_id"
    }
}

private struct ChildInviteInsert: Encodable {
    let id: UUID
    let familyId: UUID
    let childProfileId: UUID
    let childName: String
    let phoneE164: String?
    let createdByParentId: UUID?
    let tokenHash: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case childProfileId = "child_profile_id"
        case childName = "child_name"
        case phoneE164 = "phone_e164"
        case createdByParentId = "created_by_parent_id"
        case tokenHash = "token_hash"
        case expiresAt = "expires_at"
    }
}

private struct ParentInviteInsert: Encodable {
    let id: UUID
    let familyId: UUID
    let parentName: String
    let phoneE164: String?
    let createdByParentId: UUID?
    let tokenHash: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case parentName = "parent_name"
        case phoneE164 = "phone_e164"
        case createdByParentId = "created_by_parent_id"
        case tokenHash = "token_hash"
        case expiresAt = "expires_at"
    }
}

private struct InviteStatusUpdate: Encodable {
    let status: String
}

private struct FamilyAllowanceSettingsUpdate: Encodable {
    let weeklyBaseAllowanceCents: Int
    let allowanceCadence: String
    let allowanceWeekday: Int
    let nextAllowanceAt: String

    enum CodingKeys: String, CodingKey {
        case weeklyBaseAllowanceCents = "weekly_base_allowance_cents"
        case allowanceCadence = "allowance_cadence"
        case allowanceWeekday = "allowance_weekday"
        case nextAllowanceAt = "next_allowance_at"
    }
}

private struct FamilyEvidencePolicyUpsert: Encodable {
    let familyId: UUID
    let photoEvidenceEnabled: Bool
    let defaultVerificationMode: String
    let blockPeopleInPhotos: Bool
    let evidenceRetentionMode: String
    let deleteGraceMinutes: Int
    let deleteAfterPeriodCloseDays: Int

    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case photoEvidenceEnabled = "photo_evidence_enabled"
        case defaultVerificationMode = "default_verification_mode"
        case blockPeopleInPhotos = "block_people_in_photos"
        case evidenceRetentionMode = "evidence_retention_mode"
        case deleteGraceMinutes = "delete_grace_minutes"
        case deleteAfterPeriodCloseDays = "delete_after_period_close_days"
    }
}

private struct ChoreDefinitionUpdate: Encodable {
    let title: String
    let shortTitle: String
    let description: String
    let instructions: String
    let expectedEvidence: String
    let deductionCents: Int
    let verificationMode: String
    let blockPeopleInPhotos: Bool?
    let recurrence: RecurrencePayload
    let parentAlertEnabled: Bool
    let parentAlertDelayMinutes: Int
    let locationName: String?
    let locationLatitude: Double?
    let locationLongitude: Double?
    let locationRadiusMeters: Double?
    let locationLeaveReminderMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case shortTitle = "short_title"
        case description
        case instructions
        case expectedEvidence = "expected_evidence"
        case deductionCents = "deduction_cents"
        case verificationMode = "verification_mode"
        case blockPeopleInPhotos = "block_people_in_photos"
        case recurrence
        case parentAlertEnabled = "parent_alert_enabled"
        case parentAlertDelayMinutes = "parent_alert_delay_minutes"
        case locationName = "location_name"
        case locationLatitude = "location_latitude"
        case locationLongitude = "location_longitude"
        case locationRadiusMeters = "location_radius_meters"
        case locationLeaveReminderMinutes = "location_leave_reminder_minutes"
    }
}

private struct ChoreDefinitionInsert: Encodable {
    let id: UUID
    let familyId: UUID
    let childId: UUID
    let title: String
    let shortTitle: String
    let description: String
    let instructions: String
    let expectedEvidence: String
    let deductionCents: Int
    let verificationMode: String
    let blockPeopleInPhotos: Bool?
    let recurrence: RecurrencePayload
    let dueWindowMinutes: Int
    let reminderOffsetsMinutes: [Int]
    let parentAlertEnabled: Bool
    let parentAlertDelayMinutes: Int
    let locationName: String?
    let locationLatitude: Double?
    let locationLongitude: Double?
    let locationRadiusMeters: Double?
    let locationLeaveReminderMinutes: Int?
    let isPaused: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case childId = "child_id"
        case title
        case shortTitle = "short_title"
        case description
        case instructions
        case expectedEvidence = "expected_evidence"
        case deductionCents = "deduction_cents"
        case verificationMode = "verification_mode"
        case blockPeopleInPhotos = "block_people_in_photos"
        case recurrence
        case dueWindowMinutes = "due_window_minutes"
        case reminderOffsetsMinutes = "reminder_offsets_minutes"
        case isPaused = "is_paused"
        case parentAlertEnabled = "parent_alert_enabled"
        case parentAlertDelayMinutes = "parent_alert_delay_minutes"
        case locationName = "location_name"
        case locationLatitude = "location_latitude"
        case locationLongitude = "location_longitude"
        case locationRadiusMeters = "location_radius_meters"
        case locationLeaveReminderMinutes = "location_leave_reminder_minutes"
    }
}

private struct TaskOccurrenceInsert: Encodable {
    let id: UUID
    let choreDefinitionId: UUID
    let childId: UUID
    let weekId: UUID
    let scheduledAt: String
    let dueAt: String
    let expiresAt: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case choreDefinitionId = "chore_definition_id"
        case childId = "child_id"
        case weekId = "week_id"
        case scheduledAt = "scheduled_at"
        case dueAt = "due_at"
        case expiresAt = "expires_at"
        case status
    }
}

private struct TaskOccurrenceTimingUpdate: Encodable {
    let scheduledAt: String
    let dueAt: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case scheduledAt = "scheduled_at"
        case dueAt = "due_at"
        case expiresAt = "expires_at"
    }
}

private struct LedgerEntryInsert: Encodable {
    let id: UUID
    let weekId: UUID
    let childId: UUID
    let createdBy: UUID?
    let entryType: String
    let title: String
    let amountCents: Int
    let relatedOccurrenceId: UUID?
    let note: String?
    let isVoided: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case weekId = "week_id"
        case childId = "child_id"
        case createdBy = "created_by"
        case entryType = "entry_type"
        case title
        case amountCents = "amount_cents"
        case relatedOccurrenceId = "related_occurrence_id"
        case note
        case isVoided = "is_voided"
        case createdAt = "created_at"
    }
}

private struct TaskNudgeInsert: Encodable {
    let id: UUID
    let familyId: UUID
    let taskOccurrenceId: UUID
    let childId: UUID
    let createdBy: UUID
    let message: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case taskOccurrenceId = "task_occurrence_id"
        case childId = "child_id"
        case createdBy = "created_by"
        case message
        case createdAt = "created_at"
    }
}

private struct TaskNudgeDeliveryUpdate: Encodable {
    let status: String
    let deliveredAt: String

    enum CodingKeys: String, CodingKey {
        case status
        case deliveredAt = "delivered_at"
    }
}

private struct PhotoSubmissionParams: Encodable {
    let targetSubmissionId: UUID
    let targetOccurrenceId: UUID
    let targetImagePath: String

    enum CodingKeys: String, CodingKey {
        case targetSubmissionId = "target_submission_id"
        case targetOccurrenceId = "target_occurrence_id"
        case targetImagePath = "target_image_path"
    }
}

private struct NoPhotoSubmissionParams: Encodable {
    let targetOccurrenceId: UUID

    enum CodingKeys: String, CodingKey {
        case targetOccurrenceId = "target_occurrence_id"
    }
}

private struct ReviewEvidenceRequest: Encodable {
    let submissionId: UUID

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
    }
}

private struct ParentReviewDecisionParams: Encodable {
    let targetOccurrenceId: UUID
    let targetDecision: String
    let targetNote: String?

    enum CodingKeys: String, CodingKey {
        case targetOccurrenceId = "target_occurrence_id"
        case targetDecision = "target_decision"
        case targetNote = "target_note"
    }
}

private struct ChoreExcuseRequestParams: Encodable {
    let targetOccurrenceId: UUID
    let targetReason: String

    enum CodingKeys: String, CodingKey {
        case targetOccurrenceId = "target_occurrence_id"
        case targetReason = "target_reason"
    }
}

private struct ChoreLifecycleParams: Encodable {
    let choreId: UUID
    let isPaused: Bool
    let archive: Bool

    enum CodingKeys: String, CodingKey {
        case choreId = "target_chore_id"
        case isPaused = "target_is_paused"
        case archive = "target_archive"
    }
}
