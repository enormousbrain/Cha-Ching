import MessageUI
import SwiftUI

struct EarningsView: View {
    @EnvironmentObject private var store: AppStore
    var allowsBonusActions: Bool = false
    @State private var showingBonusSheet = false
    @State private var showingMessageComposer = false
    @State private var selectedSection: EarningsSection

    private enum EarningsSection: String, CaseIterable, Identifiable {
        case current = "Current"
        case history = "History"

        var id: String { rawValue }
    }

    init(allowsBonusActions: Bool = false) {
        self.allowsBonusActions = allowsBonusActions
        let launchSection = ProcessInfo.processInfo.environment["CHACHING_EARNINGS_SECTION"]
        _selectedSection = State(
            initialValue: launchSection == "history" ? .history : .current
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Earnings view", selection: $selectedSection) {
                    ForEach(EarningsSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedSection {
                case .current:
                    currentPeriodContent
                case .history:
                    AllowanceHistoryView(periods: store.archivedAllowancePeriods)
                }
            }
            .padding(22)
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("Earnings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingBonusSheet) {
            AddBonusSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showingMessageComposer) {
            MessageComposerView(body: store.allowanceRequestMessage)
        }
    }

    @ViewBuilder
    private var currentPeriodContent: some View {
        if let period = store.activeAllowancePeriod {
            AllowanceCard(
                summary: store.allowanceSummary,
                periodTitle: store.allowancePeriodTitle,
                compact: true
            )

            PeriodDateRange(period: period)
            AllowanceTrajectoryView()
            AllowanceSummaryRows(summary: store.allowanceSummary)

            if !allowsBonusActions {
                AllowanceRequestCard(
                    summary: store.allowanceSummary,
                    nextAllowanceDate: store.nextAllowanceDate,
                    messageBody: store.allowanceRequestMessage
                ) {
                    showingMessageComposer = true
                }
            }

            if allowsBonusActions {
                Button {
                    showingBonusSheet = true
                } label: {
                    Label("Add Bonus", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            AllowanceDailyActivityView(period: period)
            AllowanceLedgerView(entries: store.ledger)
        } else {
            ContentUnavailableView(
                "No Allowance Period",
                systemImage: "calendar.badge.exclamationmark",
                description: Text("Pull to refresh after your family finishes setup.")
            )
        }
    }
}

struct AllowanceTrajectoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedDate: Date?
    var compact = false

    private var selectedPoint: AllowanceTrendPoint? {
        guard let selectedDate else { return nil }
        return store.allowanceTrend.last { $0.date <= selectedDate } ?? store.allowanceTrend.first
    }

    var body: some View {
        let summary = store.allowanceSummary
        let change = summary.currentTotalCents - summary.rolloverDebtCents - summary.weeklyBaseCents
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Money.dollars(selectedPoint?.cents ?? summary.currentTotalCents))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Spacer()
                Label(Money.dollars(change, signed: true), systemImage: change > 0 ? "arrow.up.right" : change < 0 ? "arrow.down.right" : "minus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(change < 0 ? Color.warmOrange : Color.inkBlack)
            }
            Text(selectedPoint.map { "\($0.title) · \($0.date.formatted(date: .abbreviated, time: .shortened))" }
                 ?? "Started with \(Money.dollars(summary.weeklyBaseCents))")
                .font(.caption)
                .foregroundStyle(Color.mutedGray)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)

            if let period = store.activeAllowancePeriod {
                AllowanceTrendChart(
                    points: store.allowanceTrend,
                    baseCents: summary.weeklyBaseCents,
                    endsAt: period.endsAt,
                    tint: .inkBlack,
                    selectedDate: $selectedDate
                )
                .frame(height: compact ? 110 : 150)
            }

            HStack(spacing: 18) {
                Label("\(Money.dollars(summary.bonusCents)) bonuses", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.inkBlack)
                Label("\(Money.dollars(summary.activeDeductionCents)) deductions", systemImage: "minus.circle.fill")
                    .foregroundStyle(Color.warmOrange)
            }
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

            if summary.hasRolloverDebt {
                Text("Payout is $0.00. \(Money.dollars(summary.rolloverDebtCents)) carries into next period.")
                    .font(.caption).foregroundStyle(Color.mutedGray)
            }
        }
        .foregroundStyle(Color.inkBlack)
    }
}

private struct AllowanceHistoryView: View {
    var periods: [AllowancePeriod]
    @State private var showingFirstPeriodForQA = ProcessInfo.processInfo.environment["CHACHING_EARNINGS_DETAIL"] == "1"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Past Periods")
                    .font(.title3.weight(.heavy))
                Spacer()
                Text("\(periods.count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.mutedGray)
            }

