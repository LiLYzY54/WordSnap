import SwiftUI

/// GitHub 风格打卡格：近 16 周（112 天），按当日保存数分四级绿色。
struct HeatmapView: View {

    let counts: [String: Int]
    var weeks: Int = 16

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("近 \(weeks) 周 · \(activeDays) 天有记录")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<weeks, id: \.self) { column in
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { row in
                            let date = dateIn(column: column, row: row)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: date))
                                .frame(width: 11, height: 11)
                                .help("\(Self.dayFormatter.string(from: date)) · \(counts[Self.dayFormatter.string(from: date), default: 0]) 词")
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var activeDays: Int { counts.values.filter { $0 > 0 }.count }

    private func dateIn(column: Int, row: Int) -> Date {
        let totalDays = weeks * 7
        let daysAgo = totalDays - 1 - (column * 7 + row)
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    private func color(for date: Date) -> Color {
        let count = counts[Self.dayFormatter.string(from: date), default: 0]
        switch count {
        case 0: return .gray.opacity(0.18)
        case 1: return .green.opacity(0.4)
        case 2: return .green.opacity(0.65)
        default: return .green
        }
    }
}
