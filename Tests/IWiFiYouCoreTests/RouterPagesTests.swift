import Foundation
import Testing
@testable import IWiFiYouCore

private func page(_ name: String) throws -> String {
    let html = try String(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")), encoding: .utf8)
    let scriptURL = try #require(Bundle.module.url(forResource: "F460Token", withExtension: "js", subdirectory: "Fixtures"))
    return html + "<script>" + (try String(contentsOf: scriptURL, encoding: .utf8)) + "</script>"
}

private func setting(_ name: String, to value: String, in html: String) -> String {
    html.replacingOccurrences(of: "Transfer_meaning\\('" + name + "','[^']*'\\);", with: "Transfer_meaning('\(name)','\(value)');", options: .regularExpression)
}

private func rows(_ values: [[(String, String)]], in html: String, count: String = "IF_INSTNUM") -> String {
    var text = ""
    for (index, row) in values.enumerated() {
        for (key, value) in row {
            let escaped = value.replacingOccurrences(of: ":", with: "\\x3a").replacingOccurrences(of: ".", with: "\\x2e")
            text += "<INPUT type='hidden' name=\(key)\(index) ID=\(key)\(index) value=''>\n<script language=javascript>Transfer_meaning('\(key)\(index)','\(escaped)');</script>\n"
        }
    }
    return setting(count, to: String(values.count), in: html.replacingOccurrences(of: "<!--ENTRIES-->", with: text))
}

private func decodeForm(_ data: Data) -> [String: String] {
    Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
    })
}

// MARK: - Status pages

@Test func readsDeviceInfoFromEntityEncodedRows() throws {
    let info = try F460Status.device(page("F460DeviceInfo"))
    #expect(info == RouterInfo(model: "F460", hardware: "V6.0", software: "V6.0.0P12T6", bootLoader: "V6.0.0P12T1"))
}

@Test func readsWANStatusIgnoringCommentedRows() throws {
    let wan = try F460Status.wan(page("F460WANStatus"))
    #expect(wan.connected)
    #expect(wan.mode == "PPPoE")
    #expect(wan.name == "1_INTERNET_R_VID_45")
    #expect(wan.address == "100.64.12.34")
    #expect(wan.dns == ["203.0.113.53", "203.0.113.54"])
    #expect(wan.onlineSeconds == 4148)
    #expect(wan.disconnectReason == nil)
    let down = try F460Status.wan(page("F460WANStatus").replacingOccurrences(of: ">Connected<", with: ">Disconnected<"))
    #expect(!down.connected)
}

@Test func readsOpticalPowerFromPageVariables() throws {
    let optical = try F460Status.optical(page("F460Optical"))
    #expect(optical.fiber == FiberPower(rx: -21.54, tx: 2.74))
    #expect(!optical.lossOfSignal)
    #expect(optical.registration == "Terdaftar dan terotorisasi")
    #expect(optical.temperature == 48)
    #expect(optical.voltage == 3.213)
    #expect(optical.biasCurrent == 13.9)
    let los = try F460Status.optical(page("F460Optical").replacingOccurrences(of: "var LosInfo = \"0\"", with: "var LosInfo = \"1\""))
    #expect(los.lossOfSignal && los.fiber == nil)
}

@Test func opticalScaleMustMatchObservedFirmware() throws {
    let html = try page("F460Optical").replacingOccurrences(of: "RxPower/10000", with: "RxPower/100")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Status.optical(html) }
}

@Test func readsActualWLANChannel() throws {
    #expect(try F460Status.wlan(page("F460WLANStatus")) == WLANLiveStatus(enabled: true, channel: 6))
    #expect(throws: RouterError.unsupportedFirmware) { try F460Status.wlan(page("F460WANStatus")) }
}

@Test func statusPagesDetectSessionEnd() throws {
    let timeout = try page("F460SessionTimeout")
    #expect(throws: RouterError.loginRequired) { try F460Status.device(timeout) }
    #expect(throws: RouterError.loginRequired) { try F460Status.optical(timeout) }
}

@Test func decodesHTMLEntities() {
    #expect(F460Status.decodeEntities("&#70;&#52;&#x36;0 &amp; &lt;b&gt; 5&nbsp;dB &unknown;") == "F460 & <b> 5 dB &unknown;")
}

// MARK: - DHCP reservations

