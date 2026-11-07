import Foundation

public struct RouterInfo: Equatable, Sendable {
    public let model: String
    public let hardware: String
    public let software: String
    public let bootLoader: String?
}

public struct WANStatus: Equatable, Sendable {
    public let mode: String
    public let name: String
    public let address: String?
    public let gateway: String?
    public let dns: [String]
    public let connected: Bool
    public let linkText: String
    public let disconnectReason: String?
    public let onlineSeconds: Int?
}

public struct OpticalStatus: Equatable, Sendable {
    /// nil while the ONT reports loss of signal.
    public let fiber: FiberPower?
    public let lossOfSignal: Bool
    public let registration: String?
    public let temperature: Double?
    public let voltage: Double?
    public let biasCurrent: Double?
}

public struct WLANLiveStatus: Equatable, Sendable {
    public let enabled: Bool
    public let channel: Int?
}

public struct RouterStatus: Equatable, Sendable {
    public let info: RouterInfo
    public let wan: WANStatus
    public let optical: OpticalStatus
    public let wlan: WLANLiveStatus
    public let date: Date

    public init(info: RouterInfo, wan: WANStatus, optical: OpticalStatus, wlan: WLANLiveStatus, date: Date = .now) {
        self.info = info
        self.wan = wan
        self.optical = optical
        self.wlan = wlan
        self.date = date
    }

    public static let demo = RouterStatus(
        info: RouterInfo(model: "F460", hardware: "V6.0", software: "V6.0.0P12T6", bootLoader: "V6.0.0P12T1"),
        wan: WANStatus(mode: "PPPoE", name: "1_INTERNET_R_VID_45", address: "100.64.12.34", gateway: "100.64.0.1",
                       dns: ["203.0.113.53", "203.0.113.54"], connected: true, linkText: "Connected",
                       disconnectReason: nil, onlineSeconds: 186_400),
        optical: OpticalStatus(fiber: FiberPower(rx: -21.5, tx: 2.7), lossOfSignal: false,
                               registration: "Terdaftar dan terotorisasi", temperature: 48, voltage: 3.21, biasCurrent: 13.9),
        wlan: WLANLiveStatus(enabled: true, channel: 6)
    )
}

/// Status pages render values server-side into `tdleft`/`tdright` rows,
/// except optical power, which sits in `doRxTxPowerShow()` variables.
enum F460Status {
    static let devicePage = "status_dev_info_t.gch"
    static let wanPage = "status_ethwan_if_t.gch"
    static let opticalPage = "pon_status_link_info_t.gch"
    static let wlanPage = "e8_status_wlan_info_t.gch"

    static func device(_ html: String) throws -> RouterInfo {
        try checkSession(html)
        guard html.contains("id=\"Frm_ModelName\"") else { throw RouterError.unsupportedFirmware }
        let rows = Dictionary(rows(in: html), uniquingKeysWith: { first, _ in first })
        guard let model = rows["Model"], !model.isEmpty,
              let hardware = rows["Hardware Version"], let software = rows["Software Version"]
        else { throw RouterError.unsupportedFirmware }
        return RouterInfo(model: model, hardware: hardware, software: software, bootLoader: rows["Boot Loader Version"])
    }

