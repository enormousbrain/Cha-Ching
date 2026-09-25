import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingReminderSettings = false
    @State private var isShowingPlanning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                ZStack(alignment: .topTrailing) {
                    MascotCluster(scale: 0.78)
                        .offset(x: 36, y: -60)

                    AllowanceCard(summary: store.allowanceSummary, periodTitle: store.allowancePeriodTitle)
                        .padding(.top, 54)
                }

                quickStats

                if !store.activeChorePlans.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your plan").font(.headline)
                        ForEach(store.activeChorePlans) { plan in
                            NavigationLink { TaskDetailView(occurrenceId: plan.occurrenceId) } label: {
                                HStack {
                                    Image(systemName: "calendar.badge.checkmark")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(store.occurrences.first(where: { $0.id == plan.occurrenceId }).flatMap { store.chore(id: $0.choreDefinitionId)?.title } ?? "Chore")
                                        Text("Planned for \(plan.plannedFor.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }

                if !store.planningChoices.isEmpty {
                    Button { isShowingPlanning = true } label: {
                        Label("What do you want to handle next?", systemImage: "thought.bubble")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !store.awaitingReviewOccurrences.isEmpty {
                    Button {
                        store.showingCatchUp = true
                        store.reminderOccurrenceId = nil
                        store.reminderChoreIds = []
                    } label: {
                        Label("Awaiting review (\(store.awaitingReviewOccurrences.count))", systemImage: "clock")
                    }
                }

                if !store.catchUpOccurrences.isEmpty {
                    Button {
                        store.reminderOccurrenceId = nil
                        store.showingCatchUp = true
                        store.reminderChoreIds = Array(Set(store.catchUpOccurrences.map(\.choreDefinitionId)))
                    } label: {
                        Label("Catch up on \(store.catchUpOccurrences.count) missed \(store.catchUpOccurrences.count == 1 ? "chore" : "chores")", systemImage: "arrow.uturn.forward.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.warmOrange)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Today's Chores")
                            .font(.title3.weight(.heavy))
                        Spacer()
                        Text("\(store.remainingCount) left")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.mutedGray)
                    }

                    VStack(spacing: 10) {
                        ForEach(store.todayOccurrences) { occurrence in
                            NavigationLink {
                                TaskDetailView(occurrenceId: occurrence.id)
                            } label: {
                                TaskRow(
                                    occurrence: occurrence,
                                    chore: store.chore(for: occurrence),
                                    submission: store.submission(for: occurrence)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .refreshable {
            await store.refreshRemoteFamilyState()
        }
        .navigationTitle(AppBrand.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarLeading) {
                DevelopmentSessionMenu()
            }
            #endif

            ToolbarItemGroup(placement: .topBarTrailing) {
                GoldStarButton()
                NavigationLink {
                    PrivacyAccountView()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Privacy and Account")
                RemoteRefreshButton()

                Button {
                    isShowingReminderSettings = true
                } label: {
                    Image(systemName: "bell")
                        .font(.headline)
                }
                .accessibilityLabel("Notifications")
            }
        }
        .sheet(isPresented: $isShowingReminderSettings) {
            ReminderSettingsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $isShowingPlanning) { WhatsNextCheckInView().environmentObject(store) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hey, \(store.childName)!")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("You're doing great.")
                    .font(.subheadline)
                    .foregroundStyle(Color.mutedGray)
            }

            Spacer()

            ZStack {
                Circle()
                    .fill(Color.sunYellow)
                    .frame(width: 58, height: 58)
                Image(systemName: "sparkle")
                    .font(.title2.weight(.black))
                    .foregroundStyle(Color.brandBlack)
            }
            .accessibilityHidden(true)
        }
        .padding(.top, 8)
    }

    private var quickStats: some View {
        HStack(spacing: 10) {
            StatChip(
                title: "Started",
                value: Money.dollars(store.allowanceSummary.weeklyBaseCents),
                color: .sunYellow
            )
            StatChip(
                title: "Deductions",
                value: Money.dollars(-store.allowanceSummary.activeDeductionCents, signed: true),
                color: .warmOrange
            )
            StatChip(
                title: "Bonuses",
                value: Money.dollars(store.allowanceSummary.bonusCents, signed: true),
                color: .acidLime
            )
        }
    }
}

struct GoldStarButton: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationLink { InitiativeStarsView() } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.fill").foregroundStyle(Color.yellow)
                Text(store.starBalance, format: .number).monospacedDigit()
            }
            .font(.subheadline.weight(.bold))
        }
        .accessibilityLabel("\(store.starBalance) gold stars")
    }
}

struct InitiativeStarsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingAward = false
    @State private var selectedCredit: TaskOccurrence?
    @State private var requestID = UUID()
    @State private var approvingRequest: StarCreditRequest?

    private var pending: [StarCreditRequest] { store.starCreditRequests.filter { $0.status == "pending" } }

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label("\(store.starBalance)", systemImage: "star.fill")
                        .font(.largeTitle.bold()).foregroundStyle(Color.yellow)
                    Text("Gold stars").font(.headline)
                }
                if store.isParentSession {
                    Button { showingAward = true } label: { Label("Recognize initiative", systemImage: "star.badge.plus") }
                }
            } header: { Text(store.childName) }

            if !pending.isEmpty {
                Section("Credit requests") {
                    ForEach(pending) { request in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(choreTitle(request.occurrenceId)).font(.headline)
                            Text("5 stars · \(store.isParentSession ? "Awaiting your decision" : "Waiting for a parent")")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if store.isParentSession {
                                HStack {
                                    Button { approvingRequest = request } label: { Label("Approve", systemImage: "checkmark.circle") }
                                        .disabled(store.starBalance < InitiativeStars.creditCost)
                                    Spacer()
                                    Button(role: .destructive) {
                                        Task { _ = await store.decideStarCredit(request, approve: false) }
                                    } label: { Label("Decline", systemImage: "xmark.circle") }
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section {
                Text("5 stars = one missed-chore credit").font(.headline)
                Text("Parent approval required. A credit clears a deduction, not the responsibility.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.starBalance < InitiativeStars.creditCost {
                    Text("\(InitiativeStars.creditCost - store.starBalance) more stars to a credit")
                        .foregroundStyle(.secondary)
                } else if store.starCreditEligibleOccurrences.isEmpty {
                    Text("No eligible missed deductions").foregroundStyle(.secondary)
                } else {
                    ForEach(store.starCreditEligibleOccurrences) { occurrence in
                        Button { selectedCredit = occurrence } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choreTitle(occurrence.id))
                                Text(occurrence.dueAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: { Text("A little flexibility") }

            Section("Ways to show initiative") {
                Label("Notice what needs doing", systemImage: "eye")
                Label("Make a plan and follow through", systemImage: "calendar.badge.checkmark")
                Label("Prepare ahead when it makes sense", systemImage: "checklist")
            }

            Section("Recent recognition") {
                if store.initiativeStars.isEmpty {
                    Text("Small steps toward doing things on your own.").foregroundStyle(.secondary)
                }
                ForEach(store.initiativeStars) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.amount > 0 ? "star.fill" : "arrow.uturn.backward.circle")
                            .foregroundStyle(entry.amount > 0 ? Color.yellow : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.reason)
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.amount > 0 ? "+\(entry.amount)" : "\(entry.amount)").monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Gold Stars")
        .disabled(store.isMutationInFlight)
        .refreshable { await store.refreshRemoteFamilyState() }
        .sheet(isPresented: $showingAward) { AwardInitiativeStarSheet().environmentObject(store) }
        .confirmationDialog("Request a missed-chore credit?", isPresented: Binding(
            get: { selectedCredit != nil }, set: { if !$0 { selectedCredit = nil } }
        ), titleVisibility: .visible) {
            if let occurrence = selectedCredit {
                Button("Request credit for 5 stars") {
                    Task {
                        if await store.requestStarCredit(id: requestID, occurrenceId: occurrence.id) { requestID = UUID() }
                    }
                }
            }
        } message: { Text("Stars are only spent if a parent approves. They can decline responsibilities that should not be credited.") }
        .confirmationDialog("Approve this credit?", isPresented: Binding(
            get: { approvingRequest != nil }, set: { if !$0 { approvingRequest = nil } }
        ), titleVisibility: .visible) {
            if let request = approvingRequest {
                Button("Spend 5 stars and clear deduction") { Task { _ = await store.decideStarCredit(request, approve: true) } }
            }
        } message: { Text("This does not mark the chore completed. Approve only when a credit is appropriate for this responsibility.") }
        .id(store.childId)
    }

    private func choreTitle(_ occurrenceID: UUID) -> String {
        guard let occurrence = store.occurrences.first(where: { $0.id == occurrenceID }) else { return "Missed chore" }
        return store.chore(id: occurrence.choreDefinitionId)?.title ?? "Archived chore"
    }
}

struct AwardInitiativeStarSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var awardID = UUID()
    @State private var reason = InitiativeStars.recognitionReasons[0]
    @State private var occurrenceID: UUID?

    init(occurrenceId: UUID? = nil) {
        _occurrenceID = State(initialValue: occurrenceId)
        _reason = State(initialValue: InitiativeStars.recognitionReasons[occurrenceId == nil ? 0 : 1])
    }

    private var approved: [TaskOccurrence] {
        store.occurrences.filter { occurrence in
            occurrence.childId == store.childId && occurrence.status == .approved
                && !store.initiativeStars.contains { $0.occurrenceId == occurrence.id && $0.amount > 0 }
        }.sorted { $0.dueAt > $1.dueAt }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What did \(store.childName) do independently?") {
                    ForEach(InitiativeStars.recognitionReasons, id: \.self) { suggestion in
                        Button { reason = suggestion } label: {
                            HStack {
                                Text(suggestion).foregroundStyle(.primary)
                                Spacer()
                                if reason == suggestion { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                            }
                        }
                    }
                    TextField("Recognition", text: $reason, axis: .vertical)
                }
                Section("Related chore") {
                    Picker("Chore", selection: $occurrenceID) {
                        Text("Everyday initiative").tag(UUID?.none)
                        ForEach(approved) { occurrence in
                            Text("\(store.chore(id: occurrence.choreDefinitionId)?.shortTitle ?? "Chore") · \(occurrence.dueAt.formatted(date: .abbreviated, time: .shortened))")
                                .tag(Optional(occurrence.id))
                        }
                    }
                }
                Section {
                    Button {
                        Task { if await store.awardStar(id: awardID, reason: reason, occurrenceId: occurrenceID) { dismiss() } }
                    } label: { Label("Award one star", systemImage: "star.fill") }
                        .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reason.count > 240 || store.isMutationInFlight)
                }
            }
            .navigationTitle("Recognize Initiative")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled(store.isMutationInFlight)
    }
}

struct WhatsNextCheckInView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: TaskOccurrence?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.planningChoices) { occurrence in
                        Button { selected = occurrence } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "circle").accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.chore(id: occurrence.choreDefinitionId)?.title ?? "Chore").font(.headline)
                                    Text("Due \(occurrence.dueAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }.foregroundStyle(.primary)
                        }
                    }
                    if store.planningChoices.isEmpty { Text("Nothing else to plan right now.").foregroundStyle(.secondary) }
                } header: { Text("What do you want to handle next?") }
                Section {
                    Button("Not now") { dismiss() }
                }
            }
            .navigationTitle("What's Next?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(item: $selected) { occurrence in
                ChorePlanEditor(occurrence: occurrence) { dismiss() }.environmentObject(store)
            }
        }
    }
}

