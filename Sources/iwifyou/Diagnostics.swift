import CoreWLAN
import Darwin
import Foundation
import IWiFiYouCore
import Observation

/// The Mac's current Wi-Fi association, read locally with CoreWLAN.
nonisolated struct WiFiLink: Equatable, Sendable {
    let rssi: Int
    let noise: Int
    let transmitRate: Double
    let channel: Int?
    let band: String
    let widthMHz: Int?
    let standard: String

    var snr: Int { rssi - noise }

    static func current() -> WiFiLink? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0, let channel = interface.wlanChannel() else { return nil }
        let band = switch channel.channelBand {
        case .band2GHz: "2,4 GHz"
        case .band5GHz: "5 GHz"
        default: "6 GHz"
        }
        let width: Int? = switch channel.channelWidth {
        case .width20MHz: 20
        case .width40MHz: 40
        case .width80MHz: 80
        case .width160MHz: 160
        default: nil
        }
        let standard = switch interface.activePHYMode() {
        case .mode11a: "802.11a"
        case .mode11b: "802.11b"
        case .mode11g: "802.11g"
        case .mode11n: "Wi-Fi 4 (802.11n)"
        case .mode11ac: "Wi-Fi 5 (802.11ac)"
        case .mode11ax: "Wi-Fi 6 (802.11ax)"
        default: "—"
        }
        return WiFiLink(rssi: rssi, noise: interface.noiseMeasurement(), transmitRate: interface.transmitRate(),
                        channel: channel.channelNumber, band: band, widthMHz: width, standard: standard)
    }
}

@Observable
final class SignalMeter {
    struct Sample: Identifiable {
        let id: Date
        let rssi: Int
        let noise: Int
    }

    private(set) var samples: [Sample] = []
    private(set) var link: WiFiLink?
    let isDemo: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var users = 0

    init(demo: Bool) { isDemo = demo }

    /// Reference-counted so two visible views share one polling loop.
    func start() {
        users += 1
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        task?.cancel()
        task = nil
    }

    func sample() {
        if isDemo {
            let wobble = Int((sin(Date.now.timeIntervalSince1970 / 3) * 6).rounded())
            link = WiFiLink(rssi: -58 + wobble, noise: -92, transmitRate: 144, channel: 6, band: "2,4 GHz", widthMHz: 20, standard: "Wi-Fi 4 (802.11n)")
        } else {
            link = WiFiLink.current()
        }
        guard let link else { return }
        samples.append(Sample(id: .now, rssi: link.rssi, noise: link.noise))
        if samples.count > 90 { samples.removeFirst(samples.count - 90) }
    }
}

/// Runs macOS's own `ping`. Hosts are fixed literals or the validated
/// router address, passed as a separate argument (no shell involved).
nonisolated enum Pinger {
    @concurrent static func ping(_ host: String, count: Int = 10) async -> PingResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", String(count), "-i", "0.2", "-W", "1000", "-q", host]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PingResult.parse(String(decoding: data, as: UTF8.self))
    }

    @concurrent static func resolves(_ host: String) async -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
    }
}

/// Checks from this Mac whether a site answers over plain HTTP and over
/// HTTPS, using macOS's own curl without following redirects. Entries come
/// from SiteFilter.normalize, so they contain URL characters only.
nonisolated enum SiteProbe {
    struct Result: Equatable, Sendable {
        let http: Bool
        let https: Bool
    }

    @concurrent static func check(_ site: String) async -> Result {
        async let http = answers("http://" + site)
        async let https = answers("https://" + site)
        return await Result(http: http, https: https)
    }

    @concurrent private static func answers(_ url: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "-o", "/dev/null", "-m", "6", "--max-redirs", "0", "-w", "%{http_code}", "--", url]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let code = String(decoding: data, as: UTF8.self)
        return process.terminationStatus == 0 && code != "000"
    }
}

extension SiteProbe {
    enum DNSAnswer: Equatable, Sendable { case blocked, open, unknown }

    /// Asks the router's DNS directly, bypassing the Mac's cache.
    @concurrent static func routerDNS(_ name: String, router: String) async -> DNSAnswer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        process.arguments = ["+short", "+time=2", "+tries=1", "A", name, "@" + router]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return .unknown }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let answers = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { IPv4.normalize($0) != nil }
        guard process.terminationStatus == 0, !answers.isEmpty else { return .unknown }
        return answers.allSatisfy { $0 == DNSBlocklist.sinkhole } ? .blocked : .open
    }
}

