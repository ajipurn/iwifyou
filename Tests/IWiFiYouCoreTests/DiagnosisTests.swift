import Foundation
import Testing
@testable import IWiFiYouCore

@Test func parsesMacPingSummary() throws {
    let output = """
    --- 192.168.1.1 ping statistics ---
    10 packets transmitted, 9 packets received, 10.0% packet loss
    round-trip min/avg/max/stddev = 3.043/12.903/45.420/16.308 ms
    """
    let result = try #require(PingResult.parse(output))
    #expect(result.sent == 10 && result.received == 9)
    #expect(result.average == 12.903)
    #expect(result.jitter == 16.308)
    #expect(abs(result.loss - 0.1) < 0.0001)
    let silent = try #require(PingResult.parse("5 packets transmitted, 0 packets received, 100.0% packet loss"))
    #expect(!silent.reachable && silent.average == nil)
    #expect(PingResult.parse("ping: cannot resolve host") == nil)
}

@Test func fiberAndSignalThresholds() {
    #expect(FiberPower(rx: -21.4, tx: 2).health == .good)
    #expect(FiberPower(rx: -26, tx: nil).health == .warning)
    #expect(FiberPower(rx: -29.5, tx: nil).health == .bad)
    #expect(FiberPower(rx: -5, tx: nil).health == .bad) // overload
    #expect(SignalQuality.health(rssi: -50) == .good)
    #expect(SignalQuality.health(rssi: -70) == .warning)
    #expect(SignalQuality.health(rssi: -80) == .bad)
    #expect(SignalQuality.health(rssi: 0) == .unknown)
}

private let fine = PingResult(sent: 10, received: 10, average: 5, jitter: 1)

@Test func diagnosisBlamesTheClosestFailingHop() {
    let weakAndUnreachable = DiagnosisInput(onWiFi: true, rssi: -84, gateway: PingResult(sent: 10, received: 0, average: nil, jitter: nil))
    #expect(NetworkDiagnosis.evaluate(weakAndUnreachable).area == .wifi)

    let routerDown = DiagnosisInput(onWiFi: false, gateway: nil)
    #expect(NetworkDiagnosis.evaluate(routerDown).area == .router)

    let losFiber = DiagnosisInput(onWiFi: true, rssi: -50, gateway: fine, internet: nil, wanConnected: true, fiber: FiberPower(rx: -40, tx: nil))
    #expect(NetworkDiagnosis.evaluate(losFiber).area == .fiber)

    let wanDown = DiagnosisInput(onWiFi: true, rssi: -50, gateway: fine, internet: nil, wanConnected: false)
    #expect(NetworkDiagnosis.evaluate(wanDown).area == .fiber)

    let lossyWiFi = DiagnosisInput(onWiFi: true, rssi: -60, gateway: PingResult(sent: 10, received: 7, average: 30, jitter: 10), internet: fine)
    #expect(NetworkDiagnosis.evaluate(lossyWiFi).area == .wifi)

    let ispDown = DiagnosisInput(onWiFi: true, rssi: -55, gateway: fine, internet: PingResult(sent: 10, received: 0, average: nil, jitter: nil), wanConnected: true)
    #expect(NetworkDiagnosis.evaluate(ispDown).area == .isp)

    let slowISP = DiagnosisInput(onWiFi: true, rssi: -55, gateway: fine, internet: PingResult(sent: 10, received: 10, average: 220, jitter: 30))
    #expect(NetworkDiagnosis.evaluate(slowISP).area == .isp)

    let dnsBroken = DiagnosisInput(onWiFi: true, rssi: -55, gateway: fine, internet: fine, dnsWorks: false)
    #expect(NetworkDiagnosis.evaluate(dnsBroken).area == .dns)

    let marginalFiber = DiagnosisInput(onWiFi: false, gateway: fine, internet: fine, dnsWorks: true, wanConnected: true, fiber: FiberPower(rx: -26.2, tx: 2))
    #expect(NetworkDiagnosis.evaluate(marginalFiber).area == .fiber)
    #expect(NetworkDiagnosis.evaluate(marginalFiber).health == .warning)

    let healthy = DiagnosisInput(onWiFi: true, rssi: -52, gateway: fine, internet: fine, dnsWorks: true, wanConnected: true, fiber: FiberPower(rx: -20, tx: 2))
    #expect(NetworkDiagnosis.evaluate(healthy).area == .allGood)
}

