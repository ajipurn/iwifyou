import Foundation
import IWiFiYouCore
import Observation
import UserNotifications

/// Watches the Mac's own link to the router in the background and raises a
/// notification when it stays slow, suggesting a channel only when the scan
/// shows one that is clearly quieter. It never changes the router itself.
@Observable
final class ConnectionMonitor {
    private(set) var enabled: Bool
    private(set) var lastCheck: Date?
    private(set) var lastSummary: String?
    private(set) var lastAlert: String?
    private(set) var note: String?
    private(set) var isChecking = false
    let interval: Duration = .seconds(120)

    @ObservationIgnored private var detector = SlowConnectionDetector(required: 2, cooldown: 1800)
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let defaults = UserDefaults.standard

    init(model: AppModel) {
        self.model = model
        enabled = !model.isDemo && UserDefaults.standard.bool(forKey: "monitorSlowWiFi")
    }

    func setEnabled(_ value: Bool) async {
        note = nil
        guard !model.isDemo else { return }
        if value {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                note = "Notifikasi iwifyou belum diizinkan. Aktifkan di Pengaturan Sistem › Notifikasi."
                return
            }
        }
        enabled = value
        defaults.set(value, forKey: "monitorSlowWiFi")
        start()
    }

    func start() {
        task?.cancel()
        task = nil
        guard enabled, !model.isDemo else { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    /// Only Mac-side probes: CoreWLAN, ping to the router and to 1.1.1.1,
    /// and a Wi-Fi scan when an alert needs a channel suggestion.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        guard let link = WiFiLink.current() else {
            lastSummary = "Dilewati: Mac tidak memakai Wi-Fi."
            return
        }
        let host = model.routerHost
        let prefix = host.split(separator: ".").prefix(3)
        guard AppModel.localIPv4Addresses().contains(where: { $0.split(separator: ".").prefix(3) == prefix }) else {
            lastSummary = "Dilewati: Mac tidak berada di jaringan \(host)."
            return
        }
        async let gatewayPing = Pinger.ping(host)
        async let internetPing = Pinger.ping("1.1.1.1")
        let (gateway, internet) = await (gatewayPing, internetPing)
        lastCheck = .now
        lastSummary = "Router \(gateway?.summary ?? "—") · Internet \(internet?.summary ?? "—") · Sinyal \(link.rssi) dBm"
        let sample = ConnectionSample(rssi: link.rssi, gateway: gateway, internet: internet)
        guard let cause = detector.observe(sample) else { return }
        await alert(cause, link: link, gateway: gateway, internet: internet)
    }

    private func alert(_ cause: SlowCause, link: WiFiLink, gateway: PingResult?, internet: PingResult?) async {
        let routerText = gateway?.summary ?? "tidak terukur"
        switch cause {
        case .wifiInterference:
            let fixed = model.state.snapshot?.availableChannels.compactMap { channel -> Int? in
                if case .fixed(let number) = channel { return number }
                return nil
            } ?? []
            let channels = fixed.isEmpty ? Array(1...13) : fixed
            // Three scans a few seconds apart: one scan is too noisy to act on.
            var samples: [[ChannelQuality]] = []
            for index in 0..<3 {
                if index > 0 { try? await Task.sleep(for: .seconds(3)) }
                guard let scan = try? await WiFiScanner.scan() else { continue }
                samples.append(ChannelSurvey.qualities(for: channels, networks: scan.networks, ownSSID: model.state.snapshot?.ssid))
            }
            let qualities = ChannelSurvey.averaged(samples)
            let current = link.band == "2,4 GHz" ? link.channel : nil
            if let best = ChannelAdvice.stableSuggestion(samples, current: current) {
                let crowd = current.flatMap { channel in qualities.first { $0.channel == channel } }
                let currentText = current.map { "channel \($0)" + (crowd.map { " (\($0.neighbours) jaringan bertumpuk)" } ?? "") } ?? "channel sekarang"
                let reason = "Koneksi Wi-Fi lambat (ping ke router \(routerText)). Channel \(best) lebih lega daripada \(currentText)."
                model.suggestChannel(best, reason: reason)
                notify(title: "Wi-Fi lambat, coba pindah ke channel \(best)", body: reason + " Klik untuk membuka iwifyou.", channel: best)
            } else {
                notify(title: "Wi-Fi lambat",
                       body: "Ping ke router \(routerText). Channel sekarang sudah termasuk yang paling lega, jadi penyebabnya mungkin jarak, penghalang, atau perangkat lain yang sedang mengunduh besar.")
            }
        case .weakSignal:
            notify(title: "Sinyal Wi-Fi lemah",
                   body: "Sinyal \(link.rssi) dBm dan koneksi ke router tidak stabil (\(routerText)). Dekatkan Mac ke router; pindah channel tidak banyak membantu.")
        case .isp:
            notify(title: "Internet lambat dari sisi ISP",
                   body: "Jaringan rumah normal (ping ke router \(routerText)), tetapi internet \(internet?.summary ?? "tidak terjangkau"). Pindah channel tidak akan membantu; cek redaman di iwifyou › Status.")
        }
    }

    private func notify(title: String, body: String, channel: Int? = nil) {
        lastAlert = title
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let channel { content.userInfo = ["channel": channel] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "slow-connection", content: content, trigger: nil))
    }
}
