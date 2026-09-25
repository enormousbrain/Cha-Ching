import AuthenticationServices
import CryptoKit
import Security
import SwiftUI
import UIKit

struct ParentWorkspaceView: View {
    @State private var selectedTab: ParentTab = .review

    var body: some View {
        VStack(spacing: 0) {
            Picker("Parent section", selection: $selectedTab) {
                ForEach(ParentTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            ParentChildPicker()
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

            ZStack {
                ParentReviewQueueView()
                    .visibleParentSection(selectedTab == .review)

                ChoreManagementView()
                    .visibleParentSection(selectedTab == .chores)

                FamilyManagementView()
                    .visibleParentSection(selectedTab == .family)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("Parent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) {
                DevelopmentSessionMenu()
            }
            #endif
        }
    }
}

private struct ParentChildPicker: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.isParentSession && store.childProfiles.count > 1 {
            HStack {
                Label("Child", systemImage: "person.2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Child", selection: Binding(
                    get: { store.childId },
                    set: { selectedId in
                        Task { await store.switchParentChild(to: selectedId) }
                    }
                )) {
                    ForEach(store.childProfiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(store.familySyncState.isWorking)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            }
        }
    }
}

private extension View {
    func visibleParentSection(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

enum ParentTab: String, CaseIterable, Identifiable {
    case review
    case chores
    case family

    var id: String { rawValue }
    var title: String {
        switch self {
        case .review:
            return "Review"
        case .chores:
            return "Chores"
        case .family:
            return "Family"
        }
    }
}

struct ParentReviewQueueView: View {
    @EnvironmentObject private var store: AppStore
    @State private var filter: ReviewFilter = .pending
    @State private var showingBonus = false
    @State private var showingPreviewReview = false
    @State private var showingPreviewInsights = false
    @State private var showingAllowanceOverview = false

    private var visibleOccurrences: [TaskOccurrence] {
        switch filter {
        case .today:
            return store.todayOccurrences.filter { $0.status.isOpen && !$0.status.needsParentReview }
        case .pending:
            return store.pendingReviewOccurrences.filter { $0.status != .rejected }.sorted { $0.updatedAt < $1.updatedAt }
        case .reviewed:
            return store.occurrences.filter { $0.status == .approved || $0.status == .excused || $0.status == .rejected }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DisclosureGroup(isExpanded: $showingAllowanceOverview) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.childName)
                            .font(.title2.weight(.heavy))
                        Text(store.allowancePeriodTitle)
                            .font(.subheadline)
                            .foregroundStyle(Color.mutedGray)
                    }
                    Spacer()
                    Button { showingBonus = true } label: {
                        Label("Bonus", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.bold))
                    }
                    .disabled(store.isMutationInFlight)
                }

                AllowanceTrajectoryView(compact: true)

                NavigationLink {
                    ParentChoreInsightsView()
                } label: {
                    Label("Chore Insights", systemImage: "chart.bar.xaxis")
                        .font(.subheadline.weight(.semibold))
                }
                } label: {
                    Text("\(store.childName.isEmpty ? "Family" : store.childName)'s allowance")
                        .font(.headline)
                }

                Divider()

                Picker("Review filter", selection: $filter) {
                    ForEach(ReviewFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if filter == .pending {
                    FamilyPendingApprovalsView()
                } else if visibleOccurrences.isEmpty {
                    ContentUnavailableView(
                        filter == .pending ? "All caught up" : (filter == .today ? "Nothing left today" : "No completed chores yet"),
                        systemImage: filter == .pending ? "checkmark.circle" : "calendar",
                        description: Text(filter == .pending ? "New submissions will appear here." : "")
                    )
                    .frame(minHeight: 140)
                } else {
                    HStack {
                        Text(filter == .pending ? "Waiting for you" : filter.title)
                            .font(.headline)
                        Spacer()
                        Text("\(visibleOccurrences.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.mutedGray)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(visibleOccurrences) { occurrence in
                            if let chore = store.chore(id: occurrence.choreDefinitionId) {
                                NavigationLink {
                                    ParentTaskReviewView(occurrenceId: occurrence.id)
                                } label: {
                                    ReviewQueueRow(occurrence: occurrence, chore: chore)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .refreshable {
            await store.refreshRemoteFamilyState()
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .sheet(isPresented: $showingBonus) { AddBonusSheet().environmentObject(store) }
        .navigationDestination(isPresented: $showingPreviewReview) {
            if let occurrence = store.pendingReviewOccurrences.first {
                ParentTaskReviewView(occurrenceId: occurrence.id)
            }
        }
        .navigationDestination(isPresented: $showingPreviewInsights) {
            ParentChoreInsightsView()
        }
        .onAppear {
            #if DEBUG
            showingPreviewReview = ProcessInfo.processInfo.environment["CHACHING_REVIEW_DETAIL"] == "1"
            showingPreviewInsights = ProcessInfo.processInfo.environment["CHACHING_INSIGHTS"] == "1"
            #endif
        }
    }
}

struct FamilyPendingApprovalsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [AppStore.FamilyReviewItem] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Pending Approvals").font(.headline)
                Spacer()
                Text("\(items.count)").monospacedDigit()
            }
            if loading { ProgressView() }
            if let error {
                Text(error).foregroundStyle(.red)
                Button("Retry") { Task { await reload() } }
            }
            if items.isEmpty && !loading && error == nil {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle")
            }
            ForEach(store.childProfiles) { child in
                let childItems = items.filter { $0.occurrence.childId == child.id }
                if !childItems.isEmpty {
                    Text(child.displayName).font(.title3.weight(.bold))
                    ForEach(ChoreOccurrenceGroup.grouped(childItems.map(\.occurrence))) { group in
                        PendingApprovalGroup(items: group.occurrences.compactMap { task in childItems.first { $0.id == task.id } }, onSaved: { await reload() })
                        Divider()
                    }
                }
            }
        }
        .task(id: store.familySyncState) {
            guard !store.familySyncState.isWorking else { return }
            await reload()
        }
        .onChange(of: store.familyId) { _, _ in items = [] }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await store.loadFamilyPendingReviews()
            guard !Task.isCancelled else { return }
            items = result
            error = nil
        } catch {
            if !Task.isCancelled { self.error = "Couldn't refresh approvals. Try again." }
        }
    }
}

struct PendingApprovalGroup: View {
    @EnvironmentObject private var store: AppStore
    let items: [AppStore.FamilyReviewItem]
    let onSaved: () async -> Void
    @State private var selected: Set<UUID> = []
    @State private var decision: ParentDecision.Decision = .approved
    @State private var confirming = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                Button(selected.count == min(100, items.count) ? "Deselect all" : (items.count > 100 ? "Select first 100" : "Select all")) {
                    selected = selected.count == min(100, items.count) ? [] : Set(items.prefix(100).map(\.id))
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Button { if !selected.insert(item.id).inserted { selected.remove(item.id) } } label: {
                            Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
                                .font(.title2).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select \(item.occurrence.dueAt.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue(selected.contains(item.id) ? "Selected" : "Not selected")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.occurrence.dueAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.weight(.semibold))
                            if let reason = item.occurrence.excuseReason {
                                Label("Excuse requested", systemImage: "hand.raised")
                                Text(reason)
                            } else if let note = item.submission?.reportedDoneNote {
                                Label("Reported done without photo", systemImage: "text.bubble")
                                if !note.isEmpty { Text(note) }
                            } else if item.submission?.imageName == "no-photo" {
                                Label("Reported done", systemImage: "checkmark.bubble")
                            } else {
                                ReviewEvidenceThumbnail(chore: item.chore, submission: item.submission, size: 100)
                                if let ai = item.submission?.aiResult { Text(ai.reason) }
                            }
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !selected.isEmpty {
                    Text("\(selected.count) selected").font(.caption.weight(.semibold))
                    HStack {
                        Button { decision = .approved; confirming = true } label: { Label("Approve", systemImage: "checkmark") }
                        Spacer()
                        Button { decision = .excused; confirming = true } label: { Label("Excuse", systemImage: "hand.raised") }
                        Spacer()
                        Button { decision = .rejected; confirming = true } label: { Label("Reject", systemImage: "xmark") }
                    }
                    .font(.subheadline)
                    .disabled(selected.count > 100 || store.isMutationInFlight)
                }
            }
            .padding(.vertical, 12)
        } label: {
            if let first = items.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(first.chore.title).font(.headline)
                    Text("\(first.occurrence.dueAt.formatted(date: .omitted, time: .shortened)) · \(items.count) pending")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(store.isMutationInFlight)
        .onChange(of: items.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CHACHING_GROUPED_EXPANDED"] == "1" {
                expanded = true
                selected = Set(items.prefix(2).map(\.id))
            }
            #endif
        }
        .confirmationDialog("\(decision == .approved ? "Approve" : decision == .excused ? "Excuse" : "Reject") \(selected.count) selected chores?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Confirm") {
                let ids = Array(selected)
                let chosenDecision = decision
                Task {
                    if await store.reviewChoreBatch(ids: ids, decision: chosenDecision) { selected = [] }
                    await onSaved()
                }
            }
        } message: {
            Text(decision == .rejected ? "Deductions will remain or be applied for the selected chores." : "Any deductions for the selected chores will be restored.")
        }
    }
}

enum ReviewFilter: String, CaseIterable, Identifiable {
    case pending
    case today
    case reviewed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pending: return "Needs review"
        case .today: return "Today"
        case .reviewed: return "History"
        }
    }
}

