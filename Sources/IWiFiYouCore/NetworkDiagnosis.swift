import Foundation

public enum Health: Int, Comparable, Sendable {
    case good, warning, bad, unknown

    public static func < (lhs: Health, rhs: Health) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PingResult: Equatable, Sendable {
    public let sent: Int
    public let received: Int
    /// Milliseconds; nil when nothing came back.
    public let average: Double?
    public let jitter: Double?

    public init(sent: Int, received: Int, average: Double?, jitter: Double?) {
        self.sent = sent
        self.received = received
        self.average = average
        self.jitter = jitter
    }

    public var loss: Double { sent == 0 ? 1 : Double(sent - received) / Double(sent) }
    public var reachable: Bool { received > 0 }

    /// Parses the summary printed by macOS `/sbin/ping -q`.
    public static func parse(_ output: String) -> PingResult? {
        guard let counts = output.firstMatch(of: /(\d+) packets transmitted, (\d+) (?:packets )?received/),
              let sent = Int(counts.1), let received = Int(counts.2) else { return nil }
        var average: Double?
        var jitter: Double?
        if let times = output.firstMatch(of: #/= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms/#) {
            average = Double(times.2)
            jitter = Double(times.4)
        }
        return PingResult(sent: sent, received: received, average: average, jitter: jitter)
    }
}

public enum SignalQuality {
    /// Typical guidance for Wi-Fi client RSSI in dBm.
    public static func health(rssi: Int) -> Health {
        switch rssi {
        case 0: .unknown
        case (-67)...: .good
        case -75 ..< -67: .warning
        default: .bad
        }
    }

    public static func label(rssi: Int) -> String {
        switch rssi {
        case 0: "Tidak tersambung"
        case (-55)...: "Sangat kuat"
        case -67 ..< -55: "Baik"
        case -75 ..< -67: "Cukup"
        default: "Lemah"
        }
    }
}

/// GPON optical levels from the ONT's PON link page.
public struct FiberPower: Equatable, Sendable {
    /// Received optical power in dBm ("redaman").
    public let rx: Double
    public let tx: Double?

    public init(rx: Double, tx: Double?) {
        self.rx = rx
        self.tx = tx
    }

    /// Class B+ receivers are specified down to about -28 dBm; ISPs usually
    /// treat -8...-25 dBm as healthy and worse than -27 dBm as a fault.
    public var health: Health {
        switch rx {
        case -25 ... -8: .good
        case -27 ..< -25: .warning
        default: .bad
        }
    }
}

public struct DiagnosisInput: Sendable {
    public var onWiFi: Bool
    public var rssi: Int?
    public var gateway: PingResult?
    public var internet: PingResult?
    public var dnsWorks: Bool?
    public var wanConnected: Bool?
    public var fiber: FiberPower?

    public init(onWiFi: Bool, rssi: Int? = nil, gateway: PingResult? = nil, internet: PingResult? = nil,
                dnsWorks: Bool? = nil, wanConnected: Bool? = nil, fiber: FiberPower? = nil) {
        self.onWiFi = onWiFi
        self.rssi = rssi
        self.gateway = gateway
        self.internet = internet
        self.dnsWorks = dnsWorks
        self.wanConnected = wanConnected
        self.fiber = fiber
    }
}

public struct DiagnosisVerdict: Equatable, Sendable {
    public enum Area: Sendable { case allGood, wifi, router, fiber, isp, dns }

    public let area: Area
    public let health: Health
    public let title: String
    public let detail: String
}

/// Turns a handful of measurements into one plain-language conclusion.
/// Order matters: the closest failing hop explains the symptoms after it.
public enum NetworkDiagnosis {
    public static func evaluate(_ input: DiagnosisInput) -> DiagnosisVerdict {
        let weakSignal = input.onWiFi && (input.rssi.map { SignalQuality.health(rssi: $0) == .bad } ?? false)

        guard let gateway = input.gateway, gateway.reachable else {
            if weakSignal {
                return DiagnosisVerdict(area: .wifi, health: .bad, title: "Sinyal Wi-Fi terlalu lemah",
                    detail: "Mac tidak bisa menjangkau router. Dekatkan Mac ke router atau kurangi penghalang.")
            }
            return DiagnosisVerdict(area: .router, health: .bad, title: "Router tidak merespons",
                detail: "Mac tidak mendapat balasan dari router. Pastikan Mac tersambung ke jaringan router; jika ya, coba restart router.")
        }
        if input.wanConnected == false || input.fiber?.health == .bad {
            let fiberText = input.fiber.map { String(format: " Redaman %.1f dBm.", $0.rx) } ?? ""
            return DiagnosisVerdict(area: .fiber, health: .bad, title: "Jalur fiber atau ISP bermasalah",
                detail: "Jaringan rumah normal, tetapi koneksi router ke ISP terganggu.\(fiberText) Laporkan ke ISP dengan menyebut nilai ini.")
        }
        if gateway.loss > 0.1 || (gateway.average ?? 0) > 60 || (gateway.jitter ?? 0) > 40 {
            return DiagnosisVerdict(area: .wifi, health: .warning, title: "Koneksi Mac ke router tidak stabil",
                detail: "Ada paket hilang atau jeda tinggi di jaringan rumah. Coba pindah posisi, ganti channel yang lebih lega, atau pakai kabel.")
        }
        guard let internet = input.internet, internet.reachable else {
            return DiagnosisVerdict(area: .isp, health: .bad, title: "Internet tidak bisa dijangkau",
                detail: "Router merespons normal, tetapi tidak ada jalan keluar ke internet. Biasanya gangguan dari ISP.")
        }
        if internet.loss > 0.05 || (internet.average ?? 0) > 150 {
            return DiagnosisVerdict(area: .isp, health: .warning, title: "Internet dari ISP lambat atau tidak stabil",
                detail: "Jaringan rumah normal, tetapi jalur ke internet kehilangan paket atau lambat.")
        }
        if input.dnsWorks == false {
            return DiagnosisVerdict(area: .dns, health: .warning, title: "Nama situs tidak bisa diterjemahkan",
                detail: "Internet tersambung, tetapi DNS gagal. Situs mungkin tidak terbuka walau koneksi ada.")
        }
        if weakSignal {
            return DiagnosisVerdict(area: .wifi, health: .warning, title: "Internet normal, sinyal di sini lemah",
                detail: "Semua jalur berfungsi, tetapi sinyal Wi-Fi di posisi ini lemah sehingga kecepatan bisa turun.")
        }
        if input.fiber?.health == .warning {
            return DiagnosisVerdict(area: .fiber, health: .warning, title: "Redaman fiber mendekati batas",
                detail: String(format: "Koneksi normal, tetapi redaman %.1f dBm. Pantau; jika makin buruk, laporkan ke ISP.", input.fiber!.rx))
        }
        return DiagnosisVerdict(area: .allGood, health: .good, title: "Semua normal",
            detail: "Wi-Fi, router, dan internet merespons dengan baik.")
    }
}
