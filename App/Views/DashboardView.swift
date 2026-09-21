import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingReminderSettings = false

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