struct ReviewQueueRow: View {
    var occurrence: TaskOccurrence
    var chore: ChoreDefinition

    private var awaitsResponse: Bool {
        occurrence.status.needsParentReview && occurrence.status != .rejected
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: awaitsResponse ? "tray.full.fill" : occurrence.status.isOpen ? "clock" : "checkmark.circle")
                .font(.title3)
                .foregroundStyle(awaitsResponse ? Color.inkBlack : Color.mutedGray)
                .frame(width: 42, height: 42)
                .background(awaitsResponse ? Color.sunYellow.opacity(0.3) : Color.softGray.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(chore.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.inkBlack)
                    .fixedSize(horizontal: false, vertical: true)
                Text(occurrence.excuseReason ?? occurrence.dueAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(Color.mutedGray)
                    .lineLimit(2)
                if !occurrence.status.isOpen {
                    Text(occurrence.status == .aiReviewed || occurrence.status == .submitted ? "Awaiting decision" : occurrence.status.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(occurrence.status == .missed || occurrence.status == .rejected ? Color.warmOrange : Color.mutedGray)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.mutedGray)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct ParentTaskReviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRejection = false
    var occurrenceId: UUID

    var body: some View {
        ScrollView {
            if let occurrence = store.occurrences.first(where: { $0.id == occurrenceId }),
               let chore = store.chore(id: occurrence.choreDefinitionId) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(chore.title).font(.title2.weight(.heavy))
                    Label(occurrence.dueAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(Color.mutedGray)
                    if let reason = occurrence.excuseReason {
                        Label(reason, systemImage: "hand.raised")
                            .font(.subheadline)
                    }
                    if let note = store.submission(for: occurrence)?.reportedDoneNote {
                        Label("Reported done without photo", systemImage: "text.bubble")
                        if !note.isEmpty { Text(note).foregroundStyle(Color.mutedGray) }
                    }
                    ReviewCard(occurrence: occurrence, chore: chore, submission: store.submission(for: occurrence))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What was expected").font(.headline)
                        Text(chore.instructions).font(.body).foregroundStyle(Color.mutedGray)
                        Text("Deduction if missed: \(Money.dollars(chore.deductionCents))")
                            .font(.subheadline.weight(.semibold))
                    }
                    NavigationLink("View allowance activity") { EarningsView(allowsBonusActions: true) }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(22)
            } else {
                ContentUnavailableView("Task no longer available", systemImage: "checkmark.circle")
            }
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("Task review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            if let occurrence = store.occurrences.first(where: { $0.id == occurrenceId }),
               store.allowanceSettlements[occurrence.weekId] == nil,
               (occurrence.status.needsParentReview || occurrence.status.isOpen) && occurrence.status != .rejected {
                VStack(spacing: 10) {
                    if store.isMutationInFlight { ProgressView("Saving decision...").font(.caption) }
                    HStack(spacing: 0) {
                        decisionButton("Approve", icon: "checkmark", color: .green) {
                            Task { if await store.approve(occurrence) { dismiss() } }
                        }
                        if occurrence.weekId == store.weekId {
                            Divider().frame(height: 32)
                            decisionButton("Retake", icon: "arrow.clockwise", color: .inkBlack) {
                                Task { if await store.requestRetake(occurrence) { dismiss() } }
                            }
                        }
                        Divider().frame(height: 32)
                        decisionButton("Reject", icon: "xmark", color: .warmOrange) {
                            confirmingRejection = true
                        }
                    }
                    .disabled(store.isMutationInFlight)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let occurrence = store.occurrences.first(where: { $0.id == occurrenceId }),
                       store.allowanceSettlements[occurrence.weekId] == nil,
                       occurrence.status.needsParentReview || occurrence.status.isOpen {
                        Button {
                            Task { if await store.excuse(occurrence, reason: "Parent excused") { dismiss() } }
                        } label: { Label("Excuse without deduction", systemImage: "hand.raised") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More review options")
                .disabled(store.isMutationInFlight)
            }
        }
        .confirmationDialog("Reject this submission?", isPresented: $confirmingRejection, titleVisibility: .visible) {
            if let occurrence = store.occurrences.first(where: { $0.id == occurrenceId }) {
                Button("Reject and apply deduction", role: .destructive) {
                    Task { if await store.reject(occurrence) { dismiss() } }
                }
            }
        } message: {
            if let occurrence = store.occurrences.first(where: { $0.id == occurrenceId }),
               let chore = store.chore(id: occurrence.choreDefinitionId) {
                Text("The allowance will include a \(Money.dollars(chore.deductionCents)) deduction for this chore.")
            }
        }
    }

    private func decisionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

struct ReviewCard: View {
    @EnvironmentObject private var store: AppStore
    @State private var isSendingNudge = false
    @State private var nudgeFeedback: String?
    @State private var nudgeQueued = false
    var occurrence: TaskOccurrence
    var chore: ChoreDefinition
    var submission: ChoreSubmission?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let submission, submission.imageName.contains("/") {
                ReviewEvidenceThumbnail(chore: chore, submission: submission, size: 240)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                if submission?.imageName.contains("/") != true {
                    ReviewEvidenceThumbnail(chore: chore, submission: submission)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(chore.title)
                            .font(.headline)
                            .foregroundStyle(Color.inkBlack)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        statusBadge
                    }

                    Text(submissionSummary)
                        .font(.caption)
                        .foregroundStyle(Color.mutedGray)

                    if let result = submission?.aiResult {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(verdictText(for: result), systemImage: verdictIcon(for: result))
                                .foregroundStyle(verdictColor(for: result))
                            Text("AI confidence: \(Int(result.confidence * 100))%")
                                .foregroundStyle(Color.mutedGray)
                        }
                        .font(.subheadline.weight(.bold))
                    } else if submission != nil {
                        Label("Parent review needed", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.sunYellow)
                    } else if occurrence.status.isOpen {
                        Text("Miss it: \(Money.dollars(-chore.deductionCents, signed: true))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.warmOrange)
                    } else if occurrence.status == .rejected || occurrence.status == .missed {
                        Text("Deduction: \(Money.dollars(-chore.deductionCents, signed: true))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.warmOrange)
                    } else {
                        Text("No photo evidence")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.mutedGray)
                    }
                }
            }

            if let reason = submission?.aiResult?.reason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(Color.mutedGray)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if occurrence.status.isOpen || occurrence.status == .missed {
                SecondaryActionButton(
                    title: nudgeQueued ? "Alert queued" : (isSendingNudge ? "Sending" : (occurrence.status == .missed ? "Send missed-chore alert" : "Nudge")),
                    systemImage: "bell.badge.fill",
                    tint: .sunYellow.opacity(0.7)
                ) {
                    guard !isSendingNudge else {
                        return
                    }

                    isSendingNudge = true
                    Task {
                        let saved = await store.sendNudge(for: occurrence)
                        nudgeQueued = saved
                        nudgeFeedback = saved
                            ? "Alert queued. Delivery needs notifications enabled and a sync on your child's phone."
                            : "Alert wasn't queued. Check your connection and try again."
                        isSendingNudge = false
                    }
                }
                .disabled(isSendingNudge || nudgeQueued)
                if let nudgeFeedback {
                    Text(nudgeFeedback).font(.caption).foregroundStyle(Color.mutedGray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(occurrence.status.needsParentReview ? Color.sunYellow : Color.softGray, lineWidth: 1.5)
        )
    }

    private var statusBadge: some View {
        Text(badgeText)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(Color.inkBlack)
            .background(badgeColor, in: Capsule())
    }

    private var submissionSummary: String {
        if let submission {
            return submission.submittedAt.formatted(date: .omitted, time: .shortened)
        }

        switch occurrence.status {
        case .approved:
            return "Completed"
        case .excused:
            return "Excused"
        case .rejected, .missed:
            return "Closed without evidence"
        case .upcoming, .due, .submitted, .aiReviewed:
            return "No submission"
        }
    }

    private var badgeText: String {
        switch occurrence.status {
        case .submitted, .aiReviewed:
            return "Pending"
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .missed:
            return "Missed"
        case .excused:
            return "Excused"
        case .upcoming, .due:
            return "Open"
        }
    }

    private var badgeColor: Color {
        switch occurrence.status {
        case .submitted, .aiReviewed:
            return .sunYellow.opacity(0.45)
        case .approved:
            return .acidLime.opacity(0.55)
        case .rejected, .missed:
            return .warmOrange.opacity(0.35)
        case .excused:
            return .electricBlue.opacity(0.25)
        case .upcoming, .due:
            return .softGray
        }
    }

    private func verdictText(for result: AIReviewResult) -> String {
        switch result.verdict {
        case .likelyComplete:
            return "Likely complete"
        case .likelyIncomplete:
            return "Likely incomplete"
        case .needsParentReview:
            return "Needs a closer look"
        }
    }

    private func verdictIcon(for result: AIReviewResult) -> String {
        switch result.verdict {
        case .likelyComplete:
            return "checkmark.circle.fill"
        case .likelyIncomplete:
            return "exclamationmark.triangle.fill"
        case .needsParentReview:
            return "questionmark.circle.fill"
        }
    }

    private func verdictColor(for result: AIReviewResult) -> Color {
        switch result.verdict {
        case .likelyComplete:
            return .green
        case .likelyIncomplete:
            return .warmOrange
        case .needsParentReview:
            return .warmOrange
        }
    }
}

struct ReviewEvidenceThumbnail: View {
    @EnvironmentObject private var store: AppStore
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var isShowingEvidence = false

    var chore: ChoreDefinition
    var submission: ChoreSubmission?
    var size: CGFloat = 76

    var body: some View {
        Button {
            guard image != nil else {
                return
            }
            isShowingEvidence = true
        } label: {
            thumbnail
        }
        .buttonStyle(.plain)
        .disabled(image == nil)
        .accessibilityLabel(image == nil ? "No evidence photo available" : "View evidence photo")
        .task(id: submission?.imageName) {
            await loadEvidence()
        }
        .fullScreenCover(isPresented: $isShowingEvidence) {
            EvidencePhotoViewer(image: image, choreTitle: chore.title)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.brandWhite)
                        .padding(6)
                        .background(Color.brandBlack.opacity(0.72), in: Circle())
                        .padding(5)
                }
        } else {
            placeholder
                .overlay {
                    if isLoading {
                        ProgressView()
                            .tint(Color.brandWhite)
                    } else if loadFailed {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.brandWhite)
                    }
                }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: thumbnailColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)

            if !isLoading && !loadFailed {
                Image(systemName: iconName)
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.brandWhite)
            }
        }
    }

    @MainActor
    private func loadEvidence() async {
        image = nil
        loadFailed = false

        guard let submission,
              submission.imageName.contains("/"),
              !submission.imageName.hasPrefix("mock-")
        else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            guard let data = try await store.evidenceImageData(for: submission),
                  let loadedImage = UIImage(data: data)
            else {
                loadFailed = true
                return
            }
            image = loadedImage
        } catch {
            loadFailed = true
        }
    }

    private var thumbnailColors: [Color] {
        if chore.title.contains("Dog") {
            return [.sunYellow, .warmOrange]
        }
        if chore.title.contains("Bathroom") {
            return [.electricBlue.opacity(0.62), .softGray]
        }
        return [.hotPink, .electricBlue]
    }

    private var iconName: String {
        if chore.title.contains("Dog") {
            return "pawprint.fill"
        }
        if chore.title.contains("Bathroom") {
            return "shower.fill"
        }
        return "bed.double.fill"
    }
}

private struct EvidencePhotoViewer: View {
    @Environment(\.dismiss) private var dismiss

