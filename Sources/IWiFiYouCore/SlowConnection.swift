import Foundation

public struct ConnectionSample: Sendable {
    public let rssi: Int?
    public let gateway: PingResult?
    public let internet: PingResult?

    public init(rssi: Int?, gateway: PingResult?, internet: PingResult?) {
        self.rssi = rssi
        self.gateway = gateway
        self.internet = internet
    }
}

public enum SlowCause: Equatable, Sendable {
    /// The Mac-to-router hop is slow while the signal is fine: congestion
    /// or interference, the case a channel change can help.
    case wifiInterference
    case weakSignal
    /// Home network is fine; the ISP side is slow.
    case isp
}

/// Turns periodic measurements into at most one alert per episode. A cause
/// must repeat on consecutive checks, and alerts respect a cooldown.
public struct SlowConnectionDetector: Sendable {
    public let required: Int
    public let cooldown: TimeInterval
    public private(set) var lastAlert: Date?
    private var streakCause: SlowCause?
    private var streakCount = 0

    public init(required: Int = 2, cooldown: TimeInterval = 1800) {
        self.required = required
        self.cooldown = cooldown
    }

    public static func classify(_ sample: ConnectionSample) -> SlowCause? {
        // An unreachable router is an outage, not "slow"; Diagnosa covers it.
        guard let gateway = sample.gateway, gateway.reachable else { return nil }
        let homeSlow = gateway.loss >= 0.1 || (gateway.average ?? 0) >= 40 || (gateway.jitter ?? 0) >= 30
        if homeSlow {
            if let rssi = sample.rssi, rssi != 0, rssi < -75 { return .weakSignal }
            return .wifiInterference
        }
        guard let internet = sample.internet else { return nil }
        if !internet.reachable || internet.loss >= 0.1 || (internet.average ?? 0) >= 150 { return .isp }
        return nil
    }

    /// Returns the cause when an alert should be shown now.
    public mutating func observe(_ sample: ConnectionSample, at date: Date = .now) -> SlowCause? {
        guard let cause = Self.classify(sample) else {
            streakCause = nil
            streakCount = 0
            return nil
        }
        streakCount = cause == streakCause ? streakCount + 1 : 1
        streakCause = cause
        guard streakCount >= required else { return nil }
        if let lastAlert, date.timeIntervalSince(lastAlert) < cooldown { return nil }
        lastAlert = date
        streakCount = 0
        return cause
    }
}

public enum ChannelAdvice {
    /// Suggests the least loaded channel only when it is clearly better
    /// than the one in use, so a slow link is not blamed on the channel
    /// when the air is already as quiet as it gets.
    public static func suggestion(_ qualities: [ChannelQuality], current: Int?) -> Int? {
        guard let best = ChannelSurvey.recommendation(qualities),
              let bestLoad = qualities.first(where: { $0.channel == best })?.load else { return nil }
        guard let current, current != best else { return current == nil ? best : nil }
        guard let currentLoad = qualities.first(where: { $0.channel == current })?.load else { return best }
        return currentLoad - bestLoad >= 0.3 ? best : nil
    }
}
