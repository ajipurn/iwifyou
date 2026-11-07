import CryptoKit
import Foundation

/// Parses the scalar initializers emitted by the observed F460 firmware.
/// No router JavaScript is executed and no credentials are persisted here.
struct F460Page {
    static let path = "getpage.gch?pid=1002&nextpage=pon_net_wlan_conf_t.gch"
    static let configurationKeys = [
        "Enable", "RadioStatus", "Standard", "BeaconInterval", "RtsCts", "Fragment", "DTIM",
        "TxPower", "CountryCode", "TxRate", "Channel", "ESSID", "ESSIDPrefix", "ACLPolicy",
        "BeaconType", "WEPAuthMode", "WEPEncryptionLevel", "WEPKeyIndex", "WPAAuthMode",
        "WPAEncryptType", "WPAGroupRekey", "WPAEAPServerIp", "RadiusPort", "RadiusServerPort",
        "WPAEAPSecret", "PossibleChannels", "BasicDataRates", "OpDataRates", "PossibleTxRates",
        "OOBAccessEnabled", "BeaconEnabled", "ESSIDHideEnable", "RegulatoryDomain", "WlanMode",
        "DistanceFromRoot", "PeerBSSID", "AuthServiceMode", "QosType", "Priority", "UAPSDEnabled",
        "AutoChannelEnabled", "ChannelsInUse", "11iAuthMode", "11iEncryptType", "MaxUserNum",
        "SSIDIsolationEnable", "VapIsolationEnable", "Band", "11nMode", "BandWidth", "SideBand",
        "11nRate", "SGIEnabled", "GreenField",
    ]
    static let secretKeys = ["PreSharedKey", "KeyPassphrase", "AssociatedDeviceMACAddress"]
    static let wepKeys = ["WEPKey", "WEPKey0", "WEPKey1", "WEPKey2", "WEPKey3"]

    private let fields: [String: String]

    func field(_ key: String) -> String? { fields[key] }
    var allFields: [String: String] { fields }
    let snapshot: RouterSnapshot

