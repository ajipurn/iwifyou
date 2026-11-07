import Foundation

/// A 2.4 GHz network heard by the Mac's own Wi-Fi radio. Names are optional:
/// macOS hides SSIDs from scans until Location access is granted.
public struct NearbyNetwork: Hashable, Sendable {
    public let name: String?
    public let channel: Int
    public let widthMHz: Int
    public let rssi: Int

    public init(name: String?, channel: Int, widthMHz: Int, rssi: Int) {
        self.name = name
        self.channel = channel
        self.widthMHz = widthMHz
        self.rssi = rssi
    }
}

public struct WiFiScanResult: Equatable, Sendable {
    public let networks: [NearbyNetwork]
    /// The channel the Mac itself is associated on, when it is on 2.4 GHz.
    public let connectedChannel: Int?
    public let namesAvailable: Bool
    public let otherBandCount: Int
    public let date: Date

    public init(networks: [NearbyNetwork], connectedChannel: Int?, namesAvailable: Bool, otherBandCount: Int, date: Date = .now) {
        self.networks = networks
        self.connectedChannel = connectedChannel
        self.namesAvailable = namesAvailable
        self.otherBandCount = otherBandCount
        self.date = date
    }

    public static let demo = WiFiScanResult(
        networks: [
            NearbyNetwork(name: "iwifyou demo", channel: 6, widthMHz: 20, rssi: -42),
            NearbyNetwork(name: "Tetangga-1", channel: 1, widthMHz: 20, rssi: -58),
            NearbyNetwork(name: "Tetangga-2", channel: 1, widthMHz: 20, rssi: -71),
            NearbyNetwork(name: "Kafe", channel: 3, widthMHz: 40, rssi: -66),
            NearbyNetwork(name: nil, channel: 6, widthMHz: 20, rssi: -79),
            NearbyNetwork(name: "Kos Mawar", channel: 11, widthMHz: 20, rssi: -63),
            NearbyNetwork(name: "Kos Melati", channel: 9, widthMHz: 20, rssi: -84),
        ],
        connectedChannel: 6, namesAvailable: true, otherBandCount: 3
    )
}

public struct ChannelQuality: Hashable, Sendable, Identifiable {
    public enum Level: Sendable { case good, fair, busy }

    public let channel: Int
    /// Sum of overlap x signal weight of foreign networks; 1.0 is roughly one
    /// strong neighbour sitting on exactly this channel.
    public let load: Double
    public let neighbours: Int

    public var id: Int { channel }
    public var level: Level { load < 0.6 ? .good : load < 1.6 ? .fair : .busy }
}

/// Estimates co- and adjacent-channel interference from a Wi-Fi scan.
/// It only knows what the Mac can hear from where it sits.
public enum ChannelSurvey {
    public static func qualities(for channels: [Int], networks: [NearbyNetwork], ownSSID: String?) -> [ChannelQuality] {
        let foreign = networks.filter { network in
            guard let ownSSID, let name = network.name else { return true }
            return name != ownSSID
        }
        return channels.filter { (1...13).contains($0) }.map { channel in
            var load = 0.0
            var neighbours = 0
            for network in foreign {
                let contribution = overlap(candidate: channel, network: network) * signalWeight(network.rssi)
                if contribution > 0 {
                    load += contribution
                    neighbours += 1
                }
            }
            return ChannelQuality(channel: channel, load: load, neighbours: neighbours)
        }
    }

    /// Lowest load wins; ties prefer the non-overlapping 1/6/11 plan.
    public static func recommendation(_ qualities: [ChannelQuality]) -> Int? {
        qualities.min { lhs, rhs in
            let left = (Int((lhs.load * 100).rounded()), [1, 6, 11].contains(lhs.channel) ? 0 : 1, lhs.channel)
            let right = (Int((rhs.load * 100).rounded()), [1, 6, 11].contains(rhs.channel) ? 0 : 1, rhs.channel)
            return left < right
        }?.channel
    }

    /// Fraction of a 20 MHz candidate channel covered by the network's signal.
    static func overlap(candidate: Int, network: NearbyNetwork) -> Double {
        guard (1...13).contains(network.channel) else { return 0 }
        let center = frequency(candidate)
        let span = occupied(network)
        let shared = min(center + 10, span.upperBound) - max(center - 10, span.lowerBound)
        return max(0, min(1, shared / 20))
    }

    /// -90 dBm or weaker contributes nothing; -50 dBm or stronger counts fully.
    public static func signalWeight(_ rssi: Int) -> Double {
        max(0, min(1, Double(rssi + 90) / 40))
    }

    private static func frequency(_ channel: Int) -> Double { 2407 + 5 * Double(channel) }

    /// Scans report the primary channel and width but not the 40 MHz
    /// extension side. Edge channels can only extend inward; in the middle
    /// both sides are counted, which errs toward caution.
    private static func occupied(_ network: NearbyNetwork) -> ClosedRange<Double> {
        let center = frequency(network.channel)
        guard network.widthMHz >= 40 else { return (center - 10)...(center + 10) }
        if network.channel <= 4 { return (center - 10)...(center + 30) }
        if network.channel >= 10 { return (center - 30)...(center + 10) }
        return (center - 30)...(center + 30)
    }
}

extension ChannelSurvey {
    /// Mean load per channel across several scans. A single scan swings
    /// with RSSI noise and missed beacons; the mean is what persists.
    public static func averaged(_ samples: [[ChannelQuality]]) -> [ChannelQuality] {
        guard let first = samples.first else { return [] }
        return first.map { quality in
            let loads = samples.compactMap { sample in sample.first { $0.channel == quality.channel }?.load }
            let neighbours = samples.compactMap { sample in sample.first { $0.channel == quality.channel }?.neighbours }
            return ChannelQuality(
                channel: quality.channel,
                load: loads.reduce(0, +) / Double(max(loads.count, 1)),
                neighbours: Int((Double(neighbours.reduce(0, +)) / Double(max(neighbours.count, 1))).rounded())
            )
        }
    }
}

extension ChannelAdvice {
    /// Suggests a channel only when it is clearly quieter than the current
    /// one on average *and* in most individual scans. With fewer than
    /// `minimumSamples` scans there is no suggestion at all.
    public static func stableSuggestion(
        _ samples: [[ChannelQuality]], current: Int?, margin: Double = 0.3,
        consistency: Double = 0.75, minimumSamples: Int = 3
    ) -> Int? {
        guard samples.count >= minimumSamples else { return nil }
        let average = ChannelSurvey.averaged(samples)
        guard let best = ChannelSurvey.recommendation(average),
              let bestLoad = average.first(where: { $0.channel == best })?.load else { return nil }
        guard let current, current != best else { return current == nil ? best : nil }
        guard let currentLoad = average.first(where: { $0.channel == current })?.load,
              currentLoad - bestLoad >= margin else { return nil }
        let wins = samples.filter { sample in
            guard let b = sample.first(where: { $0.channel == best })?.load,
                  let c = sample.first(where: { $0.channel == current })?.load else { return false }
            return c - b >= margin / 2
        }.count
        return Double(wins) / Double(samples.count) >= consistency ? best : nil
    }
}
