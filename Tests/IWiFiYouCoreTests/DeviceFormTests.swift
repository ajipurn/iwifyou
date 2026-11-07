import Foundation
import Testing
@testable import IWiFiYouCore

private func page(_ name: String) throws -> String {
    let html = try String(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")), encoding: .utf8)
    let scriptURL = try #require(Bundle.module.url(forResource: "F460Token", withExtension: "js", subdirectory: "Fixtures"))
    return html + "<script>" + (try String(contentsOf: scriptURL, encoding: .utf8)) + "</script>"
}

private func setting(_ name: String, to value: String, in html: String) -> String {
    html.replacingOccurrences(
        of: "Transfer_meaning\\('" + name + "','[^']*'\\);",
        with: "Transfer_meaning('\(name)','\(value)');",
        options: .regularExpression
    )
}

/// Adds rule rows in the indexed shape the firmware uses for other lists.
private func filterPage(entries: [String], enabled: Bool = false, mode: String = "Discard") throws -> String {
    var rows = ""
    for (index, mac) in entries.enumerated() {
        let escaped = mac.replacingOccurrences(of: ":", with: "\\x3a")
        rows += "<INPUT type='hidden' name=SrcMacAddr\(index) ID=SrcMacAddr\(index) value=''>\n<script language=javascript>Transfer_meaning('SrcMacAddr\(index)','\(escaped)');</script>\n"
        rows += "<INPUT type='hidden' name=DstMacAddr\(index) ID=DstMacAddr\(index) value=''>\n<script language=javascript>Transfer_meaning('DstMacAddr\(index)','00\\x3a00\\x3a00\\x3a00\\x3a00\\x3a00');</script>\n"
    }
    var html = try page("F460MACFilter").replacingOccurrences(of: "<!--ENTRIES-->", with: rows)
    html = setting("IF_INSTNUM", to: String(entries.count), in: html)
    html = setting("MacFilterEnable", to: enabled ? "1" : "0", in: html)
    return setting("MacFilterTarget", to: mode, in: html)
}

private func decodeForm(_ data: Data) -> [String: String] {
    let text = String(decoding: data, as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
    })
}

// MARK: - Devices

@Test func readsDHCPClientsWithPortsAndNormalizedMACs() throws {
    let form = try F460Form(html: page("F460LANInfo"), page: F460Devices.lanPage)
    let devices = try F460Devices.devices(form)
    #expect(devices.count == 3)
    #expect(devices[0] == ConnectedDevice(mac: "02:00:5e:10:00:01", ip: "192.168.1.3", hostName: nil, port: "SSID1", kind: "Computer", leaseSeconds: 84_973))
    #expect(devices[1].hostName == "android-tv")
    #expect(!devices[1].isWireless)
    #expect(devices.filter(\.isWireless).count == 2)
}

@Test func readsActiveMACsFromARPTable() throws {
    let form = try F460Form(html: page("F460ARP"), page: F460Devices.arpPage)
    #expect(try F460Devices.activeMACs(form) == ["02:00:5e:10:00:01", "02:00:5e:10:00:02"])
}

@Test func pageIdentityMustMatchRequestedPage() throws {
    #expect(throws: RouterError.unsupportedFirmware) { try F460Form(html: page("F460LANInfo"), page: F460Devices.arpPage) }
}

@Test func missingDeviceRowFailsClosed() throws {
    let html = setting("IF_INSTNUM", to: "4", in: try page("F460LANInfo"))
    let form = try F460Form(html: html, page: F460Devices.lanPage)
    #expect(throws: RouterError.unsupportedFirmware) { try F460Devices.devices(form) }
}

@Test func changedHostTableDeclarationFailsClosed() throws {
    let html = try page("F460LANInfo").replacingOccurrences(of: "\"PhyType\"\n)", with: "\"PhyType\",\n\"Extra\"\n)")
    let form = try F460Form(html: html, page: F460Devices.lanPage)
    #expect(throws: RouterError.unsupportedFirmware) { try F460Devices.devices(form) }
}

@Test func routerErrorsOnDevicePagesAreReported() throws {
    let rejected = setting("IF_ERRORSTR", to: "FAIL", in: try page("F460ARP"))
    #expect(throws: RouterError.rejected) { try F460Form(html: rejected, page: F460Devices.arpPage) }
    let token = setting("IF_ERRORPARAM", to: "_SESSION_TOKEN", in: setting("IF_ERRORSTR", to: "FAIL", in: try page("F460ARP")))
    #expect(throws: RouterError.invalidSession) { try F460Form(html: token, page: F460Devices.arpPage) }
}

