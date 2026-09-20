import SwiftUI
import UIKit
import WidgetKit

struct ChaChingAllowanceEntry: TimelineEntry {
    let date: Date
    let periodTitle: String
    let childName: String
    let currentCents: Int
    let baseCents: Int
    let rolloverDebtCents: Int
    let choresLeft: Int
    let nextChoreTitle: String
    let nextChoreTime: String
    var trend: [AllowanceTrendPoint] = []
    var periodEndsAt: Date? = nil

    var progress: Double {
        guard baseCents > 0 else { return 0 }
        return min(1, Double(currentCents) / Double(baseCents))
    }

    var hasRolloverDebt: Bool {
        rolloverDebtCents > 0
    }

    var choresLeftText: String {
        switch choresLeft {
        case 0:
            return "All chores done"
        case 1:
            return "1 chore left"
        default:
            return "\(choresLeft) chores left"
        }
    }
}

struct ChaChingAllowanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChaChingAllowanceEntry {
        sampleEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (ChaChingAllowanceEntry) -> Void) {
        completion(context.isPreview ? sampleEntry : currentEntry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChaChingAllowanceEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private var currentEntry: ChaChingAllowanceEntry {
        guard let snapshot = ChaChingWidgetSharedState.loadSnapshot() else {
            return sampleEntry
        }

        return ChaChingAllowanceEntry(
            date: snapshot.updatedAt,
            periodTitle: snapshot.periodTitle,
            childName: snapshot.childName,
            currentCents: snapshot.currentCents,
            baseCents: snapshot.baseCents,
            rolloverDebtCents: snapshot.rolloverDebtCents,
            choresLeft: snapshot.choresLeft,
            nextChoreTitle: snapshot.nextChoreTitle,
            nextChoreTime: snapshot.nextChoreTime,
            trend: snapshot.trend ?? [],
            periodEndsAt: snapshot.periodEndsAt
        )
    }

    private var sampleEntry: ChaChingAllowanceEntry {
        ChaChingAllowanceEntry(
            date: Date(),
            periodTitle: "This Week",
            childName: "Zoe",
            currentCents: 1_350,
            baseCents: 1_500,
            rolloverDebtCents: 0,
            choresLeft: 2,
            nextChoreTitle: "Take Dog Out",
            nextChoreTime: "8:00 PM",
            trend: [
                AllowanceTrendPoint(date: Date().addingTimeInterval(-4 * 86400), cents: 1500, title: "Starting allowance"),
                AllowanceTrendPoint(date: Date().addingTimeInterval(-3 * 86400), cents: 1400, title: "Deduction"),
                AllowanceTrendPoint(date: Date().addingTimeInterval(-2 * 86400), cents: 1600, title: "Bonus"),
                AllowanceTrendPoint(date: Date().addingTimeInterval(-86400), cents: 1350, title: "Deduction"),
                AllowanceTrendPoint(date: Date(), cents: 1350, title: "Current balance")
            ],
            periodEndsAt: Date().addingTimeInterval(2 * 86400)
        )
    }
}

struct ChaChingAllowanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: ChaChingAllowanceEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        default:
            mediumWidget
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.periodTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ccMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                LimeFace()
                    .frame(width: 24, height: 26)
            }

            Text(dollars(entry.currentCents))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ccInk)
                .minimumScaleFactor(0.72)

            miniTrend
                .frame(height: 30)

            Text(entry.choresLeftText)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Color.ccInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .padding(14)
        .containerBackground(Color.ccPaper, for: .widget)
    }

    private var mediumWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.childName) · \(entry.periodTitle)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ccMuted)
                        .lineLimit(1)
                    Text(dollars(entry.currentCents))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.ccInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Started \(dollars(entry.baseCents))")
                        .font(.caption2)
                        .foregroundStyle(Color.ccMuted)
                }
                miniTrend
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
            HStack(alignment: .top, spacing: 12) {
                Text(entry.choresLeftText)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color.ccInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Label("\(entry.nextChoreTitle) · \(entry.nextChoreTime)", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(Color.ccMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .containerBackground(Color.ccPaper, for: .widget)
    }

    private var accessoryCircular: some View {
        Gauge(value: entry.progress) {
            Text("Allowance")
        } currentValueLabel: {
            Text(dollars(entry.currentCents).replacingOccurrences(of: ".00", with: ""))
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    @ViewBuilder
    private var miniTrend: some View {
        if entry.trend.isEmpty {
            ProgressBar(value: entry.progress)
        } else {
            AllowanceTrendChart(
                points: entry.trend,
                baseCents: entry.baseCents,
                endsAt: entry.periodEndsAt ?? entry.date,
                tint: .ccInk,
                compact: true,
                selectedDate: .constant(nil)
            )
        }
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dollars(entry.currentCents))
                .font(.headline.weight(.heavy))
            Text(entry.choresLeftText)
            Text(entry.nextChoreTime)
        }
    }

    private func dollars(_ cents: Int) -> String {
        let value = Double(cents) / 100
        return value.formatted(.currency(code: "USD"))
    }
}

struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.ccSoft)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.ccSun, .ccLime],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: value <= 0 ? 0 : max(10, proxy.size.width * value))
            }
        }
        .frame(height: 10)
    }
}

struct LimeFace: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.ccLime)
                .rotationEffect(.degrees(8))

            VStack(spacing: 5) {
                HStack(spacing: 12) {
                    Circle().fill(Color.ccBrandBlack).frame(width: 4, height: 4)
                    Circle().fill(Color.ccBrandBlack).frame(width: 4, height: 4)
                }
                ArcSmile()
                    .stroke(Color.ccBrandBlack, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 8)
            }
            .offset(y: 4)
        }
    }
}

struct ArcSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

struct ChaChingAllowanceWidget: Widget {
    let kind = "ChaChingAllowanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ChaChingAllowanceProvider()) { entry in
            ChaChingAllowanceWidgetView(entry: entry)
        }
        .configurationDisplayName("ChaChing Allowance")
        .description("Check allowance progress and the next chore.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

@main
struct ChaChingWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChaChingAllowanceWidget()
    }
}

private extension Color {
    static let ccBrandBlack = Color(hex: "050505")
    static let ccInk = Color(lightHex: "050505", darkHex: "F5F5F2")
    static let ccPaper = Color(lightHex: "F8F7F2", darkHex: "171815")
    static let ccMuted = Color(lightHex: "777770", darkHex: "B6B6AE")
    static let ccSoft = Color(lightHex: "E9E9E5", darkHex: "383934")
    static let ccSun = Color(hex: "FFCC00")
    static let ccLime = Color(hex: "A8E600")

    init(lightHex: String, darkHex: String) {
        let light = UIColor(hex: lightHex)
        let dark = UIColor(hex: darkHex)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    init(hex: String) {
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
