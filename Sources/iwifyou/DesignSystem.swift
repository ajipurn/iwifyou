import AppKit
import IWiFiYouCore
import SwiftUI

/// Native macOS look: system materials, grouped forms, the user's accent
/// colour and semantic system colours. Brand appears only in the logo.
enum Brand {
    static let logoInk = Color(hex: 0x17181C)
    static let amber = Color(hex: 0xFFB020)
    static let accent = Color.accentColor
    static let good = Color.green
    static let warn = Color.orange
    static let bad = Color.red
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - Typography

extension Font {
    /// Manrope, bundled with the app (SIL OFL 1.1), at macOS text sizes.
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: size).weight(weight)
    }

    static func app(_ style: Font.TextStyle) -> Font {
        let (size, weight): (CGFloat, Font.Weight) = switch style {
        case .largeTitle: (26, .bold)
        case .title: (22, .bold)
        case .title2: (17, .bold)
        case .title3: (15, .semibold)
        case .headline: (13, .bold)
        case .subheadline: (11, .regular)
        case .callout: (12, .regular)
        case .footnote: (10.5, .regular)
        case .caption: (10.5, .regular)
        case .caption2: (10, .regular)
        default: (13, .regular)
        }
        return .custom("Manrope", size: size, relativeTo: style).weight(weight)
    }
}

// MARK: - Sections

extension MainSection {
    var group: String {
        switch self {
        case .status, .diagnosis: "Ringkasan"
        case .devices, .wlan, .channel, .network: "Jaringan rumah"
        case .security, .system: "Kontrol"
        }
    }
}

// MARK: - Components

/// A value row in a grouped form: label on the left, value on the right.
struct KeyValueRow: View {
    let label: String
    let value: String
    var tint: Color?

    var body: some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(tint ?? .secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// Coloured dot plus text, the way System Settings shows a state.
struct StatusLabel: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// A row of headline figures inside a form section.
struct MetricsRow: View {
    struct Metric: Identifiable {
        let label: String
        let value: String
        var unit: String?
        var color: Color?
        var id: String { label }
    }

    let metrics: [Metric]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 { Divider().frame(height: 40) }
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(metric.value).font(.app(size: 22, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(metric.color ?? .primary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let unit = metric.unit { Text(unit).font(.app(.callout)).foregroundStyle(.secondary) }
                    }
                    Text(metric.label).font(.app(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Shown on a screen whose data has not been read yet.
struct LoadPrompt: View {
    let model: AppModel
    let section: MainSection
    let detail: String
    let openSettings: () -> Void
    let load: () async -> Void

    var body: some View {
        if model.state.snapshot == nil {
            DisconnectedView(model: model, openSettings: openSettings)
        } else {
            ContentUnavailableView {
                Label(model.activeTask ?? section.title, systemImage: section.icon)
            } description: {
                Text(detail)
            } actions: {
                if model.activeTask == nil {
                    Button("Baca dari Router") { Task { await load() } }
                        .buttonStyle(.borderedProminent).disabled(model.isWorking)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

/// Inline result or error for the current screen.
struct AreaNotice: View {
    let model: AppModel
    let area: AppModel.RouterArea

    var body: some View {
        if let error = model.areaErrors[area] {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                .fixedSize(horizontal: false, vertical: true)
        } else if let message = model.areaMessages[area] {
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.good)
                .fixedSize(horizontal: false, vertical: true)
        } else if let task = model.activeTask {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(task).foregroundStyle(.secondary) }
        }
    }

    var isVisible: Bool { model.areaErrors[area] != nil || model.areaMessages[area] != nil || model.activeTask != nil }
}

extension View {
    /// Kept for small grouped surfaces outside forms (sheets, popovers).
    func card() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