    var image: UIImage?
    var choreTitle: String

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brandBlack.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Evidence photo for \(choreTitle)")
                }
            }
            .navigationTitle(choreTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

struct ParentChoreInsightsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedChore: ChoreDefinition?

    private var insights: [ChoreInsight] {
        ChoreInsight.summarize(chores: store.chores, occurrences: store.occurrences,
                              childId: store.childId)
    }

    var body: some View {
        List {
            Section {
                Text(store.childName).font(.headline)
                Text(store.allowancePeriodTitle).foregroundStyle(.secondary)
            }
            if insights.isEmpty {
                ContentUnavailableView("No missed-chore patterns yet", systemImage: "checkmark.circle",
                                       description: Text("Recorded misses will appear here during this allowance period."))
            }
            ForEach(insights) { insight in
                Section(insight.title) {
                    HStack {
                        Label("Missed", systemImage: "clock.badge.exclamationmark")
                        Spacer()
                        Text("\(insight.missedCount) of \(insight.observedCount)").fontWeight(.semibold)
                    }
                    ProgressView(value: Double(insight.missedCount), total: Double(insight.observedCount))
                        .tint(Color.warmOrange)
                        .accessibilityLabel("Missed \(insight.missedCount) of \(insight.observedCount) observed chores")
                    if insight.suggestsScheduleReview {
                        Text("This time may be hard to fit in. Ask whether a later time, different days, or a longer completion window would help.")
                            .font(.subheadline)
                    } else {
                        Text("Too few repeated misses to suggest a schedule change yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let chore = store.chore(id: insight.id), chore.archivedAt == nil {
                        Button { selectedChore = chore } label: {
                            Label("Review Schedule", systemImage: "calendar.badge.clock")
                        }
                    }
                }
            }
            Section {
                Text("Based on recorded outcomes in the current allowance period. Upcoming, unresolved, and excused chores are excluded. Rejected submissions count as attempted, not missed. Suggestions need at least three observations and two misses; they never change a schedule automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Chore Insights")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshRemoteFamilyState() }
        .sheet(item: $selectedChore) { chore in
            EditChoreSheet(chore: chore).environmentObject(store)
        }
    }
}

struct ChoreManagementView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedChore: ChoreDefinition?
    @State private var isAddingChore = false
    @State private var isChoosingTemplates = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Chores")
                        .font(.title3.weight(.heavy))

                    Spacer()

                    Button {
                        isAddingChore = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.brandBlack)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(Color.sunYellow.opacity(0.72), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        isChoosingTemplates = true
                    } label: {
                        Label("Templates", systemImage: "square.grid.2x2")
                            .font(.headline)
                            .foregroundStyle(Color.inkBlack)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(Color.acidLime.opacity(0.72), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if store.activeChores.isEmpty {
                    ContentUnavailableView("No chores yet", systemImage: "checklist")
                        .frame(minHeight: 240)
                } else {
                    ForEach(store.activeChores) { chore in
                        Button {
                            selectedChore = chore
                        } label: {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(chore.isPaused ? Color.softGray : Color.acidLime)
                                    .frame(width: 14, height: 14)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(chore.title)
                                        .font(.headline)
                                        .foregroundStyle(Color.inkBlack)
                                    Text(chore.isPaused
                                         ? "Paused · \(chore.recurrence.summary) · \(chore.dueTime)"
                                         : "\(chore.recurrence.summary) · \(chore.dueTime) · Miss it \(Money.dollars(-chore.deductionCents, signed: true))")
                                        .font(.caption)
                                        .foregroundStyle(Color.mutedGray)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.mutedGray)
                            }
                            .padding(16)
                            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.softGray, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(22)
        }
        .sheet(isPresented: $isAddingChore) {
            EditChoreSheet(chore: nil)
                .environmentObject(store)
        }
        .sheet(item: $selectedChore) { chore in
            EditChoreSheet(chore: chore)
                .environmentObject(store)
        }
        .sheet(isPresented: $isChoosingTemplates) {
            ChoreTemplatePickerView()
                .environmentObject(store)
        }
    }
}

struct ChoreTemplatePickerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var ageGroup: ChoreTemplateAgeGroup = .ages8To10
    @State private var selectedTemplateIDs: Set<String> = []
    @State private var isAdding = false
    @State private var importIDs: [String: UUID] = [:]
    @State private var importError: String?

    private var templates: [ChoreTemplate] {
        ChoreTemplate.forAgeGroup(ageGroup)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let importError {
                    Section {
                        Text(importError).foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Age group", selection: $ageGroup) {
                        ForEach(ChoreTemplateAgeGroup.allCases) { group in
                            Text(group.title).tag(group)
                        }
                    }
                    Text(ageGroup.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Recommended starting points")
                } footer: {
                    Text("Adapt these suggestions to your child's maturity, abilities, safety needs, and your family's routine. Adult supervision is still needed for cooking, cleaning products, tools, pets, and younger children.")
                }

                Section("Choose chores") {
                    ForEach(templates) { template in
                        Button {
                            toggle(template)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedTemplateIDs.contains(template.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTemplateIDs.contains(template.id) ? Color.acidLime : Color.mutedGray)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(template.title)
                                        .foregroundStyle(Color.inkBlack)
                                    Text("\(template.recurrence.summary) · \(template.dueTime)")
                                        .font(.caption)
                                        .foregroundStyle(Color.mutedGray)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(isAdding)
            .interactiveDismissDisabled(isAdding)
            .navigationTitle("Chore Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isAdding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdding ? "Adding..." : "Add (\(selectedTemplateIDs.count))") {
                        addSelectedTemplates()
                    }
                    .disabled(selectedTemplateIDs.isEmpty || isAdding)
                }
            }
        }
    }

    private func toggle(_ template: ChoreTemplate) {
        if selectedTemplateIDs.contains(template.id) {
            selectedTemplateIDs.remove(template.id)
        } else {
            selectedTemplateIDs.insert(template.id)
        }
    }

    private func addSelectedTemplates() {
        let selected = ChoreTemplate.all.filter { selectedTemplateIDs.contains($0.id) }
        let familyId = store.familyId
        let childId = store.childId
        for template in selected where importIDs[template.id] == nil {
            importIDs[template.id] = UUID()
        }
        importError = nil
        isAdding = true
        Task {
            defer { isAdding = false }
            for template in selected {
                guard store.familyId == familyId, store.childId == childId else {
                    importError = "The selected child changed. Close this sheet and try again."
                    return
                }
                guard let importID = importIDs[template.id] else { return }
                let saved = await store.addChore(
                    id: importID,
                    title: template.title,
                    description: template.description,
                    instructions: template.instructions,
                    expectedEvidence: template.expectedEvidence,
                    deductionCents: template.deductionCents,
                    dueTime: template.dueTime,
                    recurrence: template.recurrence,
                    verificationMode: .photoOptional,
                    blockPeopleInPhotos: true
                )
                guard saved else {
                    importError = "Couldn't add \(template.title). Chores already added are saved. Try again to add the remaining selections."
                    return
                }
                selectedTemplateIDs.remove(template.id)
            }
            dismiss()
        }
    }
}

struct PhotoSharingStatus: Decodable {
    let familyAuthorized: Bool
    let userAccepted: Bool
    var canUpload: Bool { familyAuthorized && userAccepted }
}

struct PrivacyAccountView: View {
    @EnvironmentObject private var store: AppStore
    @State private var consent: PhotoSharingStatus?
    @State private var errorMessage: String?
    @State private var showingConsent = false
    @State private var showingDelete = false
    @State private var deletionAccepted = false
    @State private var needsAppleRevocation = false
    @State private var isWorking = false
    @State private var confirmation = ""

    var body: some View {
        Form {
            Section("Photo sharing") {
                Text("Photos are stored privately with Supabase, shared with your family parents, and sent to OpenAI for AI review. AI is advisory; parents make the final decision.")
                if store.isSignedIn {
                    if let consent {
                        Label(consent.canUpload ? "Photo sharing authorized" : "Photo sharing needs permission", systemImage: consent.canUpload ? "checkmark.shield" : "hand.raised")
                        if !consent.canUpload {
                            Button("Review Photo Sharing") { showingConsent = true }
                        }
                        if consent.userAccepted || (store.isParentSession && consent.familyAuthorized) {
                            Button(store.isParentSession ? "Stop Family Photo Sharing" : "Stop My Photo Sharing", role: .destructive) {
                                Task { await revokeConsent() }
                            }
                        }
                    } else if errorMessage == nil { ProgressView("Checking permissions") }
                } else { Text("Sign in to manage photo sharing.").foregroundStyle(.secondary) }
                Text("Stopping sharing prevents new uploads. Existing photos follow your family's deletion settings. You can still report a chore without a photo for parent review.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privacy & support") {
                NavigationLink("Privacy Details") { PrivacyDetailsView() }
                Link("Privacy Policy", destination: AppBrand.privacyURL)
                Link("Support", destination: AppBrand.supportURL)
                Link("Email Support", destination: AppBrand.supportEmailURL)
            }
            if store.isSignedIn {
                Section("Account") {
                    Button("Sign Out") { Task { await store.signOutRemoteFamily() } }
                    Button("Delete Account", role: .destructive) { showingDelete = true }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await loadConsent() } }
                }
            }
            if deletionAccepted {
                Section("Deletion requested") {
                    Text("Your family access has been removed. Photo and account cleanup will continue automatically if needed.")
                    if needsAppleRevocation {
                        Text("Also remove ChaChing in iPhone Settings > your name > Sign in with Apple to revoke Apple's sign-in permission.")
                    }
                }
            }
        }
        .navigationTitle("Privacy & Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .task { await loadConsent() }
        .sheet(isPresented: $showingConsent, onDismiss: { Task { await loadConsent() } }) {
            PhotoSharingConsentView(onAccepted: {})
        }
        .sheet(isPresented: $showingDelete) {
            NavigationStack {
                Form {
                    Section {
                        Text("This permanently deletes your account. This cannot be undone.").font(.headline)
                        Text("For a child: their profile, chores, photos, savings goals, and allowance history are deleted.")
                        Text("For a parent: another parent can continue managing the family. Shared child and allowance history stays, with your account attribution removed. If you are the last parent, the family and all its child data are deleted. Other people's sign-in accounts are not deleted.")
                        Text("Photos are removed through an automatic cleanup queue. If a service is unavailable, deletion retries automatically.")
                    }
                    Section("Type DELETE to confirm") {
                        TextField("DELETE", text: $confirmation)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        if store.usesAppleSignIn {
                            Text("Continue with Apple to revoke sign-in permission and delete your account. You can also delete below and remove Apple permission in Settings afterward.")
                                .font(.footnote)
                            SignInWithAppleButton(.continue) { request in
                                request.requestedScopes = []
                            } onCompletion: { result in
                                switch result {
                                case .success(let authorization):
                                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential
                                    let code = credential?.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                                    Task { await deleteAccount(appleAuthorizationCode: code) }
                                case .failure:
                                    errorMessage = "Apple authorization wasn't completed. You can try again or delete your account below."
                                }
                            }
                            .frame(height: 44)
                            .disabled(confirmation != "DELETE" || isWorking)
                        }
                        Button(isWorking ? "Deleting..." : "Permanently Delete Account", role: .destructive) {
                            Task { await deleteAccount() }
                        }.disabled(confirmation != "DELETE" || isWorking)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
                .navigationTitle("Delete Account")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingDelete = false }.disabled(isWorking) } }
                .interactiveDismissDisabled(isWorking)
            }
        }
    }

    private func loadConsent() async {
        guard store.isSignedIn else { return }
        do { consent = try await store.photoSharingStatus(); errorMessage = nil }
        catch { errorMessage = "Couldn't load photo permissions. Check your connection and try again." }
    }

    private func revokeConsent() async {
        isWorking = true
        defer { isWorking = false }
        do { try await store.setPhotoSharingConsent(accepted: false); await loadConsent() }
        catch { errorMessage = "Couldn't stop photo sharing. Please try again." }
    }

    private func deleteAccount(appleAuthorizationCode: String? = nil) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let appleRevoked = try await store.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
            needsAppleRevocation = !appleRevoked
            deletionAccepted = true
            showingDelete = false
            confirmation = ""
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't confirm account deletion. Please try again. If it continues, contact support."
        }
    }
}