            if periods.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed allowance periods will appear here.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(periods) { period in
                    NavigationLink {
                        AllowancePeriodDetailView(period: period)
                    } label: {
                        AllowancePeriodHistoryRow(period: period)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationDestination(isPresented: $showingFirstPeriodForQA) {
            if let period = periods.first {
                AllowancePeriodDetailView(period: period)
            }
        }
        .onAppear {
            if periods.isEmpty {
                showingFirstPeriodForQA = false
            }
        }
    }
}

private struct AllowancePeriodHistoryRow: View {
    var period: AllowancePeriod

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(periodDateRange(period))
                    .font(.headline)
                    .foregroundStyle(Color.inkBlack)

                Text(periodActivitySummary(period.summary))
                    .font(.caption)
                    .foregroundStyle(Color.mutedGray)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                Text(Money.dollars(period.displayedBalanceCents))
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color.inkBlack)
                Text("Final")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.mutedGray)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.mutedGray)
        }
        .padding(16)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

private struct AllowancePeriodDetailView: View {
    var period: AllowancePeriod

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Final Balance")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.brandWhite.opacity(0.8))
                    Text(Money.dollars(period.displayedBalanceCents))
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.brandWhite)
                    Text(periodDateRange(period))
                        .font(.subheadline)
                        .foregroundStyle(Color.brandWhite.opacity(0.72))
                    if period.summary.hasRolloverDebt {
                        Label(
                            "\(Money.dollars(period.summary.rolloverDebtCents)) carried into the next period",
                            systemImage: "arrow.forward.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.sunYellow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.brandBlack, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                AllowanceSummaryRows(
                    summary: period.summary,
                    closeoutAdjustmentCents: period.closeoutAdjustmentCents
                )
                AllowanceDailyActivityView(period: period)
                AllowanceLedgerView(entries: period.entries)
            }
            .padding(22)
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("Period Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PeriodDateRange: View {
    var period: AllowancePeriod

    var body: some View {
        Label(periodDateRange(period), systemImage: "calendar")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.mutedGray)
    }
}

private struct AllowanceSummaryRows: View {
    var summary: AllowanceSummary
    var closeoutAdjustmentCents: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            EarningsRow(title: "Starting allowance", value: Money.dollars(summary.weeklyBaseCents), color: .inkBlack)
            EarningsRow(title: "Deductions", value: Money.dollars(-summary.activeDeductionCents, signed: true), color: .warmOrange)
            EarningsRow(title: "Bonuses", value: Money.dollars(summary.bonusCents, signed: true), color: .green)
            EarningsRow(title: "Adjustments", value: Money.dollars(summary.adjustmentCents, signed: true), color: .mutedGray)
            if let closeoutAdjustmentCents {
                EarningsRow(
                    title: "Closeout adjustment",
                    value: Money.dollars(closeoutAdjustmentCents, signed: true),
                    color: closeoutAdjustmentCents < 0 ? .warmOrange : .green
                )
            }
            if summary.hasRolloverDebt {
                EarningsRow(title: "Rollover next period", value: Money.dollars(-summary.rolloverDebtCents, signed: true), color: .warmOrange)
            }
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

private struct AllowanceDailyActivityView: View {
    var period: AllowancePeriod

    private var rows: [AllowanceDayActivity] {
        AllowanceEngine.dailyActivity(
            for: period.entries,
            from: period.startsAt,
            to: period.endsAt
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily Activity")
                .font(.title3.weight(.heavy))

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.inkBlack)
                            Text(dayActivityDescription(row))
                                .font(.caption)
                                .foregroundStyle(Color.mutedGray)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Text(dayActivityAmount(row))
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(dayActivityColor(row))
                    }
                    .padding(.vertical, 11)

                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
    }
}

private struct AllowanceLedgerView: View {
    var entries: [LedgerEntry]

