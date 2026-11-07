import Foundation

// MARK: - Shared validation

public enum IPv4 {
    public static func normalize(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), let value = Int(part), (0...255).contains(value) else { return nil }
            return value
        }
        guard numbers.count == 4 else { return nil }
        return numbers.map(String.init).joined(separator: ".")
    }

    static func number(_ text: String) -> UInt32? {
        guard let normalized = normalize(text) else { return nil }
        return normalized.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | UInt32($1)! }
    }

    /// A unicast host address, as the router's checkIP/checkIPZero accept.
    static func isHost(_ text: String) -> Bool {
        guard let value = number(text) else { return false }
        let last = value & 0xFF
        return value != 0 && value != .max && last != 0 && last != 255 && value >> 24 != 127 && value >> 28 != 0xE
    }
}

/// The firmware counts characters outside Latin-1 twice and rejects them in
/// its own checks; iwifyou is stricter and allows printable ASCII only.
enum FormText {
    static func isPrintableASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }
}

// MARK: - DHCP reservations

public struct DHCPReservation: Hashable, Sendable, Identifiable {
    public let ip: String
    public let mac: String
    public var id: String { mac }
}

public struct DHCPReservations: Equatable, Sendable {
    /// Router order; nil marks a row iwifyou could not read as a reservation.
    public let entries: [DHCPReservation?]
    public let poolStart: String
    public let poolEnd: String
    let revision: String

    public var reservations: [DHCPReservation] { entries.compactMap { $0 } }

    public func contains(ip: String) -> Bool {
        guard let value = IPv4.number(ip), let start = IPv4.number(poolStart), let end = IPv4.number(poolEnd) else { return false }
        return value >= start && value <= end
    }

    public static let demo = DHCPReservations(
        entries: [DHCPReservation(ip: "192.168.1.20", mac: "02:00:00:00:00:03")],
        poolStart: "192.168.1.2", poolEnd: "192.168.1.254", revision: "demo"
    )
}

/// Network > LAN > Static allocation. Add() → `new`, Delete(i) → `delete`.
struct F460DHCPStatic {
    static let page = "net_dhcp_static_t.gch"
    static let keys = ["ViewName", "HostCfgViewName", "IPAddr", "MACAddr"]

    let form: F460Form
    let state: DHCPReservations

    init(form: F460Form) throws {
        guard form.page == Self.page,
              form.declaredArray("DHCPS_PARA") == Self.keys,
              form.declaredArray("DHCPSTATIC_PARA") == ["IPAddr", "MACAddr"],
              (Self.keys + ["IF_INDEX", "IF_INSTNUM"]).allSatisfy({ form.fields[$0] != nil }),
              let start = form.scriptValues["MinAddress"].flatMap(IPv4.normalize),
              let end = form.scriptValues["MaxAddress"].flatMap(IPv4.normalize),
              IPv4.number(start)! <= IPv4.number(end)!
        else { throw RouterError.unsupportedFirmware }
        let count = try form.count("IF_INSTNUM")
        var revisionKeys = ["IF_INSTNUM"]
        let entries: [DHCPReservation?] = try (0..<count).map { index in
            revisionKeys += ["IPAddr\(index)", "MACAddr\(index)"]
            let ip = try form.value("IPAddr\(index)")
            let mac = try form.value("MACAddr\(index)")
            guard let ip = IPv4.normalize(ip), let mac = MACAddress.normalize(mac) else { return nil }
            return DHCPReservation(ip: ip, mac: mac)
        }
        self.form = form
        state = DHCPReservations(entries: entries, poolStart: start, poolEnd: end,
                                 revision: F460Page.fingerprint(form.fields, keys: revisionKeys))
    }

    func addPayload(ip input: String, mac macInput: String) throws -> Data {
        guard let mac = MACAddress.normalize(macInput) else { throw RouterError.invalidDevice }
        guard let ip = IPv4.normalize(input), IPv4.isHost(ip), state.contains(ip: ip) else { throw RouterError.invalidAddressInPool }
        guard !state.reservations.contains(where: { $0.ip == ip || $0.mac == mac }) else { throw RouterError.duplicateEntry }
        var payload = form.fields
        for key in Self.keys { payload[key] = "NULL" } // HiddenParaInit(DHCPS_PARA)
        payload["IPAddr"] = ip
        payload["MACAddr"] = mac
        payload["IF_ACTION"] = "new"
        payload["IF_INDEX"] = "-1"
        return FormEncoding.data(payload)
    }