struct ChorePlanEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let occurrence: TaskOccurrence
    var onSaved: () -> Void = {}
    @State private var timing = "now"
    @State private var customTime = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(store.chore(id: occurrence.choreDefinitionId)?.title ?? "Chore").font(.headline)
                    Text("Due \(occurrence.dueAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                }
                if occurrence.dueAt > Date() {
                    Section("When will you handle it?") {
                        Picker("Time", selection: $timing) {
                            Text("Now").tag("now")
                            Text("At the due time").tag("due")
                            Text("Choose a time").tag("custom")
                        }
                        if timing == "custom" {
                            DatePicker("My time", selection: $customTime, in: min(Date(), occurrence.dueAt)...occurrence.dueAt, displayedComponents: [.hourAndMinute])
                        }
                    }
                    Section {
                        Button {
                            let date = timing == "now" ? Date() : timing == "due" ? occurrence.dueAt : customTime
                            Task {
                                if await store.saveChorePlan(occurrenceId: occurrence.id, plannedFor: date) { dismiss(); onSaved() }
                            }
                        } label: { Label("Save my plan", systemImage: "calendar.badge.checkmark") }
                    }
                } else {
                    Text("This chore is due now. You can still open it from your chore list.").foregroundStyle(.secondary)
                }
            }
            .disabled(store.isMutationInFlight)
            .navigationTitle("My Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if let plan = store.chorePlans.first(where: { $0.occurrenceId == occurrence.id && $0.cancelledAt == nil }) {
                    customTime = min(occurrence.dueAt, max(Date(), plan.plannedFor))
                    timing = "custom"
                } else { customTime = min(occurrence.dueAt, Date().addingTimeInterval(900)) }
            }
        }
        .interactiveDismissDisabled(store.isMutationInFlight)
    }
}