@Test func macAddressNormalization() {
    #expect(MACAddress.normalize("02:00:5E:10:00:0A") == "02:00:5e:10:00:0a")
    #expect(MACAddress.normalize("00:00:00:00:00:00") == nil)
    #expect(MACAddress.normalize("ff:ff:ff:ff:ff:ff") == nil)
    #expect(MACAddress.normalize("01:00:5e:00:00:01") == nil) // multicast
    #expect(MACAddress.normalize("02:00:5e:10:00") == nil)
    #expect(MACAddress.normalize("02-00-5e-10-00-01") == nil)
}

// MARK: - MAC filter

@Test func readsObservedEmptyFilterDespiteIntermediateFailMarker() throws {
    let filter = try F460MACFilter(form: F460Form(html: page("F460MACFilter"), page: F460MACFilter.page))
    #expect(!filter.state.enabled)
    #expect(filter.state.mode == .blacklist)
    #expect(filter.state.entries.isEmpty)
    #expect(filter.state.canBlock)
}

@Test func enablingFilterMirrorsSlectEnable() throws {
    let filter = try F460MACFilter(form: F460Form(html: page("F460MACFilter"), page: F460MACFilter.page))
    let payload = decodeForm(try filter.enablePayload())
    #expect(payload["IF_ACTION"] == "basic_apply")
    #expect(payload["MacFilterEnable"] == "1")
    #expect(payload["MacFilterTarget"] == "Discard")
    for key in F460MACFilter.ruleKeys + ["IsWanSrvCntl", "IpFilterTarget", "UrlFilterTarget", "UrlFilterEnable", "SrvCntlTarget", "DefaultPolicy"] {
        #expect(payload[key] == "NULL", "\(key) must be left unchanged")
    }
    #expect(payload["_SESSION_TOKEN"] == "fixture-session-token-01")
}

@Test func blockingRequiresAnEnabledBlacklist() throws {
    let disabled = try F460MACFilter(form: F460Form(html: page("F460MACFilter"), page: F460MACFilter.page))
    #expect(throws: RouterError.filterModeUnsupported) { try disabled.blockPayload("02:00:5e:10:00:02") }

    let enabled = try F460MACFilter(form: F460Form(html: filterPage(entries: [], enabled: true), page: F460MACFilter.page))
    let payload = decodeForm(try enabled.blockPayload("02:00:5E:10:00:02"))
    #expect(payload["IF_ACTION"] == "new")
    #expect(payload["IF_INDEX"] == "-1")
    #expect(payload["Enable"] == "1")
    #expect(payload["Type"] == "Bridge+Route")
    #expect(payload["Protocol"] == "ALL")
    #expect(payload["SrcMacAddr"] == "02:00:5e:10:00:02")
    #expect(payload["DstMacAddr"] == "00:00:00:00:00:00")
    #expect(payload["MacFilterEnable"] == "1")
    #expect(payload["MacFilterTarget"] == "Discard")
    #expect(payload["BlackList"] == "NULL")
    #expect(payload["IsWanSrvCntl"] == "NULL")
    #expect(throws: RouterError.invalidDevice) { try enabled.blockPayload("ff:ff:ff:ff:ff:ff") }
}

@Test func unblockingDeletesTheMatchingIndexOnly() throws {
    let html = try filterPage(entries: ["02:00:5e:10:00:09", "02:00:5e:10:00:02"], enabled: true)
    let filter = try F460MACFilter(form: F460Form(html: html, page: F460MACFilter.page))
    #expect(filter.state.blockedMACs == ["02:00:5e:10:00:09", "02:00:5e:10:00:02"])
    let payload = decodeForm(try filter.unblockPayload("02:00:5e:10:00:02"))
    #expect(payload["IF_ACTION"] == "delete")
    #expect(payload["IF_INDEX"] == "1")
    #expect(payload["MacFilterEnable"] == "1")
    #expect(throws: RouterError.invalidDevice) { try filter.unblockPayload("02:00:5e:10:00:07") }
}

@Test func whitelistWithRulesIsNeverFlippedToBlacklist() throws {
    let html = try filterPage(entries: ["02:00:5e:10:00:01"], enabled: true, mode: "Permit")
    let filter = try F460MACFilter(form: F460Form(html: html, page: F460MACFilter.page))
    #expect(filter.state.mode == .whitelist)
    #expect(!filter.state.canBlock)
    #expect(throws: RouterError.filterModeUnsupported) { try filter.enablePayload() }
    #expect(throws: RouterError.filterModeUnsupported) { try filter.blockPayload("02:00:5e:10:00:02") }
    #expect(throws: RouterError.filterModeUnsupported) { try filter.unblockPayload("02:00:5e:10:00:01") }
}