@Test func dhcpReservationMirrorsAddAndDelete() throws {
    let empty = try F460DHCPStatic(form: F460Form(html: page("F460DHCPStatic"), page: F460DHCPStatic.page))
    #expect(empty.state.poolStart == "192.168.1.2" && empty.state.poolEnd == "192.168.1.254")
    let add = decodeForm(try empty.addPayload(ip: "192.168.1.20", mac: "02:00:5E:10:00:02"))
    #expect(add["IF_ACTION"] == "new" && add["IF_INDEX"] == "-1")
    #expect(add["IPAddr"] == "192.168.1.20" && add["MACAddr"] == "02:00:5e:10:00:02")
    #expect(add["ViewName"] == "NULL" && add["HostCfgViewName"] == "NULL")
    #expect(add["_SESSION_TOKEN"] == "fixture-session-token-01")
    #expect(throws: RouterError.invalidAddressInPool) { try empty.addPayload(ip: "192.168.2.20", mac: "02:00:5e:10:00:02") }
    #expect(throws: RouterError.invalidAddressInPool) { try empty.addPayload(ip: "192.168.1.255", mac: "02:00:5e:10:00:02") }

    let html = rows([[("IPAddr", "192.168.1.20"), ("MACAddr", "02:00:5e:10:00:02")]], in: try page("F460DHCPStatic"))
    let one = try F460DHCPStatic(form: F460Form(html: html, page: F460DHCPStatic.page))
    #expect(one.state.reservations == [DHCPReservation(ip: "192.168.1.20", mac: "02:00:5e:10:00:02")])
    #expect(throws: RouterError.duplicateEntry) { try one.addPayload(ip: "192.168.1.21", mac: "02:00:5e:10:00:02") }
    let delete = decodeForm(try one.removePayload(mac: "02:00:5e:10:00:02"))
    #expect(delete["IF_ACTION"] == "delete" && delete["IF_INDEX"] == "0")
}

@Test func dhcpWithoutPoolBoundsFailsClosed() throws {
    let html = try page("F460DHCPStatic").replacingOccurrences(of: "Transfer_meaning('MinAddress'", with: "Transfer_meaning('Other'")
    #expect(throws: RouterError.unsupportedFirmware) { try F460DHCPStatic(form: F460Form(html: html, page: F460DHCPStatic.page)) }
}

// MARK: - Port forwarding

@Test func portForwardMirrorsPageSetValue() throws {
    let forwards = try F460PortForward(form: F460Form(html: page("F460PortForward"), page: F460PortForward.page))
    let connection = try #require(forwards.state.connections.first)
    #expect(connection == WANConnection(id: "IGD.WD1.WCD1.WCPPP1", name: "1_INTERNET_R_VID_45"))
    let rule = PortForward(name: "CCTV", proto: .tcp, externalStart: 8080, externalEnd: 8081, internalHost: "192.168.1.20", internalPort: 80)
    let add = decodeForm(try forwards.addPayload(rule, connection: connection))
    #expect(add["IF_ACTION"] == "new" && add["IF_INDEX"] == "-1")
    #expect(add["Enable"] == "1" && add["Name"] == "CCTV" && add["Protocol"] == "0")
    #expect(add["MinExtPort"] == "8080" && add["MaxExtPort"] == "8081")
    #expect(add["MinIntPort"] == "80" && add["MaxIntPort"] == "80")
    #expect(add["InternalHost"] == "192.168.1.20" && add["MacEnable"] == "0")
    #expect(add["MinRemoteHost"] == "0.0.0.0" && add["MaxRemoteHost"] == "0.0.0.0")
    #expect(add["WANCViewName"] == "IGD.WD1.WCD1.WCPPP1")
    #expect(add["Description"] == "NULL" && add["InternalMacHost"] == "NULL")

    let bad = PortForward(name: "X", proto: .udp, externalStart: 9000, externalEnd: 8000, internalHost: "192.168.1.20", internalPort: 80)
    #expect(throws: RouterError.self) { try forwards.addPayload(bad, connection: connection) }
    let badHost = PortForward(name: "X", proto: .udp, externalStart: 80, externalEnd: 80, internalHost: "192.168.1.0", internalPort: 80)
    #expect(throws: RouterError.self) { try forwards.addPayload(badHost, connection: connection) }
}

@Test func portForwardRowsAndDelete() throws {
    let html = rows([[("Enable", "1"), ("Name", "Game"), ("Protocol", "2"), ("MinExtPort", "3074"), ("MaxExtPort", "3075"),
                      ("InternalHost", "192.168.1.30"), ("MinIntPort", "3074")]], in: try page("F460PortForward"))
    let forwards = try F460PortForward(form: F460Form(html: html, page: F460PortForward.page))
    #expect(forwards.state.rules == [PortForward(name: "Game", proto: .both, externalStart: 3074, externalEnd: 3075, internalHost: "192.168.1.30", internalPort: 3074)])
    let duplicate = PortForward(name: "Game", proto: .tcp, externalStart: 1, externalEnd: 1, internalHost: "192.168.1.31", internalPort: 1)
    #expect(throws: RouterError.duplicateEntry) { try forwards.addPayload(duplicate, connection: forwards.state.connections[0]) }
    let delete = decodeForm(try forwards.removePayload(name: "Game"))
    #expect(delete["IF_ACTION"] == "delete" && delete["IF_INDEX"] == "0")
}

