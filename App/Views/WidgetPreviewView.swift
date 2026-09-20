import SwiftUI

struct WidgetPreviewView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Static Widget Previews")
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(Color.inkBlack)

                LockScreenWidgetCard()
                    .environmentObject(store)

                HomeScreenWidgetCard()
                    .environmentObject(store)
            }
            .padding(22)
        }
        .background(Color.paperWhite.ignoresSafeArea())
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LockScreenWidgetCard: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Friday, May 24")
                .font(.subheadline)
                .foregroundStyle(Color.brandWhite.opacity(0.68))

            VStack(alignment: .leading, spacing: 4) {
                Text(Money.dollars(store.allowanceSummary.currentTotalCents))
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                Text("of \(Money.dollars(store.allowanceSummary.weeklyBaseCents))")
                    .font(.headline)
            }
            .foregroundStyle(Color.brandWhite)

            Text(store.remainingCount <= 2 ? "You're almost there!" : "Keep your full allowance.")
                .font(.subheadline)
                .foregroundStyle(Color.brandWhite.opacity(0.8))

            CapsuleProgress(value: store.allowanceSummary.progress)

            HStack {
                Image(systemName: "list.bullet")
                Text("\(store.remainingCount) chores left today")
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(Color.brandWhite)

            MascotCluster(scale: 0.52)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(y: 18)
                .frame(height: 54)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 292, alignment: .topLeading)
        .background(Color.brandBlack, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct HomeScreenWidgetCard: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.allowancePeriodTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.mutedGray)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Money.dollars(store.allowanceSummary.currentTotalCents))
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                        Text("/ \(Money.dollars(store.allowanceSummary.weeklyBaseCents))")
                            .font(.headline)
                            .foregroundStyle(Color.mutedGray)
                    }
                }

                Spacer()

                LimeMascot()
                    .frame(width: 72, height: 76)
            }

            AllowanceTrendChart(
                points: store.allowanceTrend,
                baseCents: store.allowanceSummary.weeklyBaseCents,
                endsAt: store.activeAllowancePeriod?.endsAt ?? Date(),
                tint: .inkBlack,
                compact: true,
                selectedDate: .constant(nil)
            )
            .frame(height: 54)

            Text("\(store.remainingCount) chores left")
                .font(.headline.weight(.heavy))

            if let next = store.nextDueOccurrence {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(Color.mutedGray)
                    Text("\(store.chore(for: next).title) · \(store.chore(for: next).dueTime)")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkBlack)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()
                    Circle()
                        .stroke(Color.mutedGray, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                }
            }

            MascotCluster(scale: 0.44)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(y: 24)
                .frame(height: 28)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 276, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.softGray, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