    init(html: String) throws {
        if Self.isAdminSessionInUse(html) { throw RouterError.adminSessionInUse }
        if Self.isLoginPage(html) || Self.isSessionTimeout(html) { throw RouterError.loginRequired }
        guard html.utf8.count < 2_000_000,
              html.contains("pon_net_wlan_conf_t.gch") || html.contains("pon\\x5fnet\\x5fwlan\\x5fconf\\x5ft\\x2egch"),
              let form = Self.matches(#"(?is)<form\b([^>]*)>(.*?)</form\s*>"#, in: html)
                .first(where: { Self.attributes(in: $0[1])["id"] == "fSubmit" }),
              Self.attributes(in: form[1])["method"]?.uppercased() == "POST",
              let declaration = Self.matches(#"var\s+CONFIG_PARA\s*=\s*new Array\(([^)]*)\)"#, in: html).first
        else { throw RouterError.unsupportedFirmware }

        let declared = Self.matches(#""([^"\\]*)""#, in: declaration[1]).map { $0[1] }
        guard declared == Self.configurationKeys else { throw RouterError.unsupportedFirmware }

        var fields: [String: String] = [:]
        for input in Self.matches(#"(?is)<input\b[^>]*>"#, in: form[2]) {
            let attributes = Self.attributes(in: input[0])
            guard attributes["type"]?.lowercased() == "hidden", let name = attributes["name"] else { continue }
            guard fields[name] == nil else { throw RouterError.unsupportedFirmware }
            fields[name] = attributes["value"] ?? ""
        }

        // Each initializer is a standalone script, and later assignments win.
        // Ignore function definitions and text inside other JavaScript strings.
        let scripts = Self.matches(#"(?is)<script\b[^>]*>(.*?)</script\s*>"#, in: html).map { $0[1] }
        for script in scripts {
            guard let assignment = Self.matches(
                #"^\s*Transfer_meaning\(\s*'([^'\\]+)'\s*,\s*'((?:\\.|[^'\\])*)'\s*\);\s*$"#,
                in: script
            ).first, fields[assignment[1]] != nil else { continue }
            fields[assignment[1]] = try Self.decodeJavaScriptString(assignment[2])
        }
        // The router appends this hidden input on window.onload. It is absent
        // from raw HTML, so reading <input> elements alone loses the CSRF token.
        fields["_SESSION_TOKEN"] = try Self.sessionToken(in: scripts, staticValue: fields["_SESSION_TOKEN"])
        let required = Self.configurationKeys + Self.secretKeys + Self.wepKeys + [
            "IF_ACTION", "IF_CONFIGTAG", "IF_PSKTAG", "IF_WEPKEYTAG", "IF_VIEWID", "IF_ERRORSTR", "IF_ERRORPARAM",
        ]
        guard required.allSatisfy({ fields[$0] != nil }),
              fields["Band"] == "2.4G", fields["IF_VIEWID"] == "IGD.LD1.WLAN1",
              ["0", "1"].contains(fields["AutoChannelEnabled"] ?? ""),
              ["0", "1"].contains(fields["RadioStatus"] ?? ""),
              let ssid = fields["ESSID"], !ssid.isEmpty,
              let width = fields["BandWidth"], ["20Mhz", "40Mhz", "Auto"].contains(width)
        else { throw RouterError.unsupportedFirmware }
        guard fields["IF_ERRORSTR"] == "SUCC", fields["IF_ERRORPARAM"] == "SUCC" else {
            if fields["IF_ERRORPARAM"] == "_SESSION_TOKEN" { throw RouterError.invalidSession }
            throw RouterError.rejected
        }

        // This mirrors Country_switch() in the inspected firmware, intersected
        // with the server's PossibleChannels so unavailable channels stay hidden.
        let country = fields["CountryCode"] ?? ""
        guard !country.isEmpty, let possible = fields["PossibleChannels"] else {
            throw RouterError.unsupportedFirmware
        }
        let channels = try Self.parseChannels(possible)
        let maximum = ["caI", "usI"].contains(country) ? 11 : 13
        let allowed = channels.filter { $0 <= maximum }
        guard !allowed.isEmpty else { throw RouterError.unsupportedFirmware }
        let channel: WiFiChannel
        if fields["AutoChannelEnabled"] == "1" {
            channel = .automatic
        } else {
            guard let number = Int(fields["Channel"] ?? ""), allowed.contains(number) else {
                throw RouterError.unsupportedFirmware
            }
            channel = .fixed(number)
        }
        self.fields = fields
        let protected = Self.configurationKeys + Self.secretKeys + Self.wepKeys + ["IF_VIEWID"]
        let otherKeys = protected.filter { !["Channel", "AutoChannelEnabled", "ChannelsInUse"].contains($0) }
        // In Auto mode Channel can change independently of the saved setting.
        let revisionKeys = fields["AutoChannelEnabled"] == "1" ? otherKeys + ["AutoChannelEnabled"] : otherKeys + ["Channel", "AutoChannelEnabled"]
        snapshot = RouterSnapshot(
            ssid: ssid, channel: channel,
            availableChannels: [.automatic] + allowed.map(WiFiChannel.fixed),
            bandwidth: width.replacingOccurrences(of: "Mhz", with: " MHz"),
            radioEnabled: fields["RadioStatus"] == "1",
            details: WLANDetails(fields: fields),
            revision: Self.fingerprint(fields, keys: revisionKeys),
            otherSettingsRevision: Self.fingerprint(fields, keys: otherKeys)
        )
    }

    func payload(for channel: WiFiChannel) throws -> Data {
        guard snapshot.radioEnabled else { throw RouterError.radioDisabled }
        guard snapshot.availableChannels.contains(channel) else { throw RouterError.unavailableChannel }
        var payload = fields
        // HiddenParaInit() in this firmware uses the literal NULL to leave a
        // parameter unchanged. Never replay SSIDs, keys, RF, or security values.
        for key in Self.configurationKeys + Self.secretKeys + Self.wepKeys { payload[key] = "NULL" }
        payload["IF_ACTION"] = "apply"
        payload["IF_CONFIGTAG"] = "Y"
        payload["IF_PSKTAG"] = "N"
        payload["IF_WEPKEYTAG"] = "N"
        payload["IF_WAPITAG"] = "N"
        switch channel {
        case .automatic:
            payload["AutoChannelEnabled"] = "1"
        case .fixed(let number):
            payload["Channel"] = String(number)
            payload["AutoChannelEnabled"] = "0"
        }
        return FormEncoding.data(payload)
    }

    /// Mirrors the observed onClickLogout(): logout=1 on flogout, with the
    /// token appended by addToken2AllForms(). Never use an unauthenticated form.
    static func logoutPayload(in html: String) throws -> Data {
        guard !isLoginPage(html), !isSessionTimeout(html), !isAdminSessionInUse(html),
              let form = matches(#"(?is)<form\b([^>]*)>(.*?)</form\s*>"#, in: html)
                .first(where: { attributes(in: $0[1])["id"] == "flogout" }),
              attributes(in: form[1])["method"]?.lowercased() == "post",
              attributes(in: form[1])["action"] == "/" else { throw RouterError.logoutUnavailable }
        let inputs = matches(#"(?is)<input\b[^>]*>"#, in: form[2]).map { attributes(in: $0[0]) }
        guard inputs.filter({ $0["name"] == "logout" && $0["type"]?.lowercased() == "hidden" }).count == 1 else {
            throw RouterError.logoutUnavailable
        }
        let scripts = matches(#"(?is)<script\b[^>]*>(.*?)</script\s*>"#, in: html).map { $0[1] }
        let staticToken = inputs.first { $0["name"] == "_SESSION_TOKEN" }?["value"]
        let token = try sessionToken(in: scripts, staticValue: staticToken)
        return FormEncoding.data(["logout": "1", "_SESSION_TOKEN": token])
    }

    static func isLoginPage(_ html: String) -> Bool {
        html.contains("Frm_Username") && html.contains("Frm_Password") && !html.contains("id=\"fSubmit\"")
    }

    static func isAdminSessionInUse(_ html: String) -> Bool {
        !html.contains("CONFIG_PARA")
            && html.contains("Another user has logged in to the system")
            && html.contains("please retry later")
    }

    static func isSessionTimeout(_ html: String) -> Bool {
        // The same timeout alert text also exists in authenticated pages.
        // Only the dedicated logout form marker proves that the session ended.
        let forms = matches(#"(?is)<form\b([^>]*)>(.*?)</form\s*>"#, in: html)
        return forms.contains { form in
            let attributes = attributes(in: form[1])
            guard attributes["id"] == "flogout" || attributes["name"] == "flogout" else { return false }
            return matches(#"(?is)<input\b[^>]*>"#, in: form[2]).contains { input in
                let attributes = self.attributes(in: input[0])
                return attributes["type"]?.lowercased() == "hidden"
                    && attributes["name"] == "logout_from" && attributes["value"] == "login_timeout"
            }
        }
    }

    static func loginToken(in html: String) throws -> String {
        if isAdminSessionInUse(html) { throw RouterError.adminSessionInUse }
        if isSessionTimeout(html) { throw RouterError.loginRequired }
        guard isLoginPage(html),
              let match = matches(#"getObj\("Frm_Logintoken"\)\.value\s*=\s*"([0-9]+)""#, in: html).first
        else { throw RouterError.unsupportedFirmware }
        return match[1]
    }

    static func sessionToken(in scripts: [String], staticValue: String?) throws -> String {
        let hooks = scripts.filter {
            !matches(#"function\s+addToken2AllForms\s*\(\s*\)"#, in: $0).isEmpty
        }
        guard hooks.count <= 1 else { throw RouterError.unsupportedFirmware }
        let token: String
        if let script = hooks.first {
            // Recognize the exact DOM hook observed on F460. Never execute it,
            // or accept an unrelated JavaScript variable as an auth token.
            let markers = [
                #"tokenInput\s*\.\s*setAttribute\(\s*["']name["']\s*,\s*["']_SESSION_TOKEN["']\s*\)"#,
                #"tokenInput\s*\.\s*setAttribute\(\s*["']type["']\s*,\s*["']hidden["']\s*\)"#,
                #"tokenInput\s*\.\s*setAttribute\(\s*["']value["']\s*,\s*session_token\s*\)"#,
                #"tempform\s*\.\s*appendChild\(\s*tokenInput\s*\)"#,
                #"(?:^|[;}\r\n])\s*addToken2AllForms\s*\(\s*\)\s*;"#,
            ]
            guard markers.allSatisfy({ !matches($0, in: script).isEmpty }) else {
                throw RouterError.unsupportedFirmware
            }
            let assignments = matches(
                #"\bvar\s+session_token\s*=\s*(?:'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)")\s*;"#,
                in: script
            )
            guard assignments.count == 1, let assignment = assignments.first else {
                throw RouterError.unsupportedFirmware
            }
            token = try decodeJavaScriptString(assignment[1].isEmpty ? assignment[2] : assignment[1])
            guard staticValue == nil || staticValue == token else { throw RouterError.unsupportedFirmware }
        } else if let staticValue {
            token = staticValue
        } else {
            throw RouterError.unsupportedFirmware
        }
        guard !token.isEmpty, token.utf8.count <= 256, token != "NULL",
              token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw RouterError.unsupportedFirmware
        }
        return token
    }

    static func parseChannels(_ text: String) throws -> [Int] {
        var channels = Set<Int>()
        for component in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = component.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), (1...13).contains(first) else {
                throw RouterError.unsupportedFirmware
            }
            let last = bounds.count == 2 ? Int(bounds[1]) : first
            guard let last, (first...13).contains(last) else { throw RouterError.unsupportedFirmware }
            channels.formUnion(first...last)
        }
        return channels.sorted()
    }

    static func decodeJavaScriptString(_ input: String) throws -> String {
        let scalars = Array(input.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar != "\\" { result.append(scalar); continue }
            guard index < scalars.count else { throw RouterError.unsupportedFirmware }
            let escape = scalars[index]
            index += 1
            switch escape {
            case "\\", "'", "\"", "/": result.append(escape)
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "x", "u":
                let count = escape == "x" ? 2 : 4
                guard index + count <= scalars.count,
                      let value = UInt32(String(String.UnicodeScalarView(scalars[index..<(index + count)])), radix: 16),
                      let decoded = Unicode.Scalar(value)
                else { throw RouterError.unsupportedFirmware }
                result.append(decoded)
                index += count
            default: throw RouterError.unsupportedFirmware
            }
        }
        return String(result)
    }

    static func fingerprint(_ fields: [String: String], keys: [String]) -> String {
        SHA256.hash(data: FormEncoding.data(Dictionary(uniqueKeysWithValues: keys.map { ($0, fields[$0] ?? "") })))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in matches(#"([a-zA-Z_][\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: tag) {
            result[match[1].lowercased()] = match[2...4].first { !$0.isEmpty } ?? ""
        }
        return result
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
}