    private var sortedEntries: [LedgerEntry] {
        entries.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ledger")
                    .font(.title3.weight(.heavy))
                Spacer()
                Text("\(entries.count) entries")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.mutedGray)
            }

            VStack(spacing: 0) {
                if sortedEntries.isEmpty {
                    Text("No ledger entries for this period.")
                        .font(.subheadline)
                        .foregroundStyle(Color.mutedGray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                } else {
                    ForEach(Array(sortedEntries.enumerated()), id: \.element.id) { index, entry in
                        LedgerEntryRow(entry: entry)
                        if index < sortedEntries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
    }
}

private func periodDateRange(_ period: AllowancePeriod) -> String {
    let inclusiveEnd = period.endsAt.addingTimeInterval(-1)
    return "\(period.startsAt.formatted(.dateTime.month(.abbreviated).day())) - \(inclusiveEnd.formatted(.dateTime.month(.abbreviated).day().year()))"
}

private func periodActivitySummary(_ summary: AllowanceSummary) -> String {
    var parts: [String] = []
    if summary.activeDeductionCents > 0 {
        parts.append("\(Money.dollars(summary.activeDeductionCents)) deducted")
    }
    if summary.bonusCents > 0 {
        parts.append("\(Money.dollars(summary.bonusCents)) bonus")
    }
    if summary.rolloverDebtCents > 0 {
        parts.append("\(Money.dollars(summary.rolloverDebtCents)) rolled forward")
    }
    return parts.isEmpty ? "No adjustments" : parts.joined(separator: " / ")
}

private func dayActivityDescription(_ row: AllowanceDayActivity) -> String {
    var parts: [String] = []
    if row.startingAllowanceCents > 0 {
        parts.append("Started \(Money.dollars(row.startingAllowanceCents))")
    }
    if row.deductionCents > 0 {
        parts.append("\(Money.dollars(row.deductionCents)) deducted")
    }
    if row.bonusCents > 0 {
        parts.append("\(Money.dollars(row.bonusCents)) bonus")
    }
    if row.adjustmentCents != 0 {
        parts.append("\(Money.dollars(row.adjustmentCents)) adjusted")
    }
    if row.excusedDeductionCents > 0 {
        parts.append("\(Money.dollars(row.excusedDeductionCents)) excused")
    }
    return parts.isEmpty ? "No changes" : parts.joined(separator: " / ")
}

private func dayActivityAmount(_ row: AllowanceDayActivity) -> String {
    guard row.hasActivity else {
        return "-"
    }
    return Money.dollars(row.netChangeCents, signed: row.netChangeCents != row.startingAllowanceCents)
}

private func dayActivityColor(_ row: AllowanceDayActivity) -> Color {
    if !row.hasActivity || row.netChangeCents == 0 {
        return .mutedGray
    }
    if row.netChangeCents < 0 {
        return .warmOrange
    }
    if row.bonusCents > 0 || row.adjustmentCents > 0 {
        return .green
    }
    return .inkBlack
}

struct AllowanceRequestCard: View {
    var summary: AllowanceSummary
    var nextAllowanceDate: Date
    var messageBody: String
    var onRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allowance Day", systemImage: "party.popper.fill")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color.inkBlack)

            VStack(alignment: .leading, spacing: 6) {
                Text(summary.hasRolloverDebt ? "This period closes at $0.00" : "You earned \(Money.dollars(summary.currentTotalCents))")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.inkBlack)

                Text(summary.hasRolloverDebt ? "Next period starts reduced by \(Money.dollars(summary.rolloverDebtCents))." : "Next allowance day is \(nextAllowanceDate.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.subheadline)
                    .foregroundStyle(Color.mutedGray)
            }

            if MFMessageComposeViewController.canSendText() {
                Button(action: onRequest) {
                    Label("Message Parent", systemImage: "message.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ShareLink(item: messageBody) {
                    Label("Share Request", systemImage: "square.and.arrow.up.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(Color.brandBlack)
                        .background(Color.acidLime, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }
}

struct MessageComposerView: UIViewControllerRepresentable {
    var body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    final class Coordinator: NSObject, @MainActor MFMessageComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        @MainActor func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            dismiss()
        }
    }
}

struct EarningsRow: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.inkBlack)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

struct LedgerEntryRow: View {
    var entry: LedgerEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(entry.isVoided ? Color.mutedGray : Color.inkBlack)
                    if entry.isVoided {
                        Text("Voided")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.softGray, in: Capsule())
                    }
                }

                if let note = entry.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Color.mutedGray)
                }

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.mutedGray)
            }

            Spacer()

            Text(displayAmount)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 12)
        .opacity(entry.isVoided ? 0.55 : 1)
    }

    private var displayAmount: String {
        switch entry.type {
        case .weeklyBase:
            return Money.dollars(entry.amountCents)
        case .deduction:
            return Money.dollars(-entry.amountCents, signed: true)
        case .bonus, .adjustment:
            return Money.dollars(entry.amountCents, signed: true)
        }
    }

    private var amountColor: Color {
        switch entry.type {
        case .deduction:
            return .warmOrange
        case .bonus:
            return .green
        case .weeklyBase, .adjustment:
            return .inkBlack
        }
    }

    private var dotColor: Color {
        switch entry.type {
        case .weeklyBase:
            return .sunYellow
        case .deduction:
            return .warmOrange
        case .bonus:
            return .acidLime
        case .adjustment:
            return .electricBlue.opacity(0.45)
        }
    }
}

struct AddBonusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var title = "Helped without being asked"
    @State private var amount = "2.00"
    @State private var note = ""
    @State private var isSaving = false
    @State private var entryId = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if isSaving {
                    Section {
                        ProgressView("Saving bonus...")
                    }
                }
            }
            .navigationTitle("Add Bonus")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let cents = Money.cents(fromDollarString: amount), !title.isEmpty {
                            isSaving = true
                            Task {
                                let saved = await store.addBonus(
                                    id: entryId,
                                    title: title,
                                    amountCents: cents,
                                    note: note.isEmpty ? nil : note
                                )
                                isSaving = false
                                if saved {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}
