import Foundation
import Testing
@testable import IWiFiYouCore
@testable import iwifyou

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IWIFYOU_SIMULATOR"] != nil))
struct ClientIntegrationTests {
    private func address() throws -> RouterAddress {
        let input = try #require(ProcessInfo.processInfo.environment["IWIFYOU_SIMULATOR"])
        let address = try RouterAddress(input)
        // Integration tests can only point at the local simulator, never a router.
        try #require(address.url.host() == "127.0.0.1")
        return address
    }

    @discardableResult
    private func simulator(_ path: String) async throws -> Data {
        let base = try address().url
        let url = try #require(URL(string: "simulate/" + path, relativeTo: base))
        return try await URLSession.shared.data(from: url).0
    }

    private func counters() async throws -> [String: Int] {
        let value = try JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any]
        return ["posts": value?["posts"] as? Int ?? -1, "logins": value?["logins"] as? Int ?? -1,
                "tokensRejected": value?["tokens_rejected"] as? Int ?? -1,
                "logouts": value?["logouts"] as? Int ?? -1,
                "logoutAttempts": value?["logout_attempts"] as? Int ?? -1]
    }

    @Test func loginReadApplyAndNoDuplicatePost() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        await #expect(throws: RouterError.loginRequired) { try await client.read() }
        await #expect(throws: RouterError.loginFailed) { try await client.login(username: "fixture-admin", password: "wrong-password") }
        #expect(try await counters()["logins"] == 1)
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        let after = try await client.apply(.fixed(6), expected: before)
        #expect(after.channel == .fixed(6))
        #expect(after.otherSettingsRevision == before.otherSettingsRevision)
        _ = try await client.apply(.fixed(6), expected: after)
        #expect(try await counters()["posts"] == 1)
        let automatic = try await client.apply(.automatic, expected: after)
        #expect(automatic.channel == .automatic)
        #expect(try await counters()["posts"] == 2)
        #expect(try await counters()["tokensRejected"] == 0)
    }

    @Test func missingSessionTokenReproducesRouterRejection() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        let url = try #require(URL(string: F460Page.path, relativeTo: address().url))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let simulatedState = try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
        let cookie = try #require(simulatedState["active_session"] as? String)
        request.setValue("session=" + cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Reproduce the old request: no dynamically appended _SESSION_TOKEN.
        request.httpBody = FormEncoding.data(["Channel": "6", "AutoChannelEnabled": "0"])
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(throws: RouterError.invalidSession) { try F460Page(html: String(decoding: data, as: UTF8.self)) }
        #expect(try await counters()["tokensRejected"] == 1)
        #expect(try await client.read().channel == .automatic)
    }

    @Test func expiredTokenStopsUntilExplicitRefreshAndRetry() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("expire-next")
        await #expect(throws: RouterError.invalidSession) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 1)
        #expect(try await counters()["tokensRejected"] == 1)
        let refreshed = try await client.read()
        let after = try await client.apply(.fixed(6), expected: refreshed)
        #expect(after.channel == .fixed(6))
        #expect(try await counters()["posts"] == 2)
    }

    @Test func disconnectedPostIsVerifiedWithoutResubmission() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("drop-next")
        let after = try await client.apply(.fixed(11), expected: before)
        #expect(after.channel == .fixed(11))
        #expect(try await counters()["posts"] == 1)
    }

    @Test func expiredAdminSessionRequiresLoginWithoutSendingApply() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("expire-session")
        await #expect(throws: RouterError.loginRequired) { try await client.read() }
        await #expect(throws: RouterError.loginRequired) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 0)
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        #expect(try await client.read().channel == .automatic)
    }

    @Test func activeAdminSessionBlocksLoginAndApplyWithoutPosting() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("admin-busy")
        await #expect(throws: RouterError.adminSessionInUse) { try await client.read() }
        await #expect(throws: RouterError.adminSessionInUse) { try await client.login(username: "fixture-admin", password: "fixture-password") }
        // Preflight detects the expired session before any change is submitted.
        await #expect(throws: RouterError.adminSessionInUse) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 0)
        #expect(try await counters()["logins"] == 1)
    }

    @Test func expiryDuringVerificationRequestsLoginWithoutReposting() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("expire-during-verification")
        await #expect(throws: RouterError.loginRequired) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 1)
        let afterLogin = try await client.login(username: "fixture-admin", password: "fixture-password")
        #expect(afterLogin.channel == .fixed(6))
        #expect(try await counters()["posts"] == 1)
    }

    @Test func staleConfigurationNeverPosts() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("external-change")
        await #expect(throws: RouterError.configurationChanged) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 0)
    }

    @Test func rejectedChangeIsNotReportedAsSuccess() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("reject-next")
        await #expect(throws: RouterError.rejected) { try await client.apply(.fixed(6), expected: before) }
        #expect(try await counters()["posts"] == 1)
        #expect(try await client.read().channel == .automatic)
    }

    @Test func logoutReleasesCurrentSessionWithFreshTokenOnlyOnce() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        _ = try await client.apply(.fixed(6), expected: before)
        #expect(await client.hasSession)
        #expect(try await counters()["logouts"] == 0)
        #expect(try await client.logout())
        #expect(await !client.hasSession)
        #expect(try await counters()["logouts"] == 1)
        #expect(try await counters()["logoutAttempts"] == 1)
        #expect(try await counters()["logins"] == 1)
        #expect(try await client.logout() == false)
        #expect(try await counters()["logoutAttempts"] == 1)
        await #expect(throws: RouterError.loginRequired) { try await client.read() }
    }

    @Test func logoutDoesNotLoginOrForceAnotherAdminOut() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("admin-busy")
        _ = try await client.logout()
        #expect(try await counters()["logouts"] == 0)
        #expect(try await counters()["logins"] == 1)
        await #expect(throws: RouterError.adminSessionInUse) { try await client.read() }
        let newClient = try F460Client(address: address())
        #expect(try await newClient.logout() == false)
        #expect(try await counters()["logoutAttempts"] == 1)
    }

    @Test func logoutVerifiesProtectedPageAfterDroppedResponse() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("drop-logout")
        #expect(try await client.logout())
        #expect(try await counters()["logoutAttempts"] == 1)
        #expect(try await counters()["logouts"] == 1)
    }

    @Test func loginHtmlIsNotEnoughToClaimLogoutSucceeded() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("lie-logout")
        await #expect(throws: RouterError.logoutUnverified) { try await client.logout() }
        #expect(await client.hasSession)
        #expect(try await counters()["logoutAttempts"] == 1)
        #expect(try await counters()["logouts"] == 0)
    }

    @Test func sessionOperationsCannotLogoutWhileApplying() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await simulator("delay-apply")
        let apply = Task { try await client.apply(.fixed(6), expected: before) }
        for _ in 0..<100 {
            if try await counters()["posts"] == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await #expect(throws: RouterError.operationInProgress) { try await client.logout() }
        _ = try await apply.value
        #expect(try await counters()["logoutAttempts"] == 0)
        _ = try await client.logout()
    }

    @MainActor
    private func testModel(idleTimeout: Duration = .seconds(120)) -> (AppModel, UserDefaults, String) {
        let name = "app.iwifyou.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: name)!
        let model = AppModel(demo: false, defaults: preferences, credentialStore: MemoryCredentials(), idleTimeout: idleTimeout)
        return (model, preferences, name)
    }

    @MainActor
    private func waitUntilReleased(_ model: AppModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while clock.now < deadline {
            if case .released = model.state { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Idle logout did not complete")
        throw RouterError.logoutUnverified
    }

    @MainActor
    @Test func idleLogoutAndKeychainReauthenticationAreAutomatic() async throws {
        try await simulator("reset")
        let (model, preferences, name) = testModel(idleTimeout: .milliseconds(100))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(try await model.connect(address: address().url.absoluteString, username: "fixture-admin", password: "fixture-password", remember: true))
        try await waitUntilReleased(model)
        #expect(model.state.snapshot != nil)
        #expect(try await counters()["logouts"] == 1)
        model.selectChannel(.fixed(6))
        await model.applySelectedChannel()
        #expect(model.state.snapshot?.channel == .fixed(6))
        #expect(try await counters()["logins"] == 2)
        #expect(try await counters()["posts"] == 1)
        _ = await model.releaseSession()
    }

    @MainActor
    @Test func repeatedChangesReuseSessionAndIdleTimerWaitsForApply() async throws {
        try await simulator("reset")
        let (model, preferences, name) = testModel(idleTimeout: .milliseconds(100))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(try await model.connect(address: address().url.absoluteString, username: "fixture-admin", password: "fixture-password", remember: true))
        model.selectChannel(.fixed(6))
        await model.applySelectedChannel()
        #expect(try await counters()["logins"] == 1)
        #expect(try await counters()["logouts"] == 0)
        try await simulator("delay-apply")
        model.selectChannel(.fixed(11))
        let apply = Task { await model.applySelectedChannel() }
        try await Task.sleep(for: .milliseconds(160))
        #expect(try await counters()["logoutAttempts"] == 0)
        await apply.value
        #expect(model.state.snapshot?.channel == .fixed(11))
        try await waitUntilReleased(model)
        #expect(try await counters()["logins"] == 1)
        #expect(try await counters()["logouts"] == 1)
    }

    @MainActor
    @Test func browserHandoffReleasesSessionWithoutReacquiringIt() async throws {
        try await simulator("reset")
        let (model, preferences, name) = testModel()
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(try await model.connect(address: address().url.absoluteString, username: "fixture-admin", password: "fixture-password", remember: false))
        #expect(try await model.prepareAdminBrowser() == address().url)
        await model.startIfNeeded()
        #expect(model.statusText == "Sesi admin dilepas")
        #expect(try await counters()["logouts"] == 1)
        #expect(try await counters()["logins"] == 1)
        model.selectChannel(.fixed(6))
        #expect(model.requiresLoginBeforeApply)
    }

    @MainActor
    @Test func browserDoesNotOpenWhenLogoutCannotBeVerified() async throws {
        try await simulator("reset")
        let (model, preferences, name) = testModel()
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(try await model.connect(address: address().url.absoluteString, username: "fixture-admin", password: "fixture-password", remember: false))
        try await simulator("lie-logout")
        #expect(await model.prepareAdminBrowser() == nil)
        #expect(model.message == RouterError.logoutUnverified.localizedDescription)
        #expect(try await counters()["logoutAttempts"] == 1)
        try await simulator("allow-logout")
        #expect(await model.prepareAdminBrowser() != nil)
    }
}

private actor MemoryCredentials: RouterCredentialStore {
    private var values: [String: String] = [:]
    func password(for account: String) async throws -> String? { values[account] }
    func save(_ password: String, for account: String) async throws { values[account] = password }
    func remove(account: String) async throws { values[account] = nil }
}

// Same suite, so these never run concurrently with the WLAN tests above
// against the shared simulator state.
extension ClientIntegrationTests {
    private func simulatedState() async throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
    }

    private func filterPosts() async throws -> Int { try await simulatedState()["filter_posts"] as? Int ?? -1 }

    @Test func readsDevicesActivityAndFilter() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        await #expect(throws: RouterError.loginRequired) { try await client.devices() }
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        let list = try await client.devices()
        #expect(list.devices.map(\.mac) == ["02:00:5e:10:00:01", "02:00:5e:10:00:02", "02:00:5e:10:00:03"])
        #expect(list.activeMACs == ["02:00:5e:10:00:01", "02:00:5e:10:00:02"])
        #expect(!list.filter.enabled)
        #expect(try await filterPosts() == 0)
    }

    @Test func blockingEnablesBlacklistOnceThenAddsRuleAndUnblockDeletesIt() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var list = try await client.devices()
        list = try await client.setBlocked("02:00:5e:10:00:03", blocked: true, expected: list.filter)
        #expect(list.filter.enabled && list.filter.mode == .blacklist)
        #expect(list.filter.blockedMACs == ["02:00:5e:10:00:03"])
        #expect(try await filterPosts() == 2) // basic_apply, then new
        list = try await client.setBlocked("02:00:5e:10:00:03", blocked: true, expected: list.filter)
        #expect(try await filterPosts() == 2) // already blocked: nothing sent
        list = try await client.setBlocked("02:00:5e:10:00:02", blocked: true, expected: list.filter)
        #expect(try await filterPosts() == 3) // filter already on: only new
        list = try await client.setBlocked("02:00:5e:10:00:03", blocked: false, expected: list.filter)
        #expect(list.filter.blockedMACs == ["02:00:5e:10:00:02"])
        #expect(try await filterPosts() == 4)
        #expect(try await simulatedState()["tokens_rejected"] as? Int == 0)
    }

    @Test func staleFilterNeverPosts() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        let list = try await client.devices()
        try await simulator("external-filter-change")
        await #expect(throws: RouterError.configurationChanged) {
            try await client.setBlocked("02:00:5e:10:00:03", blocked: true, expected: list.filter)
        }
        #expect(try await filterPosts() == 0)
    }

    @Test func whitelistIsNeverTouched() async throws {
        try await simulator("reset")
        try await simulator("whitelist")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        let list = try await client.devices()
        #expect(!list.filter.canBlock)
        await #expect(throws: RouterError.filterModeUnsupported) {
            try await client.setBlocked("02:00:5e:10:00:03", blocked: true, expected: list.filter)
        }
        #expect(try await filterPosts() == 0)
    }

    @Test func droppedFilterResponseIsVerifiedWithoutResubmission() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var list = try await client.devices()
        list = try await client.setBlocked("02:00:5e:10:00:03", blocked: true, expected: list.filter)
        try await simulator("drop-filter-post")
        list = try await client.setBlocked("02:00:5e:10:00:02", blocked: true, expected: list.filter)
        #expect(list.filter.blockedMACs == ["02:00:5e:10:00:03", "02:00:5e:10:00:02"])
        #expect(try await filterPosts() == 3)
    }

    @Test func restartPostsOnceDropsSessionAndRouterComesBack() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        try await client.restart()
        #expect(try await simulatedState()["restarts"] as? Int == 1)
        #expect(await !client.hasSession)
        #expect(await !client.isReachable())
        try await Task.sleep(for: .seconds(2))
        #expect(await client.isReachable())
        await #expect(throws: RouterError.loginRequired) { try await client.devices() }
        #expect(try await simulatedState()["restarts"] as? Int == 1)
    }
}