struct StatChip: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.mutedGray)
            Text(value)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.inkBlack)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

struct TaskRow: View {
    var occurrence: TaskOccurrence
    var chore: ChoreDefinition
    var submission: ChoreSubmission?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 5) {
                Text(chore.title)
                    .font(.headline)
                    .foregroundStyle(Color.inkBlack)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    Text(statusText)
                    Text("Due \(chore.dueTime)")
                }
                .font(.caption)
                .foregroundStyle(Color.mutedGray)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text("Miss it")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.mutedGray)
                Text(Money.dollars(-chore.deductionCents, signed: true))
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(occurrence.status == .missed || occurrence.status == .rejected ? Color.warmOrange : Color.inkBlack)
            }
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: 34, height: 34)
            Image(systemName: iconName)
                .font(.caption.weight(.black))
                .foregroundStyle(Color.inkBlack)
        }
    }

    private var statusText: String {
        switch occurrence.status {
        case .approved:
            return "Protected"
        case .aiReviewed:
            let confidence = submission?.aiResult.map { Int($0.confidence * 100) } ?? 0
            return "AI \(confidence)%"
        case .submitted:
            return "Submitted"
        case .due:
            return "Due now"
        case .upcoming:
            return "Coming up"
        case .missed:
            return "Missed"
        case .rejected:
            return "Needs redo"
        case .excused:
            return "Excused"
        }
    }

    private var iconName: String {
        switch occurrence.status {
        case .approved:
            return "checkmark"
        case .aiReviewed, .submitted:
            return "sparkles"
        case .due:
            return "camera.fill"
        case .upcoming:
            return "circle"
        case .missed, .rejected:
            return "minus"
        case .excused:
            return "hand.raised.fill"
        }
    }

    private var iconBackground: Color {
        switch occurrence.status {
        case .approved:
            return .acidLime
        case .aiReviewed, .submitted:
            return .sunYellow
        case .due:
            return .hotPink.opacity(0.7)
        case .upcoming:
            return .softGray
        case .missed, .rejected:
            return .warmOrange.opacity(0.75)
        case .excused:
            return .electricBlue.opacity(0.35)
        }
    }

    private var borderColor: Color {
        switch occurrence.status {
        case .due:
            return .sunYellow
        case .aiReviewed, .submitted:
            return .acidLime
        case .missed, .rejected:
            return .warmOrange
        default:
            return .softGray
        }
    }
}
