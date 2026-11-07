import Foundation
import Testing
@testable import IWiFiYouCore

private func fixture(_ name: String = "F460WLAN") throws -> String {
    let html = try String(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures")), encoding: .utf8)
    guard name == "F460WLAN" else { return html }
    let scriptURL = try #require(Bundle.module.url(forResource: "F460Token", withExtension: "js", subdirectory: "Fixtures"))
    return html + "<script>" + (try String(contentsOf: scriptURL, encoding: .utf8)) + "</script>"
}

private func changing(_ name: String, to value: String, in html: String) -> String {
    html.replacingOccurrences(
        of: "Transfer_meaning\\('" + name + "','[^']*'\\);",
        with: "Transfer_meaning('\(name)','\(value)');",
        options: .regularExpression
    )
}

private func decodeForm(_ data: Data) -> [String: String] {
    let text = String(decoding: data, as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: text.split(separator: "&").map {
        let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
    })
}

@Test func includesSessionTokenAppendedByRouterJavaScript() throws {
    let page = try F460Page(html: fixture())
    let payload = decodeForm(try page.payload(for: .fixed(6)))
    #expect(payload["_SESSION_TOKEN"] == "fixture-session-token-01")
}

@Test func logoutUsesOnlyObservedFormAndSessionToken() throws {
    let payload = decodeForm(try F460Page.logoutPayload(in: fixture()))
    #expect(payload == ["logout": "1", "_SESSION_TOKEN": "fixture-session-token-01"])
}

@Test func logoutRejectsUnknownActionAndUnauthenticatedPages() throws {
    let html = try fixture().replacingOccurrences(of: "action=\"/\"", with: "action=\"https://example.com/\"")
    #expect(throws: RouterError.logoutUnavailable) { try F460Page.logoutPayload(in: html) }
    let timeout = try fixture("F460SessionTimeout")
    #expect(throws: RouterError.logoutUnavailable) { try F460Page.logoutPayload(in: timeout) }
    let busy = try fixture("F460AdminBusy")
    #expect(throws: RouterError.logoutUnavailable) { try F460Page.logoutPayload(in: busy) }
}

@Test func requiresSessionTokenBeforeAllowingWrites() throws {
    let html = try fixture().replacingOccurrences(of: "var session_token = 'fixture-session-token-01';", with: "var unrelated = 'fixture-session-token-01';")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page(html: html) }
}

@Test func changingTokenDoesNotChangeConfigurationRevision() throws {
    let html = try fixture()
    let newer = html.replacingOccurrences(of: "fixture-session-token-01", with: "fixture-session-token-02")
    let before = try F460Page(html: html)
    let after = try F460Page(html: newer)
    #expect(before.snapshot.revision == after.snapshot.revision)
    #expect(decodeForm(try after.payload(for: .fixed(6)))["_SESSION_TOKEN"] == "fixture-session-token-02")
}

@Test func rejectsAmbiguousOrEmptySessionTokens() throws {
    let html = try fixture()
    let duplicate = html.replacingOccurrences(of: "var session_token =", with: "var session_token = 'another-token'; var session_token =")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page(html: duplicate) }
    let empty = html.replacingOccurrences(of: "fixture-session-token-01", with: "")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page(html: empty) }
}

@Test func identifiesSessionTokenRejection() throws {
    let html = try changing("IF_ERRORPARAM", to: "_SESSION_TOKEN", in: changing("IF_ERRORSTR", to: "FAIL", in: fixture()))
    #expect(throws: RouterError.invalidSession) { try F460Page(html: html) }
}

@Test func readsConfigurationFromEscapedInitializers() throws {
    let page = try F460Page(html: fixture())
    #expect(page.snapshot.ssid == "Fixture WiFi")
    #expect(page.snapshot.channel == .automatic)
    #expect(page.snapshot.bandwidth == "20 MHz")
    #expect(page.snapshot.radioEnabled)
    #expect(page.snapshot.availableChannels == [.automatic] + (1...13).map(WiFiChannel.fixed))
}

