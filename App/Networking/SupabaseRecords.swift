import Foundation

struct FamilyRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let weeklyBaseAllowanceCents: Int
    let allowanceCadence: String?
    let allowanceWeekday: Int?
    let nextAllowanceAt: Date?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case weeklyBaseAllowanceCents = "weekly_base_allowance_cents"
        case allowanceCadence = "allowance_cadence"
        case allowanceWeekday = "allowance_weekday"
        case nextAllowanceAt = "next_allowance_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct FamilyMemberRecord: Codable, Identifiable, Sendable {
    let familyId: UUID
    let userId: UUID
    let role: String
    let displayName: String
    let createdAt: Date

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case userId = "user_id"
        case role
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

struct WeekRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let familyId: UUID
    let childId: UUID
    let startsAt: Date
    let endsAt: Date
    let baseAllowanceCents: Int
    let archivedAt: Date?
    let finalBalanceCents: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case childId = "child_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case baseAllowanceCents = "base_allowance_cents"
        case archivedAt = "archived_at"
        case finalBalanceCents = "final_balance_cents"
        case createdAt = "created_at"
    }
}

struct AllowanceSettlementRecord: Codable, Identifiable, Sendable {
    let weekId: UUID
    let amountCents: Int
    let confirmedAt: Date
    let confirmedBy: UUID?
    let paidAt: Date?
    let paidBy: UUID?
    var id: UUID { weekId }
    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case amountCents = "amount_cents"
        case confirmedAt = "confirmed_at"
        case confirmedBy = "confirmed_by"
        case paidAt = "paid_at"
        case paidBy = "paid_by"
    }
}

struct ChildProfileRecord: Codable, Identifiable, Sendable {
    var savingsGoals: [SavingsGoal]? = nil
    let id: UUID
    let familyId: UUID
    let displayName: String
    let phoneE164: String?
    let linkedUserId: UUID?
    let createdByParentId: UUID?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case savingsGoals = "savings_goals"
        case id
        case familyId = "family_id"
        case displayName = "display_name"
        case phoneE164 = "phone_e164"
        case linkedUserId = "linked_user_id"
        case createdByParentId = "created_by_parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ChildInviteRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let familyId: UUID
    let childProfileId: UUID
    let childName: String
    let phoneE164: String?
    let createdByParentId: UUID?
    let status: String
    let expiresAt: Date
    let acceptedAt: Date?
    let acceptedChildUserId: UUID?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case childProfileId = "child_profile_id"
        case childName = "child_name"
        case phoneE164 = "phone_e164"
        case createdByParentId = "created_by_parent_id"
        case status
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case acceptedChildUserId = "accepted_child_user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ParentInviteRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let familyId: UUID
    let parentName: String
    let phoneE164: String?
    let createdByParentId: UUID?
    let status: String
    let expiresAt: Date
    let acceptedAt: Date?
    let acceptedParentUserId: UUID?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case parentName = "parent_name"
        case phoneE164 = "phone_e164"
        case createdByParentId = "created_by_parent_id"
        case status
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case acceptedParentUserId = "accepted_parent_user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct FamilyEvidencePolicyRecord: Codable, Identifiable, Sendable {
    let familyId: UUID
    let photoEvidenceEnabled: Bool
    let defaultVerificationMode: String
    let blockPeopleInPhotos: Bool
    let evidenceRetentionMode: String
    let deleteGraceMinutes: Int
    let deleteAfterPeriodCloseDays: Int
    let createdAt: Date
    let updatedAt: Date

    var id: UUID { familyId }

    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case photoEvidenceEnabled = "photo_evidence_enabled"
        case defaultVerificationMode = "default_verification_mode"
        case blockPeopleInPhotos = "block_people_in_photos"
        case evidenceRetentionMode = "evidence_retention_mode"
        case deleteGraceMinutes = "delete_grace_minutes"
        case deleteAfterPeriodCloseDays = "delete_after_period_close_days"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ChoreDefinitionRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let familyId: UUID
    let childId: UUID
    let title: String
    let shortTitle: String
    let description: String?
    let instructions: String?
    let expectedEvidence: String?
    let deductionCents: Int
    let verificationMode: String
    let blockPeopleInPhotos: Bool?
    let evidenceRetentionMode: String?
    let evidenceDeleteGraceMinutes: Int?
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
    let archivedAt: Date?
    let createdAt: Date
    let updatedAt: Date

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
        case evidenceRetentionMode = "evidence_retention_mode"
        case evidenceDeleteGraceMinutes = "evidence_delete_grace_minutes"
        case recurrence
        case dueWindowMinutes = "due_window_minutes"
        case reminderOffsetsMinutes = "reminder_offsets_minutes"
        case parentAlertEnabled = "parent_alert_enabled"
        case parentAlertDelayMinutes = "parent_alert_delay_minutes"
        case locationName = "location_name"
        case locationLatitude = "location_latitude"
        case locationLongitude = "location_longitude"
        case locationRadiusMeters = "location_radius_meters"
        case locationLeaveReminderMinutes = "location_leave_reminder_minutes"
        case isPaused = "is_paused"
        case archivedAt = "archived_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct TaskOccurrenceRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let choreDefinitionId: UUID
    let childId: UUID
    let weekId: UUID
    let scheduledAt: Date
    let dueAt: Date
    let expiresAt: Date
    let status: String
    let submissionId: UUID?
    let deductionLedgerEntryId: UUID?
    let excuseReason: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case choreDefinitionId = "chore_definition_id"
        case childId = "child_id"
        case weekId = "week_id"
        case scheduledAt = "scheduled_at"
        case dueAt = "due_at"
        case expiresAt = "expires_at"
        case status
        case submissionId = "submission_id"
        case deductionLedgerEntryId = "deduction_ledger_entry_id"
        case excuseReason = "excuse_reason"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct LedgerEntryRecord: Codable, Identifiable, Sendable {
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
    let createdAt: Date

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

struct TaskNudgeRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let familyId: UUID
    let taskOccurrenceId: UUID
    let childId: UUID
    let createdBy: UUID
    let message: String
    let status: String
    let deliveredAt: Date?
    let dismissedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case familyId = "family_id"
        case taskOccurrenceId = "task_occurrence_id"
        case childId = "child_id"
        case createdBy = "created_by"
        case message
        case status
        case deliveredAt = "delivered_at"
        case dismissedAt = "dismissed_at"
        case createdAt = "created_at"
    }
}

