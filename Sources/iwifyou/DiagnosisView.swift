import Charts
import IWiFiYouCore
import Observation
import SwiftUI

@Observable
final class DiagnosisModel {
    struct RouterSide: Sendable {
        var wanConnected: Bool?
        var fiber: FiberPower?
        var note: String?
    }

    private(set) var isRunning = false
    private(set) var link: WiFiLink?
    private(set) var gateway: PingResult?
    private(set) var internet: PingResult?
    private(set) var dnsWorks: Bool?
    private(set) var router: RouterSide?
    private(set) var verdict: DiagnosisVerdict?
    private(set) var finished: Date?
    private(set) var stage = ""
    let isDemo: Bool

    init(demo: Bool) { isDemo = demo }

    /// Only the router address the user configured, a public anycast
    /// resolver and a DNS lookup are probed; nothing else leaves the Mac.
    func run(routerHost: String, routerSide: () async -> RouterSide) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; stage = "" }
        verdict = nil
        gateway = nil
        internet = nil
        dnsWorks = nil
        router = nil
        if isDemo {
            stage = "Mengukur…"
            try? await Task.sleep(for: .milliseconds(900))
            link = WiFiLink(rssi: -61, noise: -92, transmitRate: 144, channel: 6, band: "2,4 GHz", widthMHz: 20, standard: "Wi-Fi 4 (802.11n)")
            gateway = PingResult(sent: 10, received: 10, average: 4.2, jitter: 2.1)
            internet = PingResult(sent: 10, received: 10, average: 18.5, jitter: 3.4)
            dnsWorks = true
            router = RouterSide(wanConnected: true, fiber: FiberPower(rx: -21.4, tx: 2.3))
        } else {
            stage = "Membaca Wi-Fi Mac…"
            link = WiFiLink.current()
            stage = "Ping router, internet, dan DNS…"
            async let gatewayPing = Pinger.ping(routerHost)
            async let internetPing = Pinger.ping("1.1.1.1")
            async let dns = Pinger.resolves("apple.com")
            (gateway, internet, dnsWorks) = await (gatewayPing, internetPing, dns)
            stage = "Membaca status WAN dan redaman…"
            router = await routerSide()
        }
        verdict = NetworkDiagnosis.evaluate(DiagnosisInput(
            onWiFi: link != nil, rssi: link?.rssi, gateway: gateway, internet: internet,
            dnsWorks: dnsWorks, wanConnected: router?.wanConnected, fiber: router?.fiber
        ))
        finished = .now
    }
}

struct DiagnosisView: View {
    @Bindable var model: AppModel
    let diagnosis: DiagnosisModel
    let meter: SignalMeter