@Test func manualPayloadChangesOnlyChannelConfiguration() throws {
    let page = try F460Page(html: fixture())
    let fields = decodeForm(try page.payload(for: .fixed(6)))
    #expect(fields["Channel"] == "6")
    #expect(fields["AutoChannelEnabled"] == "0")
    #expect(fields["IF_ACTION"] == "apply")
    #expect(fields["IF_CONFIGTAG"] == "Y")
    #expect(fields["IF_VIEWID"] == "IGD.LD1.WLAN1")
    for key in F460Page.configurationKeys where !["Channel", "AutoChannelEnabled"].contains(key) {
        #expect(fields[key] == "NULL", "Unexpected write to \(key)")
    }
    #expect(fields["IF_PSKTAG"] == "N")
    #expect(fields["IF_WEPKEYTAG"] == "N")
    #expect(fields["KeyPassphrase"] == "NULL")
    #expect(fields["WEPKey0"] == "NULL")
    #expect(!String(decoding: try page.payload(for: .fixed(6)), as: UTF8.self).contains("fixture-only-password"))
}

@Test func automaticPayloadLeavesFixedChannelUntouched() throws {
    let page = try F460Page(html: fixture())
    let fields = decodeForm(try page.payload(for: .automatic))
    #expect(fields["Channel"] == "NULL")
    #expect(fields["AutoChannelEnabled"] == "1")
}

@Test func usesLatestInitializerWithoutExecutingScripts() throws {
    var html = try fixture()
    html = html.replacingOccurrences(of: "</body>", with: "<script>Transfer_meaning('AutoChannelEnabled','0');</script><script>Transfer_meaning('Channel','6');</script></body>")
    #expect(try F460Page(html: html).snapshot.channel == .fixed(6))
}

@Test func detectsLoginAndFreshToken() throws {
    let html = try fixture("F460Login")
    #expect(throws: RouterError.loginRequired) { try F460Page(html: html) }
    #expect(try F460Page.loginToken(in: html) == "42")
}

@Test func sessionTimeoutRequiresLoginInsteadOfUnsupportedFirmware() throws {
    let html = try fixture("F460SessionTimeout")
    #expect(throws: RouterError.loginRequired) { try F460Page(html: html) }
}

@Test func activeAdminSessionHasSpecificErrorInsteadOfUnsupportedFirmware() throws {
    let html = try fixture("F460AdminBusy")
    #expect(throws: RouterError.adminSessionInUse) { try F460Page(html: html) }
}

@Test func lockedAdminSessionDoesNotAttemptToExtractLoginToken() throws {
    let html = try fixture("F460AdminBusy")
    #expect(throws: RouterError.adminSessionInUse) { try F460Page.loginToken(in: html) }
}

@Test func adminWarningInConfigurationScriptDoesNotBlockNormalPage() throws {
    let html = try fixture() + "<script>function warn() { alert('Another user has logged in to the system, please retry later...'); }</script>"
    #expect(!F460Page.isAdminSessionInUse(html))
    #expect(try F460Page(html: html).snapshot.channel == .automatic)
}

@Test func timeoutAlertInNormalPageDoesNotMeanSessionExpired() throws {
    let html = try fixture() + """
        <script>function relogin() { alert("Session timeout, please login again."); }</script>
        <form id="flogout" method="post"><input type="hidden" name="logout" value="1"></form>
        """
    #expect(!F460Page.isSessionTimeout(html))
    #expect(try F460Page(html: html).snapshot.channel == .automatic)
}

@Test func timeoutMarkerMustBelongToLogoutForm() throws {
    let html = try fixture() + """
        <form id="other"><input type="hidden" name="logout_from" value="login_timeout"></form>
        """
    #expect(!F460Page.isSessionTimeout(html))
}

@Test func loginTokenFromTimeoutPageRequestsReauthentication() throws {
    let html = try fixture("F460SessionTimeout")
    #expect(throws: RouterError.loginRequired) { try F460Page.loginToken(in: html) }
}

@Test func blocksUnsupportedFirmware() throws {
    let html = try fixture().replacingOccurrences(of: "var CONFIG_PARA", with: "var DIFFERENT_CONFIG")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page(html: html) }
}

@Test func blocksIncompleteConfiguration() throws {
    let html = try fixture().replacingOccurrences(of: "name=\"RadioStatus\"", with: "name=\"Unknown\"")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page(html: html) }
}

@Test func blocksDisabledRadioAndOutOfRangeChannel() throws {
    let html = try fixture()
    let disabled = try F460Page(html: changing("RadioStatus", to: "0", in: html))
    #expect(throws: RouterError.radioDisabled) { try disabled.payload(for: .fixed(6)) }
    let normal = try F460Page(html: html)
    #expect(throws: RouterError.unavailableChannel) { try normal.payload(for: .fixed(14)) }
}