struct PhotoSharingConsentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onAccepted: () -> Void
    @State private var status: PhotoSharingStatus?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Before sharing a photo") {
                    Text("Your photo will be uploaded to Supabase and sent to OpenAI to help review the chore. Parents in your family can view it and make the final decision.")
                    Text("Keep people and private information out of the photo. When people blocking is enabled, the app checks on your device before uploading. Detection can miss people.")
                    Text("Photos are deleted according to your family's evidence settings. Chore status and allowance history remain after photos are deleted. AI providers may retain data under their own policies.")
                    NavigationLink("Privacy Details") { PrivacyDetailsView() }
                }
                if let status {
                    if store.isParentSession || status.familyAuthorized {
                        Section {
                            Button(isSaving ? "Saving..." : store.isParentSession ? "Authorize Family Photo Sharing" : "Allow Photo Sharing") {
                                Task {
                                    isSaving = true
                                    defer { isSaving = false }
                                    do {
                                        try await store.setPhotoSharingConsent(accepted: true)
                                        onAccepted()
                                        dismiss()
                                    } catch { errorMessage = "Permission wasn't saved. Please try again." }
                                }
                            }.disabled(isSaving)
                        }
                    } else {
                        Section { Text("Ask a parent to authorize photo sharing in Family > Privacy & Account. You can report this chore without a photo for now.") }
                    }
                } else { ProgressView("Checking family permission") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle("Photo Sharing")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() }.disabled(isSaving) } }
            .task {
                do { status = try await store.photoSharingStatus() }
                catch { errorMessage = "Couldn't check family permission. Close this screen and try again." }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}

