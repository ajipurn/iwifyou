import CoreLocation
import CoreWLAN
import Foundation
import IWiFiYouCore
import Observation

/// Scans with the Mac's own Wi-Fi radio. It never contacts the router.
nonisolated enum WiFiScanner {
    enum Failure: Error, LocalizedError {
        case noInterface
        case poweredOff
        case scanFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInterface: "Mac ini tidak punya antarmuka Wi-Fi yang bisa dipakai untuk memindai."
            case .poweredOff: "Wi-Fi Mac sedang mati. Nyalakan Wi-Fi untuk memindai channel."
            case .scanFailed(let reason): "Pemindaian Wi-Fi gagal: \(reason)"
            }
        }
    }

    // CoreWLAN scans block for a few seconds; keep them off the UI actor.
    @concurrent static func scan() async throws -> WiFiScanResult {
        guard let interface = CWWiFiClient.shared().interface() else { throw Failure.noInterface }
        guard interface.powerOn() else { throw Failure.poweredOff }
        let found: Set<CWNetwork>
        do {
            found = try interface.scanForNetworks(withName: nil, includeHidden: true)
        } catch {
            throw Failure.scanFailed(error.localizedDescription)
        }
        var networks: [NearbyNetwork] = []
        var otherBands = 0
        var namesAvailable = false
        for network in found {
            guard let channel = network.wlanChannel else { continue }
            guard channel.channelBand == .band2GHz, (1...14).contains(channel.channelNumber) else {
                otherBands += 1
                continue
            }
            // Without Location access macOS returns nil for every SSID/BSSID.
            if network.bssid != nil { namesAvailable = true }
            let width = switch channel.channelWidth {
            case .width40MHz: 40
            case .width80MHz: 80
            case .width160MHz: 160
            default: 20
            }
            let name = network.ssid.flatMap { $0.isEmpty ? nil : $0 }
            networks.append(NearbyNetwork(name: name, channel: channel.channelNumber, widthMHz: width, rssi: network.rssiValue))
        }
        let current = interface.wlanChannel()
        let connected = current?.channelBand == .band2GHz ? current?.channelNumber : nil
        return WiFiScanResult(
            networks: networks.sorted { $0.rssi > $1.rssi },
            connectedChannel: connected, namesAvailable: namesAvailable, otherBandCount: otherBands
        )
    }
}

@Observable
final class ChannelScanModel {
    enum Phase {
        case idle
        case scanning(WiFiScanResult?)
        case done(WiFiScanResult)
        case failed(String, WiFiScanResult?)

        var result: WiFiScanResult? {
            switch self {
            case .idle: nil
            case .scanning(let previous), .failed(_, let previous): previous
            case .done(let result): result
            }
        }
    }

    private(set) var phase = Phase.idle
    /// Recent scans, oldest first. Advice uses their average, never one scan.
    private(set) var history: [WiFiScanResult] = []
    private(set) var burstProgress: Int?
    let isDemo: Bool
    let burstSize = 3
    let maxHistory = 9
    let maxAge: TimeInterval = 15 * 60

    init(demo: Bool) { isDemo = demo }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// Per-scan channel qualities for the recent history.
    func samples(channels: [Int], ownSSID: String?) -> [[ChannelQuality]] {
        history.map { ChannelSurvey.qualities(for: channels, networks: $0.networks, ownSSID: ownSSID) }
    }

    /// A short burst of scans a few seconds apart, added to the history.
    func scan() async {
        guard !isScanning else { return }
        let previous = phase.result
        phase = .scanning(previous)
        var latest = previous
        for index in 0..<burstSize {
            burstProgress = index + 1
            if index > 0 { try? await Task.sleep(for: .seconds(3)) }
            do {
                let result = isDemo ? Self.demoScan() : try await WiFiScanner.scan()
                if isDemo { try? await Task.sleep(for: .milliseconds(300)) }
                latest = result
                record(result)
                phase = .scanning(result)
            } catch {
                burstProgress = nil
                phase = .failed(error.localizedDescription, latest)
                return
            }
        }
        burstProgress = nil
        if let latest { phase = .done(latest) }
    }

    private func record(_ result: WiFiScanResult) {
        history.append(result)
        history.removeAll { result.date.timeIntervalSince($0.date) > maxAge }
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
    }

    /// Demo scans wobble like real ones: RSSI noise and occasional misses.
    private static func demoScan() -> WiFiScanResult {
        let base = WiFiScanResult.demo
        let networks = base.networks.compactMap { network -> NearbyNetwork? in
            if network.name != "iwifyou demo", Int.random(in: 0..<6) == 0 { return nil }
            return NearbyNetwork(name: network.name, channel: network.channel, widthMHz: network.widthMHz,
                                 rssi: network.rssi + Int.random(in: -6...6))
        }
        return WiFiScanResult(networks: networks, connectedChannel: base.connectedChannel,
                              namesAvailable: base.namesAvailable, otherBandCount: base.otherBandCount)
    }
}

/// macOS only reveals nearby SSIDs to apps with Location access. Scanning
/// still works without it; names are simply hidden.
@Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager: CLLocationManager

    override init() {
        let manager = CLLocationManager()
        self.manager = manager
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isGranted: Bool { status == .authorizedAlways }
    var canAsk: Bool { status == .notDetermined }

    func request() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}