    func removePayload(mac: String) throws -> Data {
        let matches = state.entries.indices.filter { state.entries[$0]?.mac == mac }
        guard matches.count == 1, let index = matches.first else { throw RouterError.invalidDevice }
        var payload = form.fields
        payload["IF_ACTION"] = "delete"
        payload["IF_INDEX"] = String(index)
        return FormEncoding.data(payload)
    }
}

// MARK: - Port forwarding

public enum PortProtocol: String, CaseIterable, Sendable, Identifiable {
    case tcp = "0", udp = "1", both = "2"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .both: "TCP + UDP"
        }
    }
}

public struct WANConnection: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

public struct PortForward: Hashable, Sendable, Identifiable {
    public let name: String
    public let proto: PortProtocol
    public let externalStart: Int
    public let externalEnd: Int
    public let internalHost: String
    public let internalPort: Int
    public let enabled: Bool

    public var id: String { name }

    public init(name: String, proto: PortProtocol, externalStart: Int, externalEnd: Int, internalHost: String, internalPort: Int, enabled: Bool = true) {
        self.name = name
        self.proto = proto
        self.externalStart = externalStart
        self.externalEnd = externalEnd
        self.internalHost = internalHost
        self.internalPort = internalPort
        self.enabled = enabled
    }
}

public struct PortForwards: Equatable, Sendable {
    public let entries: [PortForward?]
    public let connections: [WANConnection]
    let revision: String

    public var rules: [PortForward] { entries.compactMap { $0 } }

    public static let demo = PortForwards(
        entries: [PortForward(name: "CCTV", proto: .tcp, externalStart: 8080, externalEnd: 8080, internalHost: "192.168.1.20", internalPort: 80)],
        connections: [WANConnection(id: "IGD.WD1.WCD1.WCPPP1", name: "1_INTERNET_R_VID_45")], revision: "demo"
    )
}

/// Application > Advanced NAT > Virtual host. pageAdd() → `new`,
/// pageDel(i) → `delete`; pageSetValue() fills the rule after NULLing.
struct F460PortForward {
    static let page = "app_virtual_conf_t.gch"
    static let ruleKeys = [
        "Enable", "Name", "Protocol", "MinRemoteHost", "MaxRemoteHost", "MinExtPort", "MaxExtPort",
        "MinIntPort", "MaxIntPort", "WANCViewName", "InternalHost", "InternalMacHost", "MacEnable",
    ]
    static let otherKeys = ["ViewName", "WANCName", "MaxIntPort", "Description", "LeaseDuration", "PortMappCreator"]

    let form: F460Form
    let state: PortForwards