    static func wan(_ html: String) throws -> WANStatus {
        try checkSession(html)
        guard identifies(html, wanPage) else { throw RouterError.unsupportedFirmware }
        let tables = F460Page.matches(#"(?is)<table\b[^>]*>(.*?)</table\s*>"#, in: stripComments(html))
            .map { Dictionary(rows(in: $0[1]), uniquingKeysWith: { first, _ in first }) }
            .filter { $0["Link Status"] != nil }
        guard let table = tables.first(where: { ($0["Connection Name"] ?? "").uppercased().contains("INTERNET") }) ?? tables.first,
              let link = table["Link Status"]
        else { throw RouterError.unsupportedFirmware }
        let dns = ["DNS1", "DNS2", "DNS3"].compactMap { table[$0] }.filter { !$0.isEmpty && $0 != "0.0.0.0" }
        let online = table["Online Duration"].flatMap { Int($0.split(separator: " ").first ?? "") }
        let reason = table["Disconnect Reason"].flatMap { $0.isEmpty ? nil : $0 }
        return WANStatus(
            mode: table["Mode"] ?? "—", name: table["Connection Name"] ?? "—",
            address: table["LAN IP Address"] ?? table["IP Address"], gateway: table["Gateway"], dns: dns,
            connected: link.caseInsensitiveCompare("Connected") == .orderedSame, linkText: link,
            disconnectReason: reason, onlineSeconds: online
        )
    }

    static func optical(_ html: String) throws -> OpticalStatus {
        try checkSession(html)
        guard identifies(html, opticalPage) else { throw RouterError.unsupportedFirmware }
        // The page divides the raw integers by 10000 before display.
        let functions = F460Page.matches(#"(?s)function\s+doRxTxPowerShow\s*\(\s*\)\s*\{(.*?)\n\}"#, in: html)
        guard functions.count == 1, let body = functions.first?[1],
              body.contains("RxPower/10000"), body.contains("TxPower/10000"),
              let los = F460Page.matches(#"var\s+LosInfo\s*=\s*"([01])"\s*;"#, in: body).first?[1],
              let rxRaw = F460Page.matches(#"var\s+RxPower\s*=\s*"(-?\d{1,7})"\s*;"#, in: body).first.flatMap({ Double($0[1]) }),
              let txRaw = F460Page.matches(#"var\s+TxPower\s*=\s*"(-?\d{1,7})"\s*;"#, in: body).first.flatMap({ Double($0[1]) })
        else { throw RouterError.unsupportedFirmware }
        let state = F460Page.matches(#"Transfer_meaning\('LoidState','(\d)'\)"#, in: html).last?[1]
        let registration: String? = switch state {
        case "0": "Belum terdaftar"
        case "1": "Terdaftar, belum diotorisasi"
        case "2": "Terdaftar dan terotorisasi"
        default: nil
        }
        let rows = rows(in: html)
        func number(_ prefix: String) -> Double? {
            rows.first { $0.0.hasPrefix(prefix) }.flatMap { Double($0.1) }
        }
        let lossOfSignal = los == "1"
        return OpticalStatus(
            fiber: lossOfSignal ? nil : FiberPower(rx: rxRaw / 10000, tx: txRaw / 10000),
            lossOfSignal: lossOfSignal, registration: registration,
            temperature: number("Operating Temperature"),
            voltage: number("Optical Module Supply Voltage").map { $0 / 1_000_000 },
            biasCurrent: number("Optical Transmitter Bias Current").map { $0 / 1000 }
        )
    }

    static func wlan(_ html: String) throws -> WLANLiveStatus {
        try checkSession(html)
        guard identifies(html, wlanPage) else { throw RouterError.unsupportedFirmware }
        let rows = rows(in: html)
        guard let state = rows.first(where: { $0.0 == "Wireless network connection status" })?.1 else {
            throw RouterError.unsupportedFirmware
        }
        let channel = rows.first(where: { $0.0 == "Channel" }).flatMap { Int($0.1) }.flatMap { (1...14).contains($0) ? $0 : nil }
        return WLANLiveStatus(enabled: state.caseInsensitiveCompare("Enable") == .orderedSame, channel: channel)
    }

    // MARK: Helpers

    static func checkSession(_ html: String) throws {
        if F460Page.isAdminSessionInUse(html) { throw RouterError.adminSessionInUse }
        if F460Page.isLoginPage(html) || F460Page.isSessionTimeout(html) { throw RouterError.loginRequired }
        guard html.utf8.count < 2_000_000 else { throw RouterError.invalidResponse }
    }

    static func identifies(_ html: String, _ page: String) -> Bool {
        let escaped = page.replacingOccurrences(of: "_", with: "\\x5f").replacingOccurrences(of: ".", with: "\\x2e")
        return html.contains("pageLoad(getURL(\"\(escaped)\")") || html.contains("pageLoad(getURL(\"\(page)\")")
    }

    static func stripComments(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    }

    /// Label/value pairs from `<td class="tdleft">` + `<td class="tdright">`.
    static func rows(in html: String) -> [(String, String)] {
        F460Page.matches(
            #"(?is)<td\s+class="tdleft(?:_1)?"[^>]*>(.*?)</td>\s*<td\b[^>]*class="tdright"[^>]*>(.*?)</td>"#,
            in: stripComments(html)
        ).map { (text($0[1]), text($0[2])) }
    }

    static func text(_ fragment: String) -> String {
        let stripped = fragment
            .replacingOccurrences(of: #"(?is)<script\b.*?</script\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[ampersand...]
            if let match = tail.prefixMatch(of: /&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});/) {
                let token = String(match.1)
                let value = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let value, let scalar = Unicode.Scalar(value) { result.unicodeScalars.append(scalar) }
                rest = tail[match.range.upperBound...]
            } else if let match = tail.prefixMatch(of: /&(amp|lt|gt|quot|apos|nbsp);/) {
                result += ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "][String(match.1)]!
                rest = tail[match.range.upperBound...]
            } else {
                result += "&"
                rest = tail.dropFirst()
            }
        }
        return result + rest
    }
}
