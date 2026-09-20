import Foundation
import SwiftUI
import Charts

struct ChaChingWidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    var periodTitle: String
    var childName: String
    var currentCents: Int
    var baseCents: Int
    var rolloverDebtCents: Int
    var choresLeft: Int
    var nextChoreTitle: String
    var nextChoreTime: String
    var trend: [AllowanceTrendPoint]? = nil
    var periodEndsAt: Date? = nil

    var progress: Double {
        guard baseCents > 0 else { return 0 }
        return min(1, Double(currentCents) / Double(baseCents))
    }

    var hasRolloverDebt: Bool {
        rolloverDebtCents > 0
    }
}

struct AllowanceTrendPoint: Codable, Equatable {
    var date: Date
    var cents: Int
    var title: String
}

struct AllowanceTrendChart: View {
    var points: [AllowanceTrendPoint]
    var baseCents: Int
    var endsAt: Date
    var tint: Color
    var compact = false
    @Binding var selectedDate: Date?

    private var selectedPoint: AllowanceTrendPoint? {
        guard let selectedDate else { return nil }
        return points.last { $0.date <= selectedDate } ?? points.first
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Starting allowance", Double(baseCents) / 100))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Date", point.date), y: .value("Balance", Double(point.cents) / 100))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Balance", Double(last.cents) / 100))
                    .foregroundStyle(tint)
                    .symbolSize(compact ? 12 : 32)
            }
            if !compact, let selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                PointMark(x: .value("Selected", selectedPoint.date), y: .value("Balance", Double(selectedPoint.cents) / 100))
                    .foregroundStyle(tint)
                    .symbolSize(55)
            }
        }
        .chartXScale(domain: (points.first?.date ?? endsAt.addingTimeInterval(-1))...max(endsAt, (points.first?.date ?? endsAt).addingTimeInterval(1)))
        .chartYScale(domain: lowerBound...upperBound)
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartYAxis {
            if !compact {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                        }
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("Allowance balance trend")
        .accessibilityValue("Started at \(Double(baseCents) / 100, format: .currency(code: "USD")), currently \(Double(points.last?.cents ?? baseCents) / 100, format: .currency(code: "USD"))")
    }

    private var lowerBound: Double {
        let minimum = min(baseCents, points.map(\.cents).min() ?? baseCents)
        return Double(compact ? minimum : min(0, minimum)) / 100 - 0.5
    }

    private var upperBound: Double {
        Double(max(baseCents, points.map(\.cents).max() ?? baseCents)) / 100 + 1
    }
}

enum ChaChingWidgetSharedState {
    static let appGroupIdentifier = "group.com.artofsullivan.chaching"
    static let snapshotKey = "chaching.widget.allowanceSnapshot"
    static let widgetKind = "ChaChingAllowanceWidget"

    static func loadSnapshot() -> ChaChingWidgetSnapshot? {
        guard let data = sharedDefaults?.data(forKey: snapshotKey) else {
            return nil
        }

        return try? JSONDecoder().decode(ChaChingWidgetSnapshot.self, from: data)
    }

    @discardableResult
    static func saveSnapshot(_ snapshot: ChaChingWidgetSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot),
              let sharedDefaults else {
            return false
        }

        sharedDefaults.set(data, forKey: snapshotKey)
        return true
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }
}