extension ClientIntegrationTests {
    private func listPosts() async throws -> Int {
        let value = try JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any]
        return value?["list_posts"] as? Int ?? -1
    }

    @Test func readsStatusPages() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        await #expect(throws: RouterError.loginRequired) { try await client.status() }
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        let status = try await client.status()
        #expect(status.info.model == "F460")
        #expect(status.wan.connected)
        #expect(status.optical.fiber?.health == .good)
        #expect(status.wlan.channel == 6)
    }

    @Test func changesWiFiNameAndPasswordOnceAndVerifies() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        let before = try await client.login(username: "fixture-admin", password: "fixture-password")
        let after = try await client.changeCredentials(ssid: "Rumah Baru", passphrase: "password-baru-123", expected: before)
        #expect(after.ssid == "Rumah Baru")
        #expect(after.channel == before.channel)
        let state = try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
        #expect(state["credential_posts"] as? Int == 1)
        #expect(state["passphrase"] as? String == "password-baru-123")
        // Same values again: nothing is sent.
        _ = try await client.changeCredentials(ssid: "Rumah Baru", passphrase: "password-baru-123", expected: after)
        let again = try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
        #expect(again["credential_posts"] as? Int == 1)
        // A stale snapshot never posts.
        await #expect(throws: RouterError.configurationChanged) {
            try await client.changeCredentials(ssid: "Lain", passphrase: nil, expected: before)
        }
    }

    @Test func dhcpReservationsAddAndRemove() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var list = try await client.reservations()
        list = try await client.addReservation(ip: "192.168.1.20", mac: "02:00:5e:10:00:02", expected: list)
        #expect(list.reservations == [DHCPReservation(ip: "192.168.1.20", mac: "02:00:5e:10:00:02")])
        await #expect(throws: RouterError.duplicateEntry) {
            try await client.addReservation(ip: "192.168.1.21", mac: "02:00:5e:10:00:02", expected: list)
        }
        list = try await client.removeReservation(mac: "02:00:5e:10:00:02", expected: list)
        #expect(list.reservations.isEmpty)
        #expect(try await listPosts() == 2)
    }

    @Test func portForwardsAddAndRemove() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var forwards = try await client.portForwards()
        let rule = PortForward(name: "CCTV", proto: .tcp, externalStart: 8080, externalEnd: 8080, internalHost: "192.168.1.20", internalPort: 80)
        forwards = try await client.addPortForward(rule, connection: forwards.connections[0], expected: forwards)
        #expect(forwards.rules == [rule])
        let stale = forwards
        forwards = try await client.removePortForward(name: "CCTV", expected: forwards)
        #expect(forwards.rules.isEmpty)
        await #expect(throws: RouterError.configurationChanged) { try await client.removePortForward(name: "CCTV", expected: stale) }
        #expect(try await listPosts() == 2)
    }

    @Test func siteBlockingEnablesBlacklistThenAdds() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var filter = try await client.siteFilter()
        filter = try await client.blockSite("https://Judi.Example/", expected: filter)
        #expect(filter.enabled && filter.sites == ["judi.example"])
        #expect(try await listPosts() == 2) // basic_apply, then new
        filter = try await client.blockSite("video.example", expected: filter)
        #expect(try await listPosts() == 3)
        filter = try await client.unblockSite("judi.example", expected: filter)
        #expect(filter.sites == ["video.example"])
        #expect(try await listPosts() == 4)
    }
}

extension ClientIntegrationTests {
    @Test func dnsBlockingAddsEachNameOnceAndRemovesThem() async throws {
        try await simulator("reset")
        let client = try F460Client(address: address())
        _ = try await client.login(username: "fixture-admin", password: "fixture-password")
        var list = try await client.dnsBlocklist()
        list = try await client.blockNames(SitePreset.youtube.hosts, expected: list)
        #expect(list.blockedNames == Set(SitePreset.youtube.hosts))
        let state = try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
        #expect(state["list_posts"] as? Int == SitePreset.youtube.hosts.count)
        // Already present: nothing is sent.
        list = try await client.blockNames(["youtube.com"], expected: list)
        list = try await client.unblockNames(["www.youtube.com", "youtube.com"], expected: list)
        #expect(!list.blockedNames.contains("youtube.com") && list.blockedNames.contains("m.youtube.com"))
        let after = try #require(JSONSerialization.jsonObject(with: await simulator("state")) as? [String: Any])
        #expect(after["list_posts"] as? Int == SitePreset.youtube.hosts.count + 2)
    }
}