private func ping(_ average: Double, loss received: Int = 10, jitter: Double = 2) -> PingResult {
    PingResult(sent: 10, received: received, average: received == 0 ? nil : average, jitter: received == 0 ? nil : jitter)
}

@Test func classifiesSlowConnectionCause() {
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -55, gateway: ping(4), internet: ping(20))) == nil)
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -55, gateway: ping(80, jitter: 45), internet: ping(120))) == .wifiInterference)
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -82, gateway: ping(12, loss: 7), internet: ping(40))) == .weakSignal)
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -55, gateway: ping(4), internet: ping(260))) == .isp)
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -55, gateway: ping(4), internet: ping(0, loss: 0))) == .isp)
    // Router unreachable is an outage, handled by Diagnosa, not a slow alert.
    #expect(SlowConnectionDetector.classify(ConnectionSample(rssi: -55, gateway: ping(0, loss: 0), internet: nil)) == nil)
}

@Test func alertsOnlyAfterConsecutiveSlowChecksAndRespectsCooldown() {
    var detector = SlowConnectionDetector(required: 2, cooldown: 1800)
    let slow = ConnectionSample(rssi: -55, gateway: ping(90, jitter: 50), internet: ping(150))
    let fine = ConnectionSample(rssi: -55, gateway: ping(3), internet: ping(18))
    let start = Date(timeIntervalSince1970: 1_000_000)
    #expect(detector.observe(slow, at: start) == nil)
    #expect(detector.observe(fine, at: start + 120) == nil) // a spike resets
    #expect(detector.observe(slow, at: start + 240) == nil)
    #expect(detector.observe(slow, at: start + 360) == .wifiInterference)
    #expect(detector.observe(slow, at: start + 480) == nil)
    #expect(detector.observe(slow, at: start + 600) == nil) // cooldown
    #expect(detector.observe(slow, at: start + 2100) == nil)
    #expect(detector.observe(slow, at: start + 2400) == .wifiInterference) // still slow after cooldown
}

@Test func suggestsChannelOnlyWhenClearlyBetter() {
    let busy = [NearbyNetwork(name: "A", channel: 1, widthMHz: 20, rssi: -45), NearbyNetwork(name: "B", channel: 2, widthMHz: 20, rssi: -50)]
    let qualities = ChannelSurvey.qualities(for: Array(1...13), networks: busy, ownSSID: nil)
    #expect(ChannelAdvice.suggestion(qualities, current: 1) == 6)
    #expect(ChannelAdvice.suggestion(qualities, current: 11) == nil) // already quiet
    let quiet = ChannelSurvey.qualities(for: Array(1...13), networks: [], ownSSID: nil)
    #expect(ChannelAdvice.suggestion(quiet, current: 6) == nil)
}

private func sample(_ loads: [Int: Double]) -> [ChannelQuality] {
    (1...13).map { ChannelQuality(channel: $0, load: loads[$0] ?? 0.2, neighbours: 1) }
}

@Test func averagingSmoothsSingleScanSpikes() {
    let samples = [sample([1: 2.0]), sample([1: 0.2]), sample([1: 0.2])]
    let average = ChannelSurvey.averaged(samples)
    #expect(abs((average.first { $0.channel == 1 }?.load ?? 0) - 0.8) < 0.0001)
    #expect(average.count == 13)
}

@Test func stableSuggestionNeedsEnoughConsistentScans() {
    let busyOne = [sample([1: 1.4]), sample([1: 1.2]), sample([1: 1.5])]
    #expect(ChannelAdvice.stableSuggestion(busyOne, current: 1) == 6)
    // Too few scans: no advice, however busy.
    #expect(ChannelAdvice.stableSuggestion(Array(busyOne.prefix(2)), current: 1) == nil)
    // Busy in one scan only: the average may cross the margin but the
    // channel is not consistently worse, so nothing is suggested.
    let oneSpike = [sample([1: 2.6]), sample([1: 0.2]), sample([1: 0.2]), sample([1: 0.2])]
    #expect(ChannelAdvice.stableSuggestion(oneSpike, current: 1) == nil)
    // Everything equally quiet: keep the current channel.
    let quiet = [sample([:]), sample([:]), sample([:])]
    #expect(ChannelAdvice.stableSuggestion(quiet, current: 1) == nil)
}