    init(form: F460Form) throws {
        guard form.page == Self.page,
              form.declaredArray("FWPMSTATIC_PARA") == Self.ruleKeys,
              form.declaredArray("OTHER_PARA") == Self.otherKeys,
              (Self.ruleKeys + Self.otherKeys + ["IF_INDEX", "IF_INSTNUM"]).allSatisfy({ form.fields[$0] != nil })
        else { throw RouterError.unsupportedFirmware }
        let select = F460Page.matches(#"(?is)<select\b[^>]*\bid="Frm_WANCViewName"[^>]*>(.*?)</select>"#, in: form.html)
        guard let options = select.first?[1] else { throw RouterError.unsupportedFirmware }
        let connections = F460Page.matches(#"(?is)<option\b[^>]*\bvalue="([^"]+)"[^>]*>(.*?)</option>"#, in: options)
            .map { WANConnection(id: $0[1], name: F460Status.text($0[2])) }
        let count = try form.count("IF_INSTNUM")
        var revisionKeys = ["IF_INSTNUM"]
        let entries: [PortForward?] = try (0..<count).map { index in
            let keys = ["Enable", "Name", "Protocol", "MinExtPort", "MaxExtPort", "InternalHost", "MinIntPort"]
            revisionKeys += keys.map { $0 + String(index) }
            let values = try keys.map { try form.value($0 + String(index)) }
            guard let proto = PortProtocol(rawValue: values[2]),
                  let start = Int(values[3]), let end = Int(values[4]), let port = Int(values[6]),
                  let host = IPv4.normalize(values[5]) else { return nil }
            return PortForward(name: values[1], proto: proto, externalStart: start, externalEnd: end,
                               internalHost: host, internalPort: port, enabled: values[0] == "1")
        }
        self.form = form
        state = PortForwards(entries: entries, connections: connections,
                             revision: F460Page.fingerprint(form.fields, keys: revisionKeys))
    }

    func addPayload(_ rule: PortForward, connection: WANConnection) throws -> Data {
        guard state.connections.contains(connection) else { throw RouterError.unsupportedFirmware }
        guard (1...32).contains(rule.name.count), FormText.isPrintableASCII(rule.name),
              !rule.name.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw RouterError.invalidRule("Nama aturan harus 1–32 karakter ASCII.") }
        guard !state.rules.contains(where: { $0.name == rule.name }) else { throw RouterError.duplicateEntry }
        guard (1...65535).contains(rule.externalStart), (1...65535).contains(rule.externalEnd),
              (1...65535).contains(rule.internalPort), rule.externalStart <= rule.externalEnd
        else { throw RouterError.invalidRule("Port harus 1–65535, dan port awal tidak boleh lebih besar dari port akhir.") }
        guard let host = IPv4.normalize(rule.internalHost), IPv4.isHost(host) else {
            throw RouterError.invalidRule("Alamat IP perangkat tujuan tidak valid.")
        }
        var payload = form.fields
        for key in Self.ruleKeys + Self.otherKeys { payload[key] = "NULL" }
        payload["Enable"] = rule.enabled ? "1" : "0"
        payload["Name"] = rule.name
        payload["Protocol"] = rule.proto.rawValue
        payload["MinRemoteHost"] = "0.0.0.0"
        payload["MaxRemoteHost"] = "0.0.0.0"
        payload["WANCViewName"] = connection.id
        payload["MinExtPort"] = String(rule.externalStart)
        payload["MaxExtPort"] = String(rule.externalEnd)
        payload["MacEnable"] = "0"
        payload["InternalHost"] = host
        payload["MinIntPort"] = String(rule.internalPort)
        payload["MaxIntPort"] = String(rule.internalPort)
        payload["IF_ACTION"] = "new"
        payload["IF_INDEX"] = "-1"
        return FormEncoding.data(payload)
    }

    func removePayload(name: String) throws -> Data {
        let matches = state.entries.indices.filter { state.entries[$0]?.name == name }
        guard matches.count == 1, let index = matches.first else { throw RouterError.invalidDevice }
        var payload = form.fields
        payload["IF_ACTION"] = "delete"
        payload["IF_INDEX"] = String(index)
        return FormEncoding.data(payload)
    }
}

// MARK: - Website blocking

public struct SiteFilter: Equatable, Sendable {
    public enum Mode: String, Sendable { case blacklist = "0", whitelist = "1" }

    public let enabled: Bool
    public let mode: Mode
    public let entries: [String?]
    let revision: String

    public var sites: [String] { entries.compactMap { $0 } }
    public var canBlock: Bool { mode == .blacklist || entries.isEmpty }

    public static let demo = SiteFilter(enabled: true, mode: .blacklist, entries: ["situs-contoh.example"], revision: "demo")

    /// Strips a scheme and trailing slash; returns nil for text the
    /// router's CheckURL() would reject.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        while text.hasSuffix("/") { text.removeLast() }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.:;,!@%#?_/&=+*'$()-")
        guard (1...256).contains(text.count), text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text.lowercased()
    }
}

/// Security > Wan access settings (URL filter). Slect_Enable() →
/// `basic_apply`, Add() → `new`, Delete(i) → `delete`.
struct F460URLFilter {
    static let page = "sec_url_filter_t.gch"
    static let duplicates: Set<String> = ["IF_INSTNUM"]
    static let ruleKeys = ["ViewName", "Enable", "Url", "FilterTarget"]
    static let basicKeys = ["IsWanSrvCntl", "IpFilterTarget", "UrlFilterTarget", "UrlFilterEnable", "SrvCntlTarget", "DefaultPolicy"]

    let form: F460Form
    let state: SiteFilter