struct PrivacyDetailsView: View {
    var body: some View {
        Form {
            Section("Your family data") {
                Text("ChaChing stores sign-in details, family memberships, chores, reviews, savings goals, and allowance records in Supabase. Family parents can manage their children's records. Other families cannot access them.")
            }
            Section("Photos and AI") {
                Text("Photos are optional evidence. A parent authorizes cloud sharing, and each person agrees before uploading. Supabase stores photos privately; OpenAI processes them for chore review. Parents can approve a no-photo report instead.")
                Text("People detection runs on the device when enabled. It is not a guarantee. Keep faces, addresses, school details, and other private information out of photos.")
                Text("Reviewed photos follow family and chore retention settings, including any deletion grace period. A cleanup job removes due images. Abandoned uploads become eligible for cleanup after 24 hours. Deleting a photo does not delete the chore or allowance record.")
            }
            Section("Reminders and location") {
                Text("Notification permission is optional. Location reminders use locations you choose; home reminders run on your device. Chore destinations and parent alert settings are shared with your family. ChaChing does not provide continuous location tracking.")
            }
            Section("Deletion") {
                Text("Delete your account from Privacy & Account. Deleting a child account deletes that child's data. Deleting a parent preserves shared family records if another parent remains; deleting the last parent removes the family and its child data. Storage cleanup retries automatically. Provider backups and processing logs follow the providers' retention policies.")
            }
            Section {
                Link("OpenAI Data Controls", destination: URL(string: "https://platform.openai.com/docs/guides/your-data")!)
                Link("Contact Support", destination: AppBrand.supportEmailURL)
            }
        }
        .navigationTitle("Privacy Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FamilyManagementView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("chaching.family.childNameDraft") private var childName = "Zoe"
    @SceneStorage("chaching.family.childPhoneDraft") private var phoneNumber = ""
    @SceneStorage("chaching.family.parentNameDraft") private var parentName = "Mamma"
    @SceneStorage("chaching.family.parentPhoneDraft") private var parentPhoneNumber = ""
    @State private var childInviteDraftId = UUID()
    @State private var parentInviteDraftId = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FamilySyncCard()
                    .environmentObject(store)

                NavigationLink {
                    PrivacyAccountView()
                } label: {
                    Label("Privacy & Account", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }

                if let syncMessage = store.inviteCreationState.message {
                    Label(syncMessage, systemImage: store.inviteCreationState.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.inviteCreationState.isSynced ? Color.inkBlack : Color.mutedGray)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            (store.inviteCreationState.isSynced ? Color.acidLime : Color.softGray).opacity(0.45),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }

                AllowanceSettingsCard()
                    .environmentObject(store)

                EvidencePrivacySettingsCard()
                    .environmentObject(store)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Parents")
                        .font(.title3.weight(.heavy))

                    ForEach(store.members.filter { $0.role == .parent }) { member in
                        ParentMemberCard(member: member, isCurrentSession: member.userId == store.session.userId)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Invite Parent")
                        .font(.title3.weight(.heavy))

                    VStack(spacing: 12) {
                        TextField("Parent name", text: $parentName)
                            .textContentType(.givenName)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)

                        TextField("Phone number", text: $parentPhoneNumber)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)

                        PrimaryButton(title: "Create Parent Invite", systemImage: "person.badge.plus") {
                            Task {
                                let saved = await store.createParentInvite(
                                    id: parentInviteDraftId,
                                    parentName: parentName,
                                    phoneNumber: parentPhoneNumber
                                )
                                if saved {
                                    parentInviteDraftId = UUID()
                                }
                            }
                        }
                        .disabled(store.inviteCreationState.isWorking)
                    }
                    .padding(16)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.softGray, lineWidth: 1)
                    )
                }

                if !store.parentInvites.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Parent Links")
                            .font(.title3.weight(.heavy))

                        ForEach(store.parentInvites) { invite in
                            ParentInviteCard(invite: invite)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Children")
                        .font(.title3.weight(.heavy))

                    ForEach(store.childProfiles) { profile in
                        ChildProfileCard(profile: profile)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Invite Child")
                        .font(.title3.weight(.heavy))

                    VStack(spacing: 12) {
                        TextField("Child name", text: $childName)
                            .textContentType(.givenName)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)

                        TextField("Phone number", text: $phoneNumber)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)

                        PrimaryButton(title: "Create Child Invite", systemImage: "link.badge.plus") {
                            Task {
                                let saved = await store.createChildInvite(
                                    id: childInviteDraftId,
                                    childName: childName,
                                    phoneNumber: phoneNumber
                                )
                                if saved {
                                    childInviteDraftId = UUID()
                                }
                            }
                        }
                        .disabled(store.inviteCreationState.isWorking)
                    }
                    .padding(16)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.softGray, lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Child Links")
                        .font(.title3.weight(.heavy))

                    if store.childInvites.isEmpty {
                        ContentUnavailableView("No invites yet", systemImage: "message.badge")
                            .frame(minHeight: 180)
                    } else {
                        ForEach(store.childInvites) { invite in
                            ChildInviteCard(invite: invite)
                        }
                    }
                }
            }
            .padding(22)
        }
    }
}