@Test func filterRowsMissingFromPageFailClosed() throws {
    let html = setting("IF_INSTNUM", to: "1", in: try page("F460MACFilter"))
    #expect(throws: RouterError.unsupportedFirmware) { try F460MACFilter(form: F460Form(html: html, page: F460MACFilter.page)) }
}

@Test func changedFilterParameterListFailsClosed() throws {
    let html = try page("F460MACFilter").replacingOccurrences(of: "\"SrcMacAddr\",\"DstMacAddr\");\nvar MAC_FILT", with: "\"SrcMacAddr\",\"DstMacAddr\",\"Port\");\nvar MAC_FILT")
    #expect(throws: RouterError.unsupportedFirmware) { try F460MACFilter(form: F460Form(html: html, page: F460MACFilter.page)) }
}

@Test func filterRevisionTracksRulesButNotToken() throws {
    let first = try F460MACFilter(form: F460Form(html: filterPage(entries: [], enabled: true), page: F460MACFilter.page))
    let rotated = try filterPage(entries: [], enabled: true).replacingOccurrences(of: "fixture-session-token-01", with: "fixture-session-token-02")
    let second = try F460MACFilter(form: F460Form(html: rotated, page: F460MACFilter.page))
    let changed = try F460MACFilter(form: F460Form(html: filterPage(entries: ["02:00:5e:10:00:02"], enabled: true), page: F460MACFilter.page))
    #expect(first.state == second.state)
    #expect(first.state != changed.state)
}

// MARK: - Restart

@Test func restartMirrorsMsgCallback() throws {
    let restart = try F460Restart(form: F460Form(html: page("F460Restart"), page: F460Restart.page))
    let payload = decodeForm(restart.payload())
    #expect(payload["IF_ACTION"] == "devrestart")
    #expect(payload["flag"] == "1")
    #expect(payload["_SESSION_TOKEN"] == "fixture-session-token-01")
}

@Test func restartWithoutObservedCallbackFailsClosed() throws {
    let html = try page("F460Restart").replacingOccurrences(of: "devrestart", with: "factoryreset")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Restart(form: F460Form(html: html, page: F460Restart.page)) }
}

// MARK: - WLAN details and channel survey

@Test func wlanDetailsAreReadWithoutSecrets() throws {
    let html = try page("F460WLAN")
    let details = try F460Page(html: html).snapshot.details
    #expect(details.standard == "802.11b/g/n")
    #expect(details.security == "WPA/WPA2-Personal")
    #expect(details.encryption == "AES")
    #expect(details.region == "CN")
    #expect(details.maxClients == 32)
    #expect(details.macFilter == "Nonaktif")
    #expect(details.sideBand == nil)
    #expect(!String(describing: details).contains("fixture-only-password"))
}

@Test func surveyWeighsOverlapAndSignal() {
    let strong = NearbyNetwork(name: "A", channel: 6, widthMHz: 20, rssi: -50)
    #expect(ChannelSurvey.overlap(candidate: 6, network: strong) == 1)
    #expect(ChannelSurvey.overlap(candidate: 8, network: strong) == 0.5)
    #expect(ChannelSurvey.overlap(candidate: 10, network: strong) == 0)
    #expect(ChannelSurvey.signalWeight(-50) == 1)
    #expect(ChannelSurvey.signalWeight(-90) == 0)
    // 40 MHz on channel 1 can only extend upward.
    let wide = NearbyNetwork(name: "B", channel: 1, widthMHz: 40, rssi: -50)
    #expect(ChannelSurvey.overlap(candidate: 5, network: wide) == 1)
    #expect(ChannelSurvey.overlap(candidate: 9, network: wide) == 0)
}

@Test func surveyIgnoresOwnNetworkAndPrefersNonOverlappingChannels() {
    let networks = [
        NearbyNetwork(name: "Rumah", channel: 1, widthMHz: 20, rssi: -40),
        NearbyNetwork(name: "Tetangga", channel: 11, widthMHz: 20, rssi: -55),
    ]
    let qualities = ChannelSurvey.qualities(for: Array(1...13), networks: networks, ownSSID: "Rumah")
    #expect(qualities.first { $0.channel == 1 }?.load == 0)
    #expect(qualities.first { $0.channel == 11 }?.level == .fair)
    // Channels 1..6 are all quiet; the 1/6/11 plan breaks the tie.
    #expect(ChannelSurvey.recommendation(qualities) == 1)
    let withoutNames = ChannelSurvey.qualities(for: [1, 6], networks: networks.map { NearbyNetwork(name: nil, channel: $0.channel, widthMHz: 20, rssi: $0.rssi) }, ownSSID: "Rumah")
    #expect(ChannelSurvey.recommendation(withoutNames) == 6)
}