    init(form: F460Form) throws {
        guard form.page == Self.page,
              form.declaredArray("URL_PARA") == Self.ruleKeys,
              form.declaredArray("URL_BASIC_PARA") == Self.basicKeys,
              (Self.ruleKeys + Self.basicKeys + ["IF_INDEX", "IF_INSTNUM"]).allSatisfy({ form.fields[$0] != nil }),
              let enabled = form.fields["UrlFilterEnable"], ["0", "1"].contains(enabled),
              let mode = form.fields["UrlFilterTarget"].flatMap(SiteFilter.Mode.init(rawValue:))
        else { throw RouterError.unsupportedFirmware }
        // The first IF_INSTNUM input is empty; the count arrives by script.
        guard let countText = form.scriptValues["IF_INSTNUM"], let count = Int(countText), (0...256).contains(count) else {
            throw RouterError.unsupportedFirmware
        }
        var revisionKeys = Self.basicKeys
        let entries: [String?] = try (0..<count).map { index in
            revisionKeys.append("Url\(index)")
            let url = try form.value("Url\(index)")
            return url.isEmpty ? nil : url.lowercased()
        }
        self.form = form
        var fingerprintFields = form.fields
        fingerprintFields["IF_INSTNUM"] = countText
        state = SiteFilter(enabled: enabled == "1", mode: mode, entries: entries,
                           revision: F460Page.fingerprint(fingerprintFields, keys: revisionKeys + ["IF_INSTNUM"]))
    }

    func enablePayload() throws -> Data {
        guard state.canBlock else { throw RouterError.filterModeUnsupported }
        var payload = form.fields
        for key in Self.basicKeys { payload[key] = "NULL" } // HiddenParaInit(URL_BASIC_PARA)
        payload["UrlFilterEnable"] = "1"
        payload["UrlFilterTarget"] = SiteFilter.Mode.blacklist.rawValue
        payload["IF_ACTION"] = "basic_apply"
        return FormEncoding.data(payload)
    }

    func addPayload(_ input: String) throws -> Data {
        guard state.enabled, state.mode == .blacklist else { throw RouterError.filterModeUnsupported }
        guard let url = SiteFilter.normalize(input) else {
            throw RouterError.invalidRule("Alamat situs hanya boleh berisi huruf, angka, dan tanda baca URL (maks. 256).")
        }
        guard !state.sites.contains(url) else { throw RouterError.duplicateEntry }
        var payload = form.fields
        for key in Self.ruleKeys { payload[key] = "NULL" } // HiddenParaInit(URL_PARA)
        payload["Url"] = url
        payload["Enable"] = "0"
        payload["FilterTarget"] = "0"
        payload["IF_ACTION"] = "new"
        payload["IF_INDEX"] = "-1"
        return FormEncoding.data(payload)
    }

    func removePayload(_ url: String) throws -> Data {
        guard state.mode == .blacklist else { throw RouterError.filterModeUnsupported }
        let matches = state.entries.indices.filter { state.entries[$0] == url }
        guard matches.count == 1, let index = matches.first else { throw RouterError.invalidDevice }
        var payload = form.fields
        payload["IF_ACTION"] = "delete"
        payload["IF_INDEX"] = String(index)
        return FormEncoding.data(payload)
    }
}

// MARK: - Wi-Fi name and password

public enum WiFiCredentials {
    /// pageSubmit() limits: SSID 1–32, WPA passphrase 8–63.
    public static func validSSID(_ text: String) -> Bool {
        (1...32).contains(text.utf8.count) && FormText.isPrintableASCII(text)
            && text.trimmingCharacters(in: .whitespaces) == text
    }

    public static func validPassphrase(_ text: String) -> Bool {
        (8...63).contains(text.count) && FormText.isPrintableASCII(text)
    }
}

extension F460Page {
    static let pskBeaconTypes = ["WPA", "11i", "WPAand11i"]

    var usesPassphrase: Bool {
        guard let beacon = field("BeaconType"), Self.pskBeaconTypes.contains(beacon) else { return false }
        let auth = beacon == "WPA" ? field("WPAAuthMode") : field("11iAuthMode")
        return auth == "PSKAuthentication"
    }

    /// Compared in memory only; the passphrase never leaves this type.
    func hasPassphrase(_ candidate: String) -> Bool { field("KeyPassphrase") == candidate }

    /// Everything except the name and passphrase, to prove nothing else moved.
    var settingsRevisionExcludingCredentials: String {
        let keys = (Self.configurationKeys + Self.secretKeys + Self.wepKeys + ["IF_VIEWID"])
            .filter { !["ESSID", "KeyPassphrase", "PreSharedKey", "Channel", "ChannelsInUse"].contains($0) }
        return F460Page.fingerprint(allFields, keys: keys)
    }