    var body: some View {
        Form {
            Section { verdictCard.padding(.vertical, 4) }
            if diagnosis.finished != nil || diagnosis.isRunning {
                Section("Hasil Pemeriksaan") { checks }
            }
            Section {
                SignalMeterCard(meter: meter).padding(.vertical, 4)
            } header: {
                Text("Meter Sinyal Live")
            } footer: {
                Text("Bawa Mac berkeliling untuk mencari titik terbaik. Di atas −67 dBm baik untuk video call dan streaming; di bawah −75 dBm koneksi mudah putus.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
    }

    private var verdictCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(color)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(diagnosis.verdict?.title ?? (diagnosis.isRunning ? "Memeriksa koneksi…" : "Internet lemot? Cek di mana masalahnya"))
                    .font(.app(size: 16, weight: .semibold))
                Text(diagnosis.verdict?.detail ?? (diagnosis.isRunning ? diagnosis.stage : "iwifyou mengukur sinyal Wi-Fi Mac, ping ke router, ping ke internet, DNS, lalu status WAN dan redaman fiber dari router."))
                    .font(.app(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let date = diagnosis.finished, !diagnosis.isRunning {
                    Text("Diperiksa \(date.formatted(date: .omitted, time: .shortened))").font(.app(.caption)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                Task {
                    await diagnosis.run(routerHost: model.routerHost) { await model.diagnosisRouterSide() }
                }
            } label: {
                if diagnosis.isRunning { ProgressView().controlSize(.small) } else { Text(diagnosis.finished == nil ? "Periksa Sekarang" : "Periksa Lagi") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(diagnosis.isRunning || model.isWorking)
        }
    }

    private var icon: String {
        switch diagnosis.verdict?.area {
        case nil: "stethoscope"
        case .allGood: "checkmark.seal.fill"
        case .wifi: "wifi.exclamationmark"
        case .router: "wifi.router"
        case .fiber: "cable.connector.slash"
        case .isp: "globe"
        case .dns: "character.book.closed"
        }
    }

    private var color: Color { diagnosis.verdict?.health.color ?? Brand.accent }

    private var checks: some View {
        Group {
            CheckRow(title: "Sinyal Wi-Fi Mac", health: diagnosis.link.map { SignalQuality.health(rssi: $0.rssi) } ?? (diagnosis.isRunning ? nil : .unknown),
                     value: diagnosis.link.map { "\($0.rssi) dBm · \(SignalQuality.label(rssi: $0.rssi))" } ?? "Tidak memakai Wi-Fi")
            CheckRow(title: "Ping ke router", health: diagnosis.gateway.map(\.health), value: diagnosis.gateway.map(\.summary) ?? "—")
            CheckRow(title: "Ping ke internet (1.1.1.1)", health: diagnosis.internet.map { $0.health(slow: 150) }, value: diagnosis.internet.map(\.summary) ?? "—")
            CheckRow(title: "DNS", health: diagnosis.dnsWorks.map { $0 ? .good : .bad }, value: diagnosis.dnsWorks.map { $0 ? "Berfungsi" : "Gagal" } ?? "—")
            CheckRow(title: "Status internet router (WAN)", health: diagnosis.router?.wanConnected.map { $0 ? .good : .bad } ?? (diagnosis.router == nil ? nil : .unknown),
                     value: diagnosis.router?.wanConnected.map { $0 ? "Tersambung" : "Terputus" } ?? (diagnosis.router?.note ?? "—"))
            CheckRow(title: "Redaman fiber (RX)", health: diagnosis.router?.fiber?.health ?? (diagnosis.router == nil ? nil : .unknown),
                     value: diagnosis.router?.fiber.map { String(format: "%.1f dBm", $0.rx) } ?? (diagnosis.router?.note ?? "—"))
        }
    }
}

private struct CheckRow: View {
    let title: String
    let health: Health?
    let value: String

    var body: some View {
        HStack {
            Group {
                if let health {
                    Image(systemName: health.symbol).foregroundStyle(health.color)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 22)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 9)
    }
}

struct SignalMeterCard: View {
    let meter: SignalMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let link = meter.link {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(link.rssi)").font(.app(size: 44, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(SignalQuality.health(rssi: link.rssi).color)
                            .contentTransition(.numericText(value: Double(link.rssi)))
                        Text("dBm · \(SignalQuality.label(rssi: link.rssi))").font(.app(.callout)).foregroundStyle(.secondary)
                    }
                    metric("SNR", "\(link.snr) dB")
                    metric("Kecepatan link", "\(Int(link.transmitRate)) Mbps")
                    metric("Channel", link.channel.map { "\($0) · \(link.band)" } ?? link.band)
                    metric("Standar", link.standard)
                }
                Chart {
                    RuleMark(y: .value("Baik", -67)).foregroundStyle(Brand.good.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    RuleMark(y: .value("Lemah", -75)).foregroundStyle(Brand.bad.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    ForEach(meter.samples) { sample in
                        LineMark(x: .value("Waktu", sample.id), y: .value("Sinyal", sample.rssi))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Brand.accent)
                    }
                }
                .chartYScale(domain: -95 ... -30)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [-90, -75, -67, -50, -30]) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)") } }
                    }
                }
                .frame(height: 150)
                Text("SNR di atas 25 dB berarti gangguan rendah.").font(.app(.caption)).foregroundStyle(.secondary)
            } else {
                Text("Mac tidak sedang tersambung ke Wi-Fi.").font(.app(.callout)).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.app(.body).weight(.medium)).monospacedDigit()
            Text(title).font(.app(.caption)).foregroundStyle(.secondary)
        }
    }
}

extension Health {
    var color: Color {
        switch self {
        case .good: Brand.good
        case .warning: Brand.warn
        case .bad: Brand.bad
        case .unknown: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .unknown: "minus.circle"
        }
    }
}

extension PingResult {
    var summary: String {
        guard reachable else { return "Tidak ada balasan" }
        let loss = Int((loss * 100).rounded())
        return String(format: "%.0f ms", average ?? 0) + (loss > 0 ? " · \(loss)% hilang" : "")
    }

    var health: Health { health(slow: 60) }

    func health(slow: Double) -> Health {
        guard reachable else { return .bad }
        if loss > 0.1 || (average ?? 0) > slow { return .warning }
        return .good
    }
}