// MARK: - Website blocking

@Test func urlFilterToleratesRepeatedCountField() throws {
    let html = try page("F460URLFilter")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Form(html: html, page: F460URLFilter.page) }
    let filter = try F460URLFilter(form: F460Form(html: html, page: F460URLFilter.page, allowingDuplicates: F460URLFilter.duplicates))
    #expect(!filter.state.enabled && filter.state.mode == .blacklist && filter.state.sites.isEmpty)
    let enable = decodeForm(try filter.enablePayload())
    #expect(enable["IF_ACTION"] == "basic_apply" && enable["UrlFilterEnable"] == "1" && enable["UrlFilterTarget"] == "0")
    #expect(enable["IsWanSrvCntl"] == "NULL" && enable["DefaultPolicy"] == "NULL")
    #expect(throws: RouterError.filterModeUnsupported) { try filter.addPayload("example.com") }
}

@Test func urlFilterAddAndDelete() throws {
    var html = rows([[("Url", "judi.example")]], in: try page("F460URLFilter"))
    html = setting("UrlFilterEnable", to: "1", in: html)
    let filter = try F460URLFilter(form: F460Form(html: html, page: F460URLFilter.page, allowingDuplicates: F460URLFilter.duplicates))
    #expect(filter.state.sites == ["judi.example"])
    let add = decodeForm(try filter.addPayload("https://Video.Example/"))
    #expect(add["IF_ACTION"] == "new" && add["IF_INDEX"] == "-1")
    #expect(add["Url"] == "video.example" && add["Enable"] == "0" && add["FilterTarget"] == "0" && add["ViewName"] == "NULL")
    #expect(add["UrlFilterEnable"] == "1") // URL_BASIC_PARA is not NULLed by Add()
    #expect(throws: RouterError.duplicateEntry) { try filter.addPayload("judi.example") }
    let delete = decodeForm(try filter.removePayload("judi.example"))
    #expect(delete["IF_ACTION"] == "delete" && delete["IF_INDEX"] == "0")
    let whitelist = try F460URLFilter(form: F460Form(html: setting("UrlFilterTarget", to: "1", in: html), page: F460URLFilter.page, allowingDuplicates: F460URLFilter.duplicates))
    #expect(!whitelist.state.canBlock)
    #expect(throws: RouterError.filterModeUnsupported) { try whitelist.enablePayload() }
}

@Test func siteNormalization() {
    #expect(SiteFilter.normalize("https://www.Example.com/") == "www.example.com")
    #expect(SiteFilter.normalize("example.com/path?q=1") == "example.com/path?q=1")
    #expect(SiteFilter.normalize("bad site.com") == nil)
    #expect(SiteFilter.normalize("") == nil)
    #expect(SiteFilter.normalize("situs.ü") == nil)
}

// MARK: - Wi-Fi name and password

@Test func credentialsPayloadMirrorsPageSubmitForWPAMixed() throws {
    let wlan = try F460Page(html: page("F460WLAN"))
    #expect(wlan.usesPassphrase)
    #expect(wlan.hasPassphrase("fixture-only-password"))
    let both = decodeForm(try wlan.credentialsPayload(ssid: "Rumah Baru", passphrase: "password-baru-123"))
    #expect(both["IF_ACTION"] == "apply" && both["IF_CONFIGTAG"] == "Y" && both["IF_PSKTAG"] == "Y")
    #expect(both["IF_WEPKEYTAG"] == "N")
    #expect(both["ESSID"] == "Rumah Baru" && both["Enable"] == "1")
    #expect(both["KeyPassphrase"] == "password-baru-123" && both["PreSharedKey"] == "NULL")
    #expect(both["BeaconType"] == "WPAand11i" && both["WPAAuthMode"] == "PSKAuthentication" && both["11iAuthMode"] == "PSKAuthentication")
    #expect(both["WPAEncryptType"] == "AESEncryption" && both["11iEncryptType"] == "AESEncryption")
    #expect(both["Channel"] == "NULL" && both["TxPower"] == "NULL" && both["ESSIDHideEnable"] == "NULL")

    let nameOnly = decodeForm(try wlan.credentialsPayload(ssid: "Rumah", passphrase: nil))
    #expect(nameOnly["IF_PSKTAG"] == "N" && nameOnly["KeyPassphrase"] == "NULL" && nameOnly["BeaconType"] == "NULL")
}