    /// Mirrors pageSubmit() → pageSetValue() for the SSID and WPA key only.
    /// Fields the page would rewrite with their current values are sent as
    /// those values; everything else stays NULL (unchanged).
    func credentialsPayload(ssid: String?, passphrase: String?) throws -> Data {
        guard ssid != nil || passphrase != nil else { throw RouterError.invalidRule("Tidak ada yang diubah.") }
        guard field("ESSIDPrefix") == "" else { throw RouterError.unsupportedFirmware }
        var payload = allFields
        for key in Self.configurationKeys + Self.secretKeys + Self.wepKeys { payload[key] = "NULL" }
        payload["IF_ACTION"] = "apply"
        payload["IF_CONFIGTAG"] = "Y"
        payload["IF_WEPKEYTAG"] = "N"
        payload["IF_WAPITAG"] = "N"
        payload["IF_PSKTAG"] = "N"
        if let ssid {
            guard WiFiCredentials.validSSID(ssid) else {
                throw RouterError.invalidRule("Nama Wi-Fi harus 1–32 karakter ASCII tanpa spasi di awal atau akhir.")
            }
            payload["Enable"] = field("Enable")
            payload["ESSID"] = ssid
        }
        if let passphrase {
            guard usesPassphrase else { throw RouterError.unsupportedFirmware }
            guard WiFiCredentials.validPassphrase(passphrase) else {
                throw RouterError.invalidRule("Password Wi-Fi harus 8–63 karakter ASCII.")
            }
            payload["IF_PSKTAG"] = "Y"
            // The same keys pageSetValue() writes for the current WPA mode.
            let keys = switch field("BeaconType") {
            case "WPA": ["BeaconType", "WPAAuthMode", "WPAEncryptType", "WPAGroupRekey"]
            case "11i": ["BeaconType", "11iAuthMode", "11iEncryptType", "WPAGroupRekey"]
            default: ["BeaconType", "WPAAuthMode", "11iAuthMode", "WPAEncryptType", "11iEncryptType", "WPAGroupRekey"]
            }
            for key in keys { payload[key] = field(key) }
            payload["KeyPassphrase"] = passphrase
        }
        return FormEncoding.data(payload)
    }
}

// MARK: - DNS blocking through Hosts

public struct HostEntry: Hashable, Sendable, Identifiable {
    public let name: String
    public let address: String
    public var id: String { name }
    public var isBlock: Bool { address == DNSBlocklist.sinkhole }
}

public struct DNSBlocklist: Equatable, Sendable {
    /// Verified on the F460: the router's DNS answers this address and
    /// connections to it fail immediately, HTTPS included.
    public static let sinkhole = "0.0.0.0"
    public static let capacity = 50

    public let entries: [HostEntry?]
    let revision: String

    public var hosts: [HostEntry] { entries.compactMap { $0 } }
    public var blockedNames: Set<String> { Set(hosts.filter(\.isBlock).map(\.name)) }

    public static let demo = DNSBlocklist(
        entries: SitePreset.youtube.hosts.map { HostEntry(name: $0, address: sinkhole) }, revision: "demo"
    )

    public func demoAdding(_ names: [String]) -> DNSBlocklist {
        let fresh = names.filter { name in !hosts.contains { $0.name == name } }.map { HostEntry(name: $0, address: Self.sinkhole) }
        return DNSBlocklist(entries: entries + fresh, revision: "demo")
    }

    public func demoRemoving(_ names: Set<String>) -> DNSBlocklist {
        DNSBlocklist(entries: entries.filter { $0.map { !names.contains($0.name) } ?? true }, revision: "demo")
    }

    /// Mirrors the page's checkHostName(): letters, digits, `_.-`, starting
    /// and ending with a letter or digit, last label not all digits.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyz_.-")
        guard (1...253).contains(text.count), text.unicodeScalars.allSatisfy(allowed.contains),
              let first = text.first, let last = text.last, first.isLetter || first.isNumber, last.isLetter || last.isNumber,
              let tld = text.split(separator: ".").last, !tld.allSatisfy(\.isNumber), !text.contains("..")
        else { return nil }
        return text
    }

    /// The site a name belongs to, without the `www.` or `m.` prefix.
    public static func site(of name: String) -> String {
        for prefix in ["www.", "m."] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }

    /// Hosts entries match exact names only, so a domain needs its common
    /// prefixes listed explicitly.
    public static func names(forDomain input: String) -> [String] {
        guard var domain = normalize(input) else { return [] }
        for prefix in ["www.", "m."] where domain.hasPrefix(prefix) { domain = String(domain.dropFirst(prefix.count)) }
        return [domain, "www." + domain, "m." + domain]
    }
}