struct ChoreSubmissionRecord: Codable, Identifiable, Sendable {
    let reportedDoneNote: String?
    let id: UUID
    let taskOccurrenceId: UUID
    let childId: UUID
    let imagePath: String?
    let thumbnailPath: String?
    let submittedAt: Date
    let aiResult: RemoteAIReviewResult?
    let parentDecision: RemoteParentDecision?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case reportedDoneNote = "reported_done_note"
        case id
        case taskOccurrenceId = "task_occurrence_id"
        case childId = "child_id"
        case imagePath = "image_path"
        case thumbnailPath = "thumbnail_path"
        case submittedAt = "submitted_at"
        case aiResult = "ai_result"
        case parentDecision = "parent_decision"
        case createdAt = "created_at"
    }
}

struct NoPhotoSubmissionResponse: Decodable, Sendable {
    let submissionId: UUID
    let taskOccurrenceId: UUID
    let status: String
    let submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case taskOccurrenceId = "task_occurrence_id"
        case status
        case submittedAt = "submitted_at"
    }
}

typealias PhotoSubmissionResponse = NoPhotoSubmissionResponse

struct ReviewEvidenceResponse: Decodable, Sendable {
    let submissionId: UUID
    let taskOccurrenceId: UUID
    let aiResult: RemoteAIReviewResult

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id"
        case taskOccurrenceId = "task_occurrence_id"
        case aiResult = "ai_result"
    }
}

struct RemoteAIReviewResult: Codable, Sendable {
    let completed: Bool?
    let confidence: Double
    let reason: String
    let retakeSuggested: Bool
    let retakeInstruction: String?
    let parentReviewPriority: String?
    let modelName: String?
    let reviewedAt: Date
}

struct RemoteParentDecision: Codable, Sendable {
    let decision: String
    let note: String?
    let decidedAt: Date?
    let parentId: UUID?

    enum CodingKeys: String, CodingKey {
        case decision
        case note
        case decidedAt = "decided_at"
        case parentId = "parent_id"
    }
}

struct RecurrencePayload: Codable, Sendable {
    let type: String
    let times: [String]?
    let weekdays: [Int]?
    let rule: String?
    let dueAt: Date?

    enum CodingKeys: String, CodingKey {
        case type
        case times
        case weekdays
        case rule
        case dueAt = "due_at"
    }
}

struct BootstrapFamilyResponse: Decodable, Sendable {
    let familyId: UUID
    let childProfileId: UUID
    let weekId: UUID

    enum CodingKeys: String, CodingKey {
        case familyId = "family_id"
        case childProfileId = "child_profile_id"
        case weekId = "week_id"
    }
}

struct EnsureTaskOccurrencesResponse: Decodable, Sendable {
    let activeWeekId: UUID
    let insertedCount: Int

    enum CodingKeys: String, CodingKey {
        case activeWeekId = "active_week_id"
        case insertedCount = "inserted_count"
    }
}

struct ProcessTaskDeadlinesResponse: Decodable, Sendable {
    let markedDueCount: Int
    let markedMissedCount: Int
    let deductionCount: Int

    enum CodingKeys: String, CodingKey {
        case markedDueCount = "marked_due_count"
        case markedMissedCount = "marked_missed_count"
        case deductionCount = "deduction_count"
    }
}

struct ChoreLifecycleResponse: Decodable, Sendable {
    let choreId: UUID
    let isPaused: Bool
    let archivedAt: Date?
    let excusedOccurrenceCount: Int

    enum CodingKeys: String, CodingKey {
        case choreId = "chore_id"
        case isPaused = "is_paused"
        case archivedAt = "archived_at"
        case excusedOccurrenceCount = "excused_occurrence_count"
    }
}

struct ParentReviewDecisionResponse: Decodable, Sendable {
    let occurrenceId: UUID
    let submissionId: UUID?
    let ledgerEntryId: UUID?
    let decision: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case occurrenceId = "occurrence_id"
        case submissionId = "submission_id"
        case ledgerEntryId = "ledger_entry_id"
        case decision
        case status
    }
}

struct ChoreExcuseRequestResponse: Decodable, Sendable {
    let occurrenceId: UUID
    let status: String
    let excuseReason: String

    enum CodingKeys: String, CodingKey {
        case occurrenceId = "occurrence_id"
        case status
        case excuseReason = "excuse_reason"
    }
}

struct ConfirmAllowanceParams: Encodable, Sendable {
    let targetWeekId: UUID
    let expectedAmountCents: Int
    enum CodingKeys: String, CodingKey { case targetWeekId = "target_week_id"; case expectedAmountCents = "expected_amount_cents" }
}

struct MarkAllowancePaidParams: Encodable, Sendable {
    let targetWeekId: UUID
    enum CodingKeys: String, CodingKey { case targetWeekId = "target_week_id" }
}