@Test func credentialsAreValidatedLikeTheRouter() throws {
    let wlan = try F460Page(html: page("F460WLAN"))
    #expect(throws: RouterError.self) { try wlan.credentialsPayload(ssid: String(repeating: "a", count: 33), passphrase: nil) }
    #expect(throws: RouterError.self) { try wlan.credentialsPayload(ssid: " spasi", passphrase: nil) }
    #expect(throws: RouterError.self) { try wlan.credentialsPayload(ssid: nil, passphrase: "pendek") }
    #expect(throws: RouterError.self) { try wlan.credentialsPayload(ssid: nil, passphrase: "kata sandi ünïcode") }
    let open = try F460Page(html: setting("BeaconType", to: "None", in: page("F460WLAN")))
    #expect(throws: RouterError.unsupportedFirmware) { try open.credentialsPayload(ssid: nil, passphrase: "password-baru-123") }
}

@Test func credentialRevisionIgnoresNameAndKeyOnly() throws {
    let base = try F460Page(html: page("F460WLAN"))
    let renamed = try F460Page(html: setting("KeyPassphrase", to: "another-password", in: setting("ESSID", to: "Lain", in: page("F460WLAN"))))
    let powered = try F460Page(html: setting("TxPower", to: "50\\x25", in: page("F460WLAN")))
    #expect(base.settingsRevisionExcludingCredentials == renamed.settingsRevisionExcludingCredentials)
    #expect(base.settingsRevisionExcludingCredentials != powered.settingsRevisionExcludingCredentials)
}

// MARK: - DNS blocking through Hosts

@Test func hostsPageMirrorsAddAndDelete() throws {
    let html = try page("F460Hosts")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Form(html: html, page: F460Hosts.page) }
    let empty = try F460Hosts(form: F460Form(html: html, page: F460Hosts.page, allowingDuplicates: F460Hosts.duplicates))
    #expect(empty.state.hosts.isEmpty)
    let add = decodeForm(try empty.addPayload("https://WWW.YouTube.com/watch?v=1"))
    #expect(add["IF_ACTION"] == "new" && add["IF_INDEX"] == "-1")
    #expect(add["HostName"] == "www.youtube.com" && add["IPAddress"] == "0.0.0.0")
    #expect(add["_SESSION_TOKEN"] == "fixture-session-token-01")

    // Same shape as the rows read from the real router.
    let rowsHTML = rows([[("HostName", "www.youtube.com"), ("IPAddress", "0.0.0.0")], [("HostName", "printer"), ("IPAddress", "192.168.1.50")]],
                        in: html, count: "HOST_INSTNUM")
    let two = try F460Hosts(form: F460Form(html: rowsHTML, page: F460Hosts.page, allowingDuplicates: F460Hosts.duplicates))
    #expect(two.state.blockedNames == ["www.youtube.com"])
    #expect(two.state.hosts.map(\.isBlock) == [true, false])
    #expect(throws: RouterError.duplicateEntry) { try two.addPayload("www.youtube.com") }
    let delete = decodeForm(try two.removePayload("printer"))
    #expect(delete["IF_ACTION"] == "delete" && delete["IF_INDEX"] == "1")
}

@Test func hostsPageReportsItsOwnError() throws {
    let html = setting("HOST_ERRORSTR", to: "FAIL", in: try page("F460Hosts"))
    #expect(throws: RouterError.rejected) { try F460Hosts(form: F460Form(html: html, page: F460Hosts.page, allowingDuplicates: F460Hosts.duplicates)) }
}

@Test func hostNamesFollowRouterRules() {
    #expect(DNSBlocklist.normalize("YouTube.com") == "youtube.com")
    #expect(DNSBlocklist.normalize("https://m.tiktok.com/@user") == "m.tiktok.com")
    #expect(DNSBlocklist.normalize("-bad.com") == nil)
    #expect(DNSBlocklist.normalize("bad..com") == nil)
    #expect(DNSBlocklist.normalize("10.0.0.1") == nil)
    #expect(DNSBlocklist.normalize("situs ku.com") == nil)
    #expect(DNSBlocklist.names(forDomain: "www.instagram.com") == ["instagram.com", "www.instagram.com", "m.instagram.com"])
    #expect(SitePreset.allCases.allSatisfy { $0.hosts.allSatisfy { DNSBlocklist.normalize($0) == $0 } })
    #expect(SitePreset.youtube.hosts.count + SitePreset.tiktok.hosts.count <= DNSBlocklist.capacity)
}

@Test func hostNamesGroupBySite() {
    #expect(DNSBlocklist.site(of: "www.instagram.com") == "instagram.com")
    #expect(DNSBlocklist.site(of: "m.instagram.com") == "instagram.com")
    #expect(DNSBlocklist.site(of: "instagram.com") == "instagram.com")
    #expect(DNSBlocklist.site(of: "api.tiktokv.com") == "api.tiktokv.com")
}