struct FamilySyncCard: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("chaching.familySync.signInMethod") private var signInMethodRawValue = FamilySyncSignInMethod.apple.rawValue
    @SceneStorage("chaching.familySync.emailDraft") private var email = ""
    @SceneStorage("chaching.familySync.phoneDraft") private var phoneNumber = ""
    @SceneStorage("chaching.familySync.codeDraft") private var oneTimeCode = ""
    @SceneStorage("chaching.familySync.bootstrapParentNameDraft") private var bootstrapParentName = "Daddy"
    @SceneStorage("chaching.familySync.bootstrapChildNameDraft") private var bootstrapChildName = "Zoe"
    @State private var appleSignInNonce: String?

    private var signInMethod: FamilySyncSignInMethod {
        FamilySyncSignInMethod(rawValue: signInMethodRawValue) ?? .email
    }

    private var signInMethodBinding: Binding<FamilySyncSignInMethod> {
        Binding {
            signInMethod
        } set: { method in
            signInMethodRawValue = method.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Family Sync", systemImage: store.familySyncState.iconName)
                    .font(.title3.weight(.heavy))
                Spacer()
                if store.familySyncState.isSynced {
                    Text("Live")
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.acidLime.opacity(0.65), in: Capsule())
                }
            }

            Text(store.familySyncState.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.familySyncState.isSynced ? Color.inkBlack : Color.mutedGray)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 12) {
                Picker("Sign in method", selection: signInMethodBinding) {
                    ForEach(FamilySyncSignInMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                switch signInMethod {
                case .apple:
                    SignInWithAppleButton(.continue) { request in
                        let nonce = AppleSignInSupport.randomNonce()
                        appleSignInNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AppleSignInSupport.sha256(nonce)
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("Uses Apple ID for family sync. Invites still decide whether this person joins as a parent or child.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.mutedGray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .email, .phone:
                    switch signInMethod {
                    case .email:
                        TextField("Email address", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)
                    case .phone:
                        TextField("Phone number", text: $phoneNumber)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)
                    case .apple:
                        EmptyView()
                    }

                    if store.familySyncState.hasPendingCode {
                        TextField("One-time code", text: $oneTimeCode)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .font(.body.weight(.semibold))
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await requestCode()
                            }
                        } label: {
                            Label("Send Code", systemImage: signInMethod.iconName)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .foregroundStyle(Color.brandBlack)
                                .background(Color.sunYellow.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task {
                                await verifyCode()
                            }
                        } label: {
                            Label("Verify", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .foregroundStyle(Color.brandWhite)
                                .background(Color.brandBlack, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.familySyncState.hasPendingCode)
                    }
                }

                if store.familySyncState.needsBootstrap {
                    TextField("Parent display name", text: $bootstrapParentName)
                        .textContentType(.givenName)
                        .font(.body.weight(.semibold))
                        .textFieldStyle(.roundedBorder)

                    TextField("Child display name", text: $bootstrapChildName)
                        .textContentType(.givenName)
                        .font(.body.weight(.semibold))
                        .textFieldStyle(.roundedBorder)

                    PrimaryButton(title: "Create Remote Family", systemImage: "icloud.and.arrow.up.fill") {
                        Task {
                            await store.bootstrapRemoteFamily(
                                parentName: bootstrapParentName,
                                childName: bootstrapChildName
                            )
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await store.loadRemoteFamilyState()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .foregroundStyle(Color.inkBlack)
                            .background(Color.softGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if store.familySyncState.isSynced {
                        Button {
                            Task {
                                await store.signOutRemoteFamily()
                            }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .foregroundStyle(Color.inkBlack)
                                .background(Color.softGray.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .disabled(store.familySyncState.isWorking)
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(store.familySyncState.isSynced ? Color.acidLime : Color.softGray, lineWidth: 1.5)
        )
    }

    private func requestCode() async {
        oneTimeCode = ""

        switch signInMethod {
        case .email:
            await store.requestFamilySyncEmailCode(email: email)
        case .phone:
            await store.requestFamilySyncCode(phoneNumber: phoneNumber)
        case .apple:
            break
        }
    }

    private func verifyCode() async {
        switch signInMethod {
        case .email:
            await store.verifyFamilySyncEmailCode(
                email: store.familySyncState.codeEmail ?? email,
                code: oneTimeCode
            )
        case .phone:
            await store.verifyFamilySyncCode(
                phoneNumber: store.familySyncState.codePhoneNumber ?? phoneNumber,
                code: oneTimeCode
            )
        case .apple:
            break
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            do {
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    throw AppleSignInError.invalidCredential
                }

                let identityToken = try AppleSignInSupport.identityTokenString(from: credential)
                let nonce = appleSignInNonce
                let fullName = credential.fullName?.formatted()

                Task {
                    await store.signInWithApple(
                        idToken: identityToken,
                        nonce: nonce,
                        fullName: fullName
                    )
                }
            } catch {
                store.failFamilySync(message: error.localizedDescription)
            }
        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return
            }

            store.failFamilySync(message: error.localizedDescription)
        }
    }
}

private enum FamilySyncSignInMethod: String, CaseIterable, Identifiable {
    case apple
    case email
    case phone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple:
            return "Apple"
        case .email:
            return "Email"
        case .phone:
            return "Phone"
        }
    }

    var iconName: String {
        switch self {
        case .apple:
            return "apple.logo"
        case .email:
            return "envelope.fill"
        case .phone:
            return "message.fill"
        }
    }
}

private enum AppleSignInSupport {
    private static let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

    static func randomNonce(length: Int = 32) -> String {
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randomBytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)

            guard status == errSecSuccess else {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            }

            for randomByte in randomBytes where remainingLength > 0 {
                guard Int(randomByte) < charset.count else {
                    continue
                }

                result.append(charset[Int(randomByte)])
                remainingLength -= 1
            }
        }

        return result
    }

    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    static func identityTokenString(from credential: ASAuthorizationAppleIDCredential) throws -> String {
        guard
            let identityToken = credential.identityToken,
            let tokenString = String(data: identityToken, encoding: .utf8)
        else {
            throw AppleSignInError.missingIdentityToken
        }

        return tokenString
    }
}

private enum AppleSignInError: LocalizedError {
    case invalidCredential
    case missingIdentityToken

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Apple did not return a usable sign-in credential."
        case .missingIdentityToken:
            return "Apple did not return a sign-in token."
        }
    }
}

struct AllowanceSettingsCard: View {
    @EnvironmentObject private var store: AppStore
    @State private var allowanceAmount = ""
    @State private var draftCadence: AllowanceCadence = .weekly
    @State private var draftWeekday: AllowanceWeekday = .friday
    @State private var draftNextAllowanceDate = Date()
    @State private var isSaving = false
    @FocusState private var isAllowanceAmountFocused: Bool

    private var parsedAllowanceCents: Int? {
        Money.cents(fromDollarString: allowanceAmount)
    }

    private var hasChanges: Bool {
        parsedAllowanceCents != store.allowanceSettings.baseAllowanceCents
            || draftCadence != store.allowanceSettings.cadence
            || draftWeekday != store.allowanceSettings.allowanceWeekday
            || !Calendar.current.isDate(
                draftNextAllowanceDate,
                inSameDayAs: store.allowanceSettings.nextAllowanceDate
            )
    }

    private var draftNextScheduledDate: Date {
        AllowanceSettings(
            familyId: store.allowanceSettings.familyId,
            baseAllowanceCents: parsedAllowanceCents ?? store.allowanceSettings.baseAllowanceCents,
            cadence: draftCadence,
            allowanceWeekday: draftWeekday,
            nextAllowanceDate: draftNextAllowanceDate
        ).nextScheduledAllowanceDate()
    }

    private var draftWeekdayBinding: Binding<AllowanceWeekday> {
        Binding {
            draftWeekday
        } set: { weekday in
            draftWeekday = weekday
            var components = Calendar.current.dateComponents(
                [.yearForWeekOfYear, .weekOfYear],
                from: draftNextAllowanceDate
            )
            components.weekday = weekday.rawValue
            if let alignedDate = Calendar.current.date(from: components) {
                draftNextAllowanceDate = alignedDate
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allowance Schedule")
                .font(.title3.weight(.heavy))

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Label("Allowance amount", systemImage: "dollarsign.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.inkBlack)

                    Spacer()

                    HStack(spacing: 6) {
                        Text("$")
                            .foregroundStyle(Color.mutedGray)

                        TextField("0.00", text: $allowanceAmount)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .focused($isAllowanceAmountFocused)
                            .frame(width: 82)

                        Image(systemName: parsedAllowanceCents == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(parsedAllowanceCents == nil ? Color.warmOrange : Color.inkBlack)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 42)
                    .background(Color.softGray.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("Amount changes begin with the next allowance period. This period stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(Color.mutedGray)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Cadence", selection: $draftCadence) {
                    ForEach(AllowanceCadence.allCases) { cadence in
                        Text(cadence.title).tag(cadence)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Allowance day", selection: draftWeekdayBinding) {
                    ForEach(AllowanceWeekday.allCases) { weekday in
                        Text(weekday.title).tag(weekday)
                    }
                }

                if draftCadence == .everyTwoWeeks {
                    DatePicker(
                        "Next payday",
                        selection: $draftNextAllowanceDate,
                        displayedComponents: .date
                    )
                }

                HStack {
                    Label("Next allowance", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.mutedGray)
                    Spacer()
                    Text(draftNextScheduledDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Color.inkBlack)
                }

                PrimaryButton(
                    title: isSaving ? "Saving" : "Save Schedule",
                    systemImage: isSaving ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
                ) {
                    saveAllowanceSettings()
                }
                .disabled(parsedAllowanceCents == nil || !hasChanges || isSaving)

                PrimaryButton(title: "Schedule Reminders", systemImage: "bell.badge.fill") {
                    Task {
                        await store.enableLocalNotifications()
                    }
                }

                if store.notificationState != .idle {
                    Text(store.notificationState.message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.notificationState == .scheduled ? Color.inkBlack : Color.mutedGray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
        .onAppear {
            refreshDrafts()
        }
        .onChange(of: store.allowanceSettings) { _, _ in
            guard !isAllowanceAmountFocused, !isSaving else { return }
            refreshDrafts()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isAllowanceAmountFocused = false
                }
            }
        }
    }

    private func saveAllowanceSettings() {
        guard let cents = parsedAllowanceCents else { return }

        isAllowanceAmountFocused = false
        isSaving = true
        Task {
            let saved = await store.updateAllowanceSettings(
                cadence: draftCadence,
                allowanceWeekday: draftWeekday,
                nextAllowanceDate: draftNextAllowanceDate,
                baseAllowanceCents: cents
            )
            isSaving = false
            if saved {
                refreshDrafts()
            }
        }
    }

    private func refreshDrafts() {
        allowanceAmount = Money.dollars(store.allowanceSettings.baseAllowanceCents)
            .replacingOccurrences(of: "$", with: "")
        draftCadence = store.allowanceSettings.cadence
        draftWeekday = store.allowanceSettings.allowanceWeekday
        draftNextAllowanceDate = store.allowanceSettings.nextAllowanceDate
    }
}

struct EvidencePrivacySettingsCard: View {
    @EnvironmentObject private var store: AppStore
    @State private var draftPolicy: FamilyEvidencePolicy?
    @State private var isSaving = false

    private var policy: FamilyEvidencePolicy {
        draftPolicy ?? store.evidencePolicy
    }

    private var hasChanges: Bool {
        draftPolicy != nil && draftPolicy != store.evidencePolicy
    }

    private var photoEvidenceBinding: Binding<Bool> {
        Binding {
            policy.photoEvidenceEnabled
        } set: { value in
            updatePolicy { $0.photoEvidenceEnabled = value }
        }
    }

    private var defaultVerificationBinding: Binding<VerificationMode> {
        Binding {
            policy.defaultVerificationMode
        } set: { value in
            updatePolicy { $0.defaultVerificationMode = value }
        }
    }

    private var blockPeopleBinding: Binding<Bool> {
        Binding {
            policy.blockPeopleInPhotos
        } set: { value in
            updatePolicy { $0.blockPeopleInPhotos = value }
        }
    }

    private var retentionBinding: Binding<EvidenceRetentionMode> {
        Binding {
            policy.evidenceRetentionMode
        } set: { value in
            updatePolicy { $0.evidenceRetentionMode = value }
        }
    }

    private var graceBinding: Binding<Int> {
        Binding {
            policy.deleteGraceMinutes
        } set: { value in
            updatePolicy { $0.deleteGraceMinutes = value }
        }
    }

    private var periodCloseBinding: Binding<Int> {
        Binding {
            policy.deleteAfterPeriodCloseDays
        } set: { value in
            updatePolicy { $0.deleteAfterPeriodCloseDays = value }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Evidence Privacy")
                .font(.title3.weight(.heavy))

            VStack(spacing: 12) {
                Toggle("Photo evidence", isOn: photoEvidenceBinding)
                    .font(.body.weight(.semibold))

                Picker("Default proof", selection: defaultVerificationBinding) {
                    ForEach(VerificationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("Block people in photos", isOn: blockPeopleBinding)
                    .font(.body.weight(.semibold))
                    .disabled(!policy.photoEvidenceEnabled)

                Picker("Delete photos", selection: retentionBinding) {
                    ForEach(EvidenceRetentionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!policy.photoEvidenceEnabled)

                Stepper(value: graceBinding, in: 0...60, step: 5) {
                    Label("\(policy.deleteGraceMinutes) min undo", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.inkBlack)
                }
                .disabled(!policy.photoEvidenceEnabled)

                Stepper(value: periodCloseBinding, in: 0...7) {
                    Label("\(policy.deleteAfterPeriodCloseDays) day cleanup", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.inkBlack)
                }
                .disabled(!policy.photoEvidenceEnabled)

                PrimaryButton(
                    title: isSaving ? "Saving" : "Save Privacy Settings",
                    systemImage: isSaving ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
                ) {
                    savePolicy()
                }
                .disabled(!hasChanges || isSaving)
            }
            .padding(16)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
        .onAppear {
            draftPolicy = store.evidencePolicy
        }
        .onChange(of: store.evidencePolicy) { _, newPolicy in
            guard !isSaving else { return }
            draftPolicy = newPolicy
        }
    }

    private func updatePolicy(_ mutation: (inout FamilyEvidencePolicy) -> Void) {
        var updatedPolicy = policy
        mutation(&updatedPolicy)
        draftPolicy = updatedPolicy
    }

    private func savePolicy() {
        let policy = policy
        isSaving = true
        Task {
            let saved = await store.updateEvidencePolicy(
                photoEvidenceEnabled: policy.photoEvidenceEnabled,
                defaultVerificationMode: policy.defaultVerificationMode,
                blockPeopleInPhotos: policy.blockPeopleInPhotos,
                evidenceRetentionMode: policy.evidenceRetentionMode,
                deleteGraceMinutes: policy.deleteGraceMinutes,
                deleteAfterPeriodCloseDays: policy.deleteAfterPeriodCloseDays
            )
            isSaving = false
            if saved {
                draftPolicy = store.evidencePolicy
            }
        }
    }
}

struct ParentMemberCard: View {
    var member: FamilyMember
    var isCurrentSession: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isCurrentSession ? Color.sunYellow : Color.acidLime)
                    .frame(width: 48, height: 48)
                Image(systemName: isCurrentSession ? "person.fill.checkmark" : "person.2.fill")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.inkBlack)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(member.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.inkBlack)

                Text(isCurrentSession ? "Signed in here" : "Can review and manage chores")
                    .font(.caption)
                    .foregroundStyle(Color.mutedGray)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

struct ChildProfileCard: View {
    var profile: ChildProfile

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(profile.linkedUserId == nil ? Color.sunYellow : Color.acidLime)
                    .frame(width: 48, height: 48)
                Image(systemName: profile.linkedUserId == nil ? "person.crop.circle.badge.plus" : "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.inkBlack)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.displayName)
                    .font(.headline)
                    .foregroundStyle(Color.inkBlack)

                Text(profile.linkedUserId == nil ? "Waiting for account link" : "Connected child account")
                    .font(.caption)
                    .foregroundStyle(Color.mutedGray)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

struct ParentInviteCard: View {
    @EnvironmentObject private var store: AppStore
    var invite: ParentInvite

    private var status: ParentInviteStatus {
        invite.resolvedStatus()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(invite.parentName)
                        .font(.headline)
                        .foregroundStyle(Color.inkBlack)
                    if let phoneNumber = invite.phoneNumber {
                        Text(phoneNumber)
                            .font(.caption)
                            .foregroundStyle(Color.mutedGray)
                    }
                }

                Spacer()

                Text(status.title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(Color.inkBlack)
                    .background(statusColor, in: Capsule())
            }

            Text(invite.inviteURL.absoluteString)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.softGray.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if status == .pending {
                HStack(spacing: 10) {
                    ShareLink(
                        item: invite.inviteURL,
                        subject: Text("Join \(AppBrand.displayName)"),
                        message: Text("\(store.parentName) invited you to help manage \(AppBrand.displayName).")
                    ) {
                        Label("Send Message", systemImage: "message.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(Color.brandBlack)
                            .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button {
                        Task {
                            await store.revokeParentInvite(invite)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 48, height: 48)
                            .foregroundStyle(Color.inkBlack)
                            .background(Color.softGray, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(store.isMutationInFlight)
                    .accessibilityLabel("Revoke parent invite")
                }

                #if DEBUG
                Button {
                    store.markParentInviteAccepted(invite)
                } label: {
                    Label("Mark Accepted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.sunYellow.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(status == .pending ? Color.sunYellow : Color.softGray, lineWidth: 1.5)
        )
    }

    private var statusColor: Color {
        switch status {
        case .pending:
            return .sunYellow.opacity(0.5)
        case .accepted:
            return .acidLime.opacity(0.55)
        case .expired:
            return .warmOrange.opacity(0.35)
        case .revoked:
            return .softGray
        }
    }
}

struct ChildInviteCard: View {
    @EnvironmentObject private var store: AppStore
    var invite: ChildInvite

    private var status: ChildInviteStatus {
        invite.resolvedStatus()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(invite.childName)
                        .font(.headline)
                        .foregroundStyle(Color.inkBlack)
                    if let phoneNumber = invite.phoneNumber {
                        Text(phoneNumber)
                            .font(.caption)
                            .foregroundStyle(Color.mutedGray)
                    }
                }

                Spacer()

                Text(status.title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .foregroundStyle(Color.inkBlack)
                    .background(statusColor, in: Capsule())
            }

            Text(invite.inviteURL.absoluteString)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.softGray.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if status == .pending {
                HStack(spacing: 10) {
                    ShareLink(
                        item: invite.inviteURL,
                        subject: Text("Join \(AppBrand.displayName)"),
                        message: Text("\(store.parentName) invited you to join \(AppBrand.displayName).")
                    ) {
                        Label("Send Message", systemImage: "message.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(Color.brandBlack)
                            .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button {
                        Task {
                            await store.revokeInvite(invite)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 48, height: 48)
                            .foregroundStyle(Color.inkBlack)
                            .background(Color.softGray, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(store.isMutationInFlight)
                    .accessibilityLabel("Revoke invite")
                }

                #if DEBUG
                Button {
                    store.markInviteAccepted(invite)
                } label: {
                    Label("Mark Accepted", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.sunYellow.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(status == .pending ? Color.sunYellow : Color.softGray, lineWidth: 1.5)
        )
    }

    private var statusColor: Color {
        switch status {
        case .pending:
            return .sunYellow.opacity(0.5)
        case .accepted:
            return .acidLime.opacity(0.55)
        case .expired:
            return .warmOrange.opacity(0.35)
        case .revoked:
            return .softGray
        }
    }
}

struct EditChoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let chore: ChoreDefinition?

    @State private var title: String
    @State private var description: String
    @State private var instructions: String
    @State private var expectedEvidence: String
    @State private var deduction: String
    @State private var dueTime: Date
    @State private var repeatFrequency: ChoreRepeatFrequency
    @State private var weekdays: Set<ChoreWeekday>
    @State private var oneTimeDate: Date
    @State private var verificationMode: VerificationMode
    @State private var blockPeopleInPhotos: Bool
    @State private var parentAlertEnabled: Bool
    @State private var parentAlertDelayMinutes: Int
    @State private var locationEnabled: Bool
    @State private var destinationName: String
    @State private var destinationLatitude: Double?
    @State private var destinationLongitude: Double?
    @State private var destinationRadiusMeters: Double
    @State private var destinationLeaveReminderMinutes: Int
    @StateObject private var locationCapture = ChoreDestinationLocationCapture()
    @State private var isShowingArchiveConfirmation = false
    @State private var isSaving = false
    @State private var draftChoreId: UUID

    init(chore: ChoreDefinition?) {
        self.chore = chore
        _title = State(initialValue: chore?.title ?? "")
        _description = State(initialValue: chore?.description ?? "")
        _instructions = State(initialValue: chore?.instructions ?? "")
        _expectedEvidence = State(initialValue: chore?.expectedEvidence ?? "")
        _deduction = State(initialValue: Money.dollars(chore?.deductionCents ?? 100).replacingOccurrences(of: "$", with: ""))
        _dueTime = State(initialValue: Self.dueTimeFormatter.date(from: chore?.dueTime ?? "8:00 PM") ?? Date())
        _repeatFrequency = State(initialValue: chore?.recurrence.frequency ?? .daily)
        _weekdays = State(initialValue: Set(chore?.recurrence.weekdays ?? [Self.currentWeekday]))
        _oneTimeDate = State(initialValue: chore?.recurrence.oneTimeDate ?? Date())
        _verificationMode = State(initialValue: chore?.verificationMode ?? .photoOptional)
        _blockPeopleInPhotos = State(initialValue: chore?.blockPeopleInPhotos ?? true)
        _parentAlertEnabled = State(initialValue: chore?.parentAlertEnabled ?? false)
        _parentAlertDelayMinutes = State(initialValue: chore?.parentAlertDelayMinutes ?? 0)
        _locationEnabled = State(initialValue: chore?.location != nil)
        _destinationName = State(initialValue: chore?.location?.name ?? "")
        _destinationLatitude = State(initialValue: chore?.location?.latitude)
        _destinationLongitude = State(initialValue: chore?.location?.longitude)
        _destinationRadiusMeters = State(initialValue: chore?.location?.radiusMeters ?? 200)
        _destinationLeaveReminderMinutes = State(initialValue: chore?.location?.leaveReminderMinutes ?? 30)
        _locationCapture = StateObject(wrappedValue: ChoreDestinationLocationCapture())
        _draftChoreId = State(initialValue: chore?.id ?? UUID())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Chore") {
                    TextField("Title", text: $title)
                    TextField("Short note", text: $description)
                    TextField("Deduction", text: $deduction)
                        .keyboardType(.decimalPad)
                }
                Section("Schedule") {
                    DatePicker("Time", selection: $dueTime, displayedComponents: .hourAndMinute)

                    Picker("Repeat", selection: $repeatFrequency) {
                        ForEach(ChoreRepeatFrequency.allCases) { frequency in
                            Text(frequency.title).tag(frequency)
                        }
                    }
                    .pickerStyle(.segmented)

                    if repeatFrequency == .weekly {
                        weekdayPicker
                    } else if repeatFrequency == .once {
                        DatePicker("Date", selection: $oneTimeDate, displayedComponents: .date)
                    }
                }
                Section("Evidence") {
                    Picker("Proof", selection: $verificationMode) {
                        ForEach(VerificationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("Block people in photos", isOn: $blockPeopleInPhotos)
                        .disabled(verificationMode == .parentOnly || verificationMode == .noVerification)
                }
                Section("Instructions") {
                    TextField("What to do", text: $instructions, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Photo guidance", text: $expectedEvidence, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Toggle("Alert parent if unfinished", isOn: $parentAlertEnabled)
                    if parentAlertEnabled {
                        Picker("Alert after due", selection: $parentAlertDelayMinutes) {
                            Text("At due time").tag(0)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                            Text("90 minutes").tag(90)
                        }
                    }
                } header: {
                    Text("Parent Alert")
                } footer: {
                    Text("The parent receives one alert when this occurrence is still unfinished. Submitted chores count as done. Delivery requires the parent to have notifications enabled and the child to be online recently.")
                }
                Section {
                    Toggle("Location-aware chore", isOn: $locationEnabled)
                    if locationEnabled {
                        TextField("Destination name", text: $destinationName)
                        Button {
                            locationCapture.request()
                        } label: {
                            Label(locationCapture.isLocating ? "Finding destination..." : "Use Current Location", systemImage: "location.fill")
                        }
                        .disabled(locationCapture.isLocating)
                        if let latitude = destinationLatitude, let longitude = destinationLongitude {
                            Text("Saved at \(latitude, specifier: "%.4f"), \(longitude, specifier: "%.4f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose the destination from the parent device before saving.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Picker("Arrival radius", selection: $destinationRadiusMeters) {
                            Text("100 m").tag(100.0)
                            Text("200 m").tag(200.0)
                            Text("500 m").tag(500.0)
                        }
                        Picker("Leave reminder", selection: $destinationLeaveReminderMinutes) {
                            Text("At due time").tag(0)
                            Text("15 minutes before").tag(15)
                            Text("30 minutes before").tag(30)
                            Text("45 minutes before").tag(45)
                            Text("1 hour before").tag(60)
                        }
                    }
                    if let message = locationCapture.message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Location Reminders")
                } footer: {
                    Text("The child gets a reminder when their iPhone enters this destination. Location stays on the child’s device, and iOS may delay reminders. Timed reminders remain the fallback.")
                }

                if let chore {
                    Section {
                        Button {
                            isSaving = true
                            Task {
                                let saved = await store.setChorePaused(chore, isPaused: !chore.isPaused)
                                isSaving = false
                                if saved {
                                    dismiss()
                                }
                            }
                        } label: {
                            Label(
                                chore.isPaused ? "Resume Chore" : "Pause Chore",
                                systemImage: chore.isPaused ? "play.fill" : "pause.fill"
                            )
                        }
                        .disabled(isSaving)

                        Button(role: .destructive) {
                            isShowingArchiveConfirmation = true
                        } label: {
                            Label("Archive Chore", systemImage: "archivebox.fill")
                        }
                    } header: {
                        Text("Status")
                    } footer: {
                        Text("Pausing excuses any open instance. Archiving removes the chore from future schedules while keeping its history.")
                    }
                }

                if repeatFrequency == .weekly && weekdays.isEmpty {
                    Section {
                        Label("Choose at least one day.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.warmOrange)
                    }
                }

                if isSaving {
                    Section {
                        ProgressView(store.activeMutationTitle ?? "Saving chore...")
                    }
                }
            }
            .navigationTitle(chore == nil ? "Add Chore" : "Edit Chore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChore()
                    }
                    .disabled(saveDisabled || isSaving)
                }
            }
            .confirmationDialog(
                "Archive \(chore?.title ?? "this chore")?",
                isPresented: $isShowingArchiveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Archive Chore", role: .destructive) {
                    guard let chore else { return }
                    isSaving = true
                    Task {
                        let saved = await store.archiveChore(chore)
                        isSaving = false
                        if saved {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its completed history stays in allowance records, but it will no longer be scheduled.")
            }
            .onChange(of: locationCapture.coordinate?.latitude) { _, _ in
                guard let coordinate = locationCapture.coordinate else { return }
                destinationLatitude = coordinate.latitude
                destinationLongitude = coordinate.longitude
                if destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    destinationName = "Chore destination"
                }
            }
        }
    }

    private func saveChore() {
        guard let cents = Money.cents(fromDollarString: deduction),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let dueTimeLabel = Self.dueTimeFormatter.string(from: dueTime)
        let recurrence = selectedRecurrence
        isSaving = true

        Task {
            let saved: Bool
            if let chore {
                saved = await store.updateChore(
                    chore,
                    title: title,
                    description: description,
                    instructions: instructions,
                    expectedEvidence: expectedEvidence,
                    deductionCents: cents,
                    dueTime: dueTimeLabel,
                    recurrence: recurrence,
                    verificationMode: verificationMode,
                    blockPeopleInPhotos: blockPeopleInPhotos,
                    parentAlertEnabled: parentAlertEnabled,
                    parentAlertDelayMinutes: parentAlertDelayMinutes,
                    location: selectedLocation
                )
            } else {
                saved = await store.addChore(
                    id: draftChoreId,
                    title: title,
                    description: description,
                    instructions: instructions,
                    expectedEvidence: expectedEvidence,
                    deductionCents: cents,
                    dueTime: dueTimeLabel,
                    recurrence: recurrence,
                    verificationMode: verificationMode,
                    blockPeopleInPhotos: blockPeopleInPhotos,
                    parentAlertEnabled: parentAlertEnabled,
                    parentAlertDelayMinutes: parentAlertDelayMinutes,
                    location: selectedLocation
                )
            }
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }

    private var saveDisabled: Bool {
        Money.cents(fromDollarString: deduction) == nil
            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (repeatFrequency == .weekly && weekdays.isEmpty)
            || (locationEnabled && selectedLocation == nil)
    }

    private var selectedLocation: ChoreLocation? {
        guard locationEnabled,
              let latitude = destinationLatitude,
              let longitude = destinationLongitude,
              !destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ChoreLocation(
            name: destinationName,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: destinationRadiusMeters,
            leaveReminderMinutes: destinationLeaveReminderMinutes
        )
    }

    private var selectedRecurrence: ChoreRecurrence {
        switch repeatFrequency {
        case .once:
            let scheduledDate = Calendar.current.date(
                bySettingHour: Calendar.current.component(.hour, from: dueTime),
                minute: Calendar.current.component(.minute, from: dueTime),
                second: 0,
                of: oneTimeDate
            ) ?? oneTimeDate
            return ChoreRecurrence(frequency: .once, oneTimeDate: scheduledDate)
        case .daily:
            return .daily
        case .weekly:
            return ChoreRecurrence(frequency: .weekly, weekdays: Array(weekdays))
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 0) {
            ForEach(ChoreWeekday.allCases) { weekday in
                Button {
                    if weekdays.contains(weekday) {
                        weekdays.remove(weekday)
                    } else {
                        weekdays.insert(weekday)
                    }
                } label: {
                    Text(String(weekday.title.prefix(1)))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(weekdays.contains(weekday) ? Color.brandBlack : Color.inkBlack)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            weekdays.contains(weekday) ? Color.acidLime : Color.softGray,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekday.title)
                .accessibilityAddTraits(weekdays.contains(weekday) ? .isSelected : [])
            }
        }
        .frame(height: 40)
    }

    private static var currentWeekday: ChoreWeekday {
        ChoreWeekday(rawValue: Calendar.current.component(.weekday, from: Date())) ?? .monday
    }

    private static let dueTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.isLenient = true
        return formatter
    }()
}