public enum SitePreset: String, CaseIterable, Sendable, Identifiable {
    case youtube, tiktok

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .youtube: "YouTube"
        case .tiktok: "TikTok"
        }
    }

    /// Entry points for the web site and app APIs. Video CDNs use
    /// unbounded random names and cannot be listed in Hosts.
    public var hosts: [String] {
        switch self {
        case .youtube:
            ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
             "youtubei.googleapis.com", "youtube.googleapis.com", "i.ytimg.com", "yt3.ggpht.com"]
        case .tiktok:
            ["tiktok.com", "www.tiktok.com", "m.tiktok.com", "vm.tiktok.com", "vt.tiktok.com",
             "tiktokv.com", "www.tiktokv.com", "api.tiktokv.com", "tiktokcdn.com"]
        }
    }
}

/// Application > Daily app > Hosts. Add() → `new` after
/// HiddenParaInit(DNSHOST_PARA); Delete(i) → `delete` with IF_INDEX.
struct F460Hosts {
    static let page = "app_dev_name_t.gch"
    /// The observed form repeats these two inputs.
    static let duplicates: Set<String> = ["HOST_ERRORSTR", "DNSDHCP_ERRORSTR"]
    static let keys = ["HostName", "IPAddress"]

    let form: F460Form
    let state: DNSBlocklist

    init(form: F460Form) throws {
        guard form.page == Self.page,
              form.declaredArray("DNSHOST_PARA") == Self.keys,
              form.declaredArray("DNSDHCP_PARA") == Self.keys,
              (Self.keys + ["IF_INDEX", "HOST_INSTNUM"]).allSatisfy({ form.fields[$0] != nil })
        else { throw RouterError.unsupportedFirmware }
        guard form.scriptValues["HOST_ERRORSTR"] == "SUCC" else {
            if form.scriptValues["HOST_ERRORPARAM"] == "_SESSION_TOKEN" { throw RouterError.invalidSession }
            throw RouterError.rejected
        }
        let count = try form.count("HOST_INSTNUM", limit: 64)
        var revisionKeys = ["HOST_INSTNUM"]
        let entries: [HostEntry?] = try (0..<count).map { index in
            revisionKeys += ["HostName\(index)", "IPAddress\(index)"]
            let name = try form.value("HostName\(index)").lowercased()
            let address = try form.value("IPAddress\(index)")
            guard !name.isEmpty, let ip = IPv4.normalize(address) else { return nil }
            return HostEntry(name: name, address: ip)
        }
        self.form = form
        state = DNSBlocklist(entries: entries, revision: F460Page.fingerprint(form.fields, keys: revisionKeys))
    }

    func addPayload(_ input: String) throws -> Data {
        guard let name = DNSBlocklist.normalize(input) else {
            throw RouterError.invalidRule("Nama situs hanya boleh berisi huruf, angka, titik, - dan _.")
        }
        guard !state.hosts.contains(where: { $0.name == name }) else { throw RouterError.duplicateEntry }
        guard state.entries.count < DNSBlocklist.capacity else {
            throw RouterError.invalidRule("Daftar Hosts router penuh (maks. \(DNSBlocklist.capacity) entri).")
        }
        var payload = form.fields
        for key in Self.keys { payload[key] = "NULL" }
        payload["HostName"] = name
        payload["IPAddress"] = DNSBlocklist.sinkhole
        payload["IF_ACTION"] = "new"
        payload["IF_INDEX"] = "-1"
        return FormEncoding.data(payload)
    }

    func removePayload(_ name: String) throws -> Data {
        let matches = state.entries.indices.filter { state.entries[$0]?.name == name }
        guard matches.count == 1, let index = matches.first else { throw RouterError.invalidDevice }
        var payload = form.fields
        payload["IF_ACTION"] = "delete"
        payload["IF_INDEX"] = String(index)
        return FormEncoding.data(payload)
    }
}