@Test func respectsCountryAndServerChannelList() throws {
    let html = try fixture()
    let usPage = try F460Page(html: changing("CountryCode", to: "usI", in: html))
    #expect(!usPage.snapshot.availableChannels.contains(.fixed(12)))
    let sparsePage = try F460Page(html: changing("PossibleChannels", to: "1,6,11", in: html))
    #expect(sparsePage.snapshot.availableChannels == [.automatic, .fixed(1), .fixed(6), .fixed(11)])
}

@Test func detectsConcurrentChangesWithoutExposingSecrets() throws {
    let html = try fixture()
    let before = try F460Page(html: html).snapshot
    let after = try F460Page(html: changing("KeyPassphrase", to: "different-fixture-secret", in: html)).snapshot
    #expect(before.revision != after.revision)
    #expect(before.otherSettingsRevision != after.otherSettingsRevision)
    #expect(before.revision.count == 64)
}

@Test func changingAutoRadioDoesNotInvalidateSavedConfiguration() throws {
    let html = try fixture()
    let before = try F460Page(html: html).snapshot
    let after = try F460Page(html: changing("Channel", to: "6", in: html)).snapshot
    #expect(before.revision == after.revision)
}

@Test func channelChangeKeepsOtherSettingsFingerprint() throws {
    let html = try fixture()
    let changed = changing("Channel", to: "6", in: changing("AutoChannelEnabled", to: "0", in: html))
    let before = try F460Page(html: html).snapshot
    let after = try F460Page(html: changed).snapshot
    #expect(before.revision != after.revision)
    #expect(before.otherSettingsRevision == after.otherSettingsRevision)
}

@Test func detectsRouterRejection() throws {
    let html = try changing("IF_ERRORSTR", to: "FAIL", in: fixture())
    #expect(throws: RouterError.rejected) { try F460Page(html: html) }
}

@Test(arguments: ["0", "14", "1-999999", "6-1", "1,,6", "", "1-13,14"])
func rejectsMalformedChannelLists(_ input: String) {
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page.parseChannels(input) }
}

@Test func decodesEscapesAndRejectsUnsupportedCode() throws {
    #expect(try F460Page.decodeJavaScriptString(#"Caf\u00e9\x20\'WiFi\'"#) == "Café 'WiFi'")
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page.decodeJavaScriptString(#"\xZZ"#) }
    #expect(throws: RouterError.unsupportedFirmware) { try F460Page.decodeJavaScriptString(#"\q"#) }
}

@Test(arguments: ["192.168.1.1", "http://10.0.0.1/", "https://172.16.0.1:8443", "127.0.0.1:18742"])
func acceptsLocalRouterAddresses(_ input: String) throws {
    #expect(try RouterAddress(input).url.host() != nil)
}

@Test(arguments: ["https://example.com", "8.8.8.8", "192.168.1.1.evil.example", "http://user:pass@192.168.1.1", "http://192.168.1.1/other", "http://192.168.1.1?x=1", "file:///etc/passwd", "192.168.001.1", "172.32.0.1", "http://192.168.1.1#fragment"])
func rejectsNonLocalOrAmbiguousAddresses(_ input: String) {
    #expect(throws: RouterError.invalidAddress) { try RouterAddress(input) }
}

@Test func blocksRedirectsToDifferentOrigins() throws {
    let address = try RouterAddress("192.168.1.1")
    #expect(address.contains(URL(string: "http://192.168.1.1/start.ghtml")))
    #expect(!address.contains(URL(string: "http://192.168.1.2/")))
    #expect(!address.contains(URL(string: "https://192.168.1.1/")))
    #expect(!address.contains(URL(string: "http://192.168.1.1:8080/")))
    #expect(!address.contains(URL(string: "http://user:pass@192.168.1.1/")))
}

@Test func formEncodingPreservesReservedCharacters() {
    let fields = ["Username": "test+user", "Password": "test & + = % / é", "empty": ""]
    #expect(decodeForm(FormEncoding.data(fields)) == fields)
}

// Optional read-only check of a captured local HTML file, never a network request.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IWIFYOU_CAPTURE"] != nil))
func readsActualFirmwareCapture() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IWIFYOU_CAPTURE"])
    let html = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    let page = try F460Page(html: html)
    #expect(!page.snapshot.availableChannels.isEmpty)
}
