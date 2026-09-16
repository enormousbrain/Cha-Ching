import MessageUI
import SwiftUI

struct EarningsView: View {
    @EnvironmentObject private var store: AppStore
    var allowsBonusActions: Bool = false
    @State private var showingBonusSheet = false
    @State private var showingMessageComposer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AllowanceCard(summary: store.allowanceSummary, periodTitle: store.allowancePeriodTitle, compact: true)

                summaryRows

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

                dailyBreakdown

                ledgerList
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

    private var summaryRows: some View {
        VStack(spacing: 0) {
            EarningsRow(title: "Starting allowance", value: Money.dollars(store.allowanceSummary.weeklyBaseCents), color: .inkBlack)
            EarningsRow(title: "Deductions", value: Money.dollars(-store.allowanceSummary.activeDeductionCents, signed: true), color: .warmOrange)
            EarningsRow(title: "Bonuses", value: Money.dollars(store.allowanceSummary.bonusCents, signed: true), color: .green)
            EarningsRow(title: "Adjustments", value: Money.dollars(store.allowanceSummary.adjustmentCents, signed: true), color: .mutedGray)
            if store.allowanceSummary.hasRolloverDebt {
                EarningsRow(title: "Rollover next period", value: Money.dollars(-store.allowanceSummary.rolloverDebtCents, signed: true), color: .warmOrange)
            }
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
    }

    private var dailyBreakdown: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily Breakdown")
                .font(.title3.weight(.heavy))

            VStack(spacing: 0) {
                ForEach(dayRows, id: \.day) { row in
                    HStack {
                        Text(row.day)
                            .font(.subheadline)
                        Spacer()
                        Text(row.value)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(row.color)
                    }
                    .padding(.vertical, 10)
                    if row.day != dayRows.last?.day {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
    }

    private var ledgerList: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ledger")
                .font(.title3.weight(.heavy))

            VStack(spacing: 0) {
                ForEach(store.ledger.sorted(by: { $0.createdAt > $1.createdAt })) { entry in
                    LedgerEntryRow(entry: entry)
                    if entry.id != store.ledger.sorted(by: { $0.createdAt > $1.createdAt }).last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.softGray, lineWidth: 1)
            )
        }
    }

    private var dayRows: [(day: String, value: String, color: Color)] {
        [
            ("Mon", "$3.00 / $3.00", .green),
            ("Tue", "$2.50 / $3.00", .warmOrange),
            ("Wed", "$3.00 / $3.00", .green),
            ("Thu", "$3.00 / $3.00", .green),
            ("Fri", "$2.00 / $3.00", .warmOrange),
            ("Sat", "-", .mutedGray),
            ("Sun", "-", .mutedGray)
        ]
    }
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
                            store.addBonus(title: title, amountCents: cents, note: note.isEmpty ? nil : note)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
