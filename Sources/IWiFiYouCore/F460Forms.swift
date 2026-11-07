import Foundation

/// The `fSubmit` form of one observed F460 page: hidden inputs with their
/// `Transfer_meaning(...)` values applied, plus the session token the
/// firmware appends on load. Nothing here executes router JavaScript.
struct F460Form {
    let page: String
    let fields: [String: String]
    /// Every standalone `Transfer_meaning` assignment on the page, including
    /// elements outside `fSubmit` (for example the DHCP pool bounds).
    let scriptValues: [String: String]
    let html: String

    var path: String { Self.path(page) }

    static func path(_ page: String) -> String { "getpage.gch?pid=1002&nextpage=" + page }

    /// `allowingDuplicates` names hidden inputs the firmware repeats inside
    /// `fSubmit`; the first element keeps the value, as getElementById would.
    init(html: String, page: String, allowingDuplicates: Set<String> = []) throws {
        if F460Page.isAdminSessionInUse(html) { throw RouterError.adminSessionInUse }
        if F460Page.isLoginPage(html) || F460Page.isSessionTimeout(html) { throw RouterError.loginRequired }
        let escaped = page.replacingOccurrences(of: "_", with: "\\x5f").replacingOccurrences(of: ".", with: "\\x2e")
        // Every inspected page binds its form with pageLoad(getURL("<page>")).
        guard html.utf8.count < 2_000_000,
              html.contains("pageLoad(getURL(\"\(escaped)\")") || html.contains("pageLoad(getURL(\"\(page)\")"),
              let form = F460Page.matches(#"(?is)<form\b([^>]*)>(.*?)</form\s*>"#, in: html)
                .first(where: { F460Page.attributes(in: $0[1])["id"] == "fSubmit" }),
              F460Page.attributes(in: form[1])["method"]?.uppercased() == "POST"
        else { throw RouterError.unsupportedFirmware }

        var fields: [String: String] = [:]
        for input in F460Page.matches(#"(?is)<input\b[^>]*>"#, in: form[2]) {
            let attributes = F460Page.attributes(in: input[0])
            guard attributes["type"]?.lowercased() == "hidden", let name = attributes["name"] else { continue }
            if fields[name] != nil {
                guard allowingDuplicates.contains(name) else { throw RouterError.unsupportedFirmware }
                continue
            }
            fields[name] = attributes["value"] ?? ""
        }
        let scripts = F460Page.matches(#"(?is)<script\b[^>]*>(.*?)</script\s*>"#, in: html).map { $0[1] }
        var scriptValues: [String: String] = [:]
        for script in scripts {
            guard let assignment = F460Page.matches(
                #"^\s*Transfer_meaning\(\s*'([^'\\]+)'\s*,\s*'((?:\\.|[^'\\])*)'\s*\);\s*$"#,
                in: script
            ).first else { continue }
            if fields[assignment[1]] != nil {
                let value = try F460Page.decodeJavaScriptString(assignment[2])
                fields[assignment[1]] = value
                scriptValues[assignment[1]] = value
            } else {
                // Values outside the form are informational only.
                scriptValues[assignment[1]] = try? F460Page.decodeJavaScriptString(assignment[2])
            }
        }
        fields["_SESSION_TOKEN"] = try F460Page.sessionToken(in: scripts, staticValue: fields["_SESSION_TOKEN"])
        guard ["IF_ACTION", "IF_ERRORSTR", "IF_ERRORPARAM"].allSatisfy({ fields[$0] != nil }) else {
            throw RouterError.unsupportedFirmware
        }
        guard fields["IF_ERRORSTR"] == "SUCC", fields["IF_ERRORPARAM"] == "SUCC" else {
            if fields["IF_ERRORPARAM"] == "_SESSION_TOKEN" { throw RouterError.invalidSession }
            throw RouterError.rejected
        }
        self.page = page
        self.fields = fields
        self.scriptValues = scriptValues
        self.html = html
    }

    /// Mirrors `var NAME = new Array("a","b")` so a changed form fails closed.
    func declaredArray(_ name: String) -> [String]? {
        guard let declaration = F460Page.matches(#"var\s+\#(name)\s*=\s*new Array\(([^)]*)\)"#, in: html).first else {
            return nil
        }
        return F460Page.matches(#""([^"\\]*)""#, in: declaration[1]).map { $0[1] }
    }

    func count(_ key: String, limit: Int = 256) throws -> Int {
        guard let text = fields[key], let count = Int(text), (0...limit).contains(count) else {
            throw RouterError.unsupportedFirmware
        }
        return count
    }

    func value(_ key: String) throws -> String {
        guard let value = fields[key] else { throw RouterError.unsupportedFirmware }
        return value
    }
}

public enum MACAddress {
    /// Lowercase colon form, or nil when the input is not a unicast MAC.
    public static func normalize(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).lowercased()
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        let value = parts.joined(separator: ":")
        guard value != "00:00:00:00:00:00", value != "ff:ff:ff:ff:ff:ff",
              let first = UInt8(parts[0], radix: 16), first & 1 == 0 else { return nil }
        return value
    }
}

public struct ConnectedDevice: Hashable, Sendable, Identifiable {
    public let mac: String
    public let ip: String
    public let hostName: String?
    /// "SSID1".."SSID4" for Wi-Fi, "LAN1".."LAN4" for Ethernet.
    public let port: String
    public let kind: String?
    public let leaseSeconds: Int?

    public var id: String { mac }
    public var isWireless: Bool { port.uppercased().hasPrefix("SSID") }

    public init(mac: String, ip: String, hostName: String?, port: String, kind: String?, leaseSeconds: Int?) {
        self.mac = mac
        self.ip = ip
        self.hostName = hostName
        self.port = port
        self.kind = kind
        self.leaseSeconds = leaseSeconds
    }
}

public struct MACFilterState: Equatable, Sendable {
    public enum Mode: String, Sendable { case blacklist = "Discard", whitelist = "Permit" }

    public let enabled: Bool
    public let mode: Mode
    /// Source MACs in router order; the index is the router's IF_INDEX.
    public let entries: [String?]
    let revision: String

    public var blockedMACs: Set<String> { Set(entries.compactMap { $0 }) }

    /// A whitelist, or a disabled list that would flip meaning when enabled
    /// as a blacklist, must be managed in the router's own panel.
    public var canBlock: Bool { mode == .blacklist || entries.isEmpty }
}

public struct DeviceList: Equatable, Sendable {
    public let devices: [ConnectedDevice]
    /// MACs present in the router's ARP table at read time.
    public let activeMACs: Set<String>
    public let filter: MACFilterState

    public static let demo = DeviceList(
        devices: [
            ConnectedDevice(mac: "02:00:00:00:00:01", ip: "192.168.1.3", hostName: "MacBook-Demo", port: "SSID1", kind: "Computer", leaseSeconds: 84_000),
            ConnectedDevice(mac: "02:00:00:00:00:02", ip: "192.168.1.4", hostName: nil, port: "SSID1", kind: "Computer", leaseSeconds: 80_120),
            ConnectedDevice(mac: "02:00:00:00:00:03", ip: "192.168.1.5", hostName: "android-tv", port: "LAN1", kind: "Computer", leaseSeconds: 61_500),
        ],
        activeMACs: ["02:00:00:00:00:01", "02:00:00:00:00:02"],
        filter: MACFilterState(enabled: false, mode: .blacklist, entries: [], revision: "demo")
    )

    public func demoBlocking(_ mac: String, _ blocked: Bool) -> DeviceList {
        var entries = filter.entries.filter { $0 != mac }
        if blocked { entries.append(mac) }
        return DeviceList(
            devices: devices, activeMACs: activeMACs,
            filter: MACFilterState(enabled: filter.enabled || blocked, mode: .blacklist, entries: entries, revision: "demo")
        )
    }
}

enum F460Devices {
    static let lanPage = "status_lan_info_t.gch"
    static let arpPage = "diag_netDiag_arpTable_t.gch"

    static func devices(_ form: F460Form) throws -> [ConnectedDevice] {
        guard form.page == lanPage,
              form.declaredArray("DHCPHOSTINFO_PARA") == ["HostName", "MACAddr", "IPAddr", "ExpiredTime", "PhyType"]
        else { throw RouterError.unsupportedFirmware }
        let count = try form.count("IF_INSTNUM")
        return try (0..<count).map { index in
            guard let mac = MACAddress.normalize(try form.value("MACAddr\(index)")) else {
                throw RouterError.unsupportedFirmware
            }
            let host = try form.value("HostName\(index)").trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = try form.value("PhyType\(index)")
            return ConnectedDevice(
                mac: mac, ip: try form.value("IPAddr\(index)"), hostName: host.isEmpty ? nil : host,
                port: try form.value("PhyPortName\(index)"), kind: kind.isEmpty ? nil : kind,
                leaseSeconds: Int(try form.value("ExpiredTime\(index)"))
            )
        }
    }

    static func activeMACs(_ form: F460Form) throws -> Set<String> {
        guard form.page == arpPage, form.declaredArray("ARP_PARA") == ["DestIP", "MACAddr", "Interface"] else {
            throw RouterError.unsupportedFirmware
        }
        let count = try form.count("IF_ARP_NUM")
        return Set(try (0..<count).compactMap { MACAddress.normalize(try form.value("MACAddr\($0)")) })
    }
}

/// Security > MAC Filter. Observed actions: `basic_apply` toggles the
/// filter and mode, `new` appends a rule, `delete` removes IF_INDEX.
struct F460MACFilter {
    static let page = "sec_macfilter_conf_t.gch"
    static let ruleKeys = ["Enable", "BlackList", "Type", "Protocol", "SrcMacAddr", "DstMacAddr"]
    static let basicKeys = [
        "IsWanSrvCntl", "IpFilterTarget", "UrlFilterTarget", "UrlFilterEnable", "SrvCntlTarget",
        "DefaultPolicy", "MacFilterTarget", "MacFilterEnable",
    ]
    static let noMAC = "00:00:00:00:00:00"

    let form: F460Form
    let state: MACFilterState

    init(form: F460Form) throws {
        guard form.page == Self.page,
              form.declaredArray("MAC_PARA") == Self.ruleKeys,
              form.declaredArray("MAC_FILT_PARA") == ["SrcMacAddr", "DstMacAddr"],
              form.declaredArray("URL_BASIC_PARA") == Self.basicKeys,
              (Self.ruleKeys + Self.basicKeys + ["IF_INDEX", "IF_INSTNUM"]).allSatisfy({ form.fields[$0] != nil }),
              let enabled = form.fields["MacFilterEnable"], ["0", "1"].contains(enabled),
              let mode = form.fields["MacFilterTarget"].flatMap(MACFilterState.Mode.init(rawValue:))
        else { throw RouterError.unsupportedFirmware }
        let count = try form.count("IF_INSTNUM")
        let entries: [String?] = try (0..<count).map { index in
            let source = try form.value("SrcMacAddr\(index)")
            _ = try form.value("DstMacAddr\(index)")
            return MACAddress.normalize(source)
        }
        self.form = form
        var revisionKeys = Self.basicKeys + ["IF_INSTNUM"]
        for index in 0..<count { revisionKeys += ["SrcMacAddr\(index)", "DstMacAddr\(index)"] }
        state = MACFilterState(
            enabled: enabled == "1", mode: mode, entries: entries,
            revision: F460Page.fingerprint(form.fields, keys: revisionKeys)
        )
    }

    /// Mirrors Slect_Enable(): the filter is switched on as a blacklist.
    func enablePayload() throws -> Data {
        guard state.canBlock else { throw RouterError.filterModeUnsupported }
        var payload = nulled()
        payload["MacFilterEnable"] = "1"
        payload["MacFilterTarget"] = MACFilterState.Mode.blacklist.rawValue
        payload["IF_ACTION"] = "basic_apply"
        return FormEncoding.data(payload)
    }

    /// Mirrors pageAdd() with the Enable box ticked and Blacklist selected.
    func blockPayload(_ mac: String) throws -> Data {
        guard state.enabled, state.mode == .blacklist else { throw RouterError.filterModeUnsupported }
        guard let mac = MACAddress.normalize(mac) else { throw RouterError.invalidDevice }
        var payload = nulled()
        payload["Enable"] = "1"
        payload["Protocol"] = "ALL"
        payload["Type"] = "Bridge+Route"
        payload["SrcMacAddr"] = mac
        payload["DstMacAddr"] = Self.noMAC
        payload["MacFilterTarget"] = MACFilterState.Mode.blacklist.rawValue
        payload["MacFilterEnable"] = "1"
        payload["IF_ACTION"] = "new"
        payload["IF_INDEX"] = "-1"
        return FormEncoding.data(payload)
    }

    /// Mirrors pageDelete(i): the form is posted as loaded with an index.
    func unblockPayload(_ mac: String) throws -> Data {
        guard state.mode == .blacklist else { throw RouterError.filterModeUnsupported }
        let matches = state.entries.indices.filter { state.entries[$0] == mac }
        guard matches.count == 1, let index = matches.first else { throw RouterError.invalidDevice }
        var payload = form.fields
        payload["IF_ACTION"] = "delete"
        payload["IF_INDEX"] = String(index)
        return FormEncoding.data(payload)
    }

    private func nulled() -> [String: String] {
        var payload = form.fields
        // HiddenParaInit(MAC_PARA) and HiddenParaInit(URL_BASIC_PARA).
        for key in Self.ruleKeys + Self.basicKeys { payload[key] = "NULL" }
        return payload
    }
}

/// Administration > System Management > Reboot. msgCallback() sets
/// IF_ACTION=devrestart and flag=1 on the loaded form.
struct F460Restart {
    static let page = "manager_dev_restart_t.gch"

    let form: F460Form

    init(form: F460Form) throws {
        guard form.page == Self.page, form.fields["flag"] != nil,
              form.html.contains(#"setValue("IF_ACTION", "devrestart")"#),
              form.html.contains(#"setValue("flag", "1")"#)
        else { throw RouterError.unsupportedFirmware }
        self.form = form
    }

    func payload() -> Data {
        var payload = form.fields
        payload["IF_ACTION"] = "devrestart"
        payload["flag"] = "1"
        return FormEncoding.data(payload)
    }
}
