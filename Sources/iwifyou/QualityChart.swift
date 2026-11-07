import Charts
import IWiFiYouCore
import SwiftUI

struct QualityChart: View {
    let qualities: [ChannelQuality]
    let recommended: Int?
    let highlighted: Int?

    private var ceiling: Double { max(2.4, (qualities.map(\.load).max() ?? 0) * 1.15) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                ForEach([ChannelQuality.Level.good, .fair, .busy], id: \.self) { level in
                    HStack(spacing: 4) {
                        Circle().fill(level.color).frame(width: 7, height: 7)
                        Text(level.label).font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
            Chart(qualities) { quality in
                BarMark(
                    x: .value("Channel", String(quality.channel)),
                    // A sliver keeps empty channels visible as a baseline.
                    y: .value("Gangguan", max(quality.load, ceiling * 0.015))
                )
                .foregroundStyle(quality.level.color)
                .opacity(highlighted == nil || highlighted == quality.channel ? 1 : 0.45)
                .cornerRadius(4)
                .annotation(position: .top, spacing: 4) {
                    if quality.channel == recommended {
                        Image(systemName: "star.fill").font(.app(size: 10)).foregroundStyle(Brand.accent)
                            .accessibilityLabel("Disarankan")
                    }
                }
            }
            .chartYScale(domain: 0...ceiling)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.6, 1.6]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(number < 1 ? "sedang" : "padat") }
                    }
                }
            }
            .chartXAxisLabel("Channel", alignment: .center)
            .frame(height: 190)
            .accessibilityLabel("Grafik gangguan per channel")
            Text("Tinggi batang = perkiraan gangguan dari jaringan lain yang memakai channel sama atau bertumpuk. Makin rendah makin lega.")
                .font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
