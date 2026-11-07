import Foundation

public actor F460Client {
    public nonisolated let address: RouterAddress
    private let session: URLSession
    private var logoutBody: Data?
    private var sessionUncertain = false
    private var operationInFlight = false

    public var hasSession: Bool { logoutBody != nil || sessionUncertain }

    public init(address: RouterAddress) {
        self.address = address
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.connectionProxyDictionary = [:]
        configuration.httpShouldSetCookies = true
        session = URLSession(
            configuration: configuration,
            delegate: LocalRedirectDelegate(address: address), delegateQueue: nil
        )
    }

    deinit { session.invalidateAndCancel() }

    public func read() async throws -> RouterSnapshot {
        try beginOperation()
        defer { operationInFlight = false }
        return try await page().snapshot
    }

    /// One login attempt per explicit call. Never retry a rejected password.
    public func login(username: String, password: String) async throws -> RouterSnapshot {
        try beginOperation()
        defer { operationInFlight = false }
        guard !username.isEmpty, !password.isEmpty else { throw RouterError.loginFailed }
        let html = try await request(path: "")
        let token = try F460Page.loginToken(in: html)
        let response = try await request(path: "", body: FormEncoding.data([
            "Username": username, "Password": password, "action": "login",
            "Frm_Logintoken": token, "frashnum": "",
        ]))
        if F460Page.isAdminSessionInUse(response) { throw RouterError.adminSessionInUse }
        if F460Page.isSessionTimeout(response) { throw RouterError.loginRequired }
        if F460Page.isLoginPage(response) { throw RouterError.loginFailed }
        sessionUncertain = logoutBody == nil
        return try await page().snapshot
    }

    public func apply(_ channel: WiFiChannel, expected: RouterSnapshot) async throws -> RouterSnapshot {
        try beginOperation()
        defer { operationInFlight = false }
        let latest = try await page()
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard latest.snapshot.revision == expected.revision else { throw RouterError.configurationChanged }
        if latest.snapshot.channel == channel { return latest.snapshot }
        let body = try latest.payload(for: channel)
        try Task.checkCancellation()
        do {
            let response = try await request(path: F460Page.path, body: body)
            // A successful transport response is not proof that settings changed.
            _ = try F460Page(html: response)
        } catch let error as RouterError {
            switch error {
            case .rejected, .invalidSession, .loginRequired, .adminSessionInUse, .httpStatus(401), .httpStatus(403): throw error
            default: break // The Wi-Fi link may have dropped during the POST.
            }
        } catch {
            // Never replay a POST after a timeout. Verify with read-only requests.
        }
        for attempt in 0..<5 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            let result: RouterSnapshot
            do {
                result = try await page().snapshot
            } catch RouterError.loginRequired {
                throw RouterError.loginRequired
            } catch RouterError.adminSessionInUse {
                throw RouterError.adminSessionInUse
            } catch {
                continue
            }
            if result.channel == channel {
                guard result.otherSettingsRevision == latest.snapshot.otherSettingsRevision else {
                    throw RouterError.otherSettingsChanged
                }
                return result
            }
        }
        throw RouterError.unverified
    }

    public func devices() async throws -> DeviceList {
        try beginOperation()
        defer { operationInFlight = false }
        return try await readDevices()
    }

    /// Adds or removes one blacklist rule, then verifies it by reading the
    /// filter again. A POST is never replayed after an uncertain response.
    public func setBlocked(_ input: String, blocked: Bool, expected: MACFilterState) async throws -> DeviceList {
        try beginOperation()
        defer { operationInFlight = false }
        guard let mac = MACAddress.normalize(input) else { throw RouterError.invalidDevice }
        var filter = try F460MACFilter(form: await form(F460MACFilter.page))
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard filter.state.revision == expected.revision else { throw RouterError.configurationChanged }
        if filter.state.blockedMACs.contains(mac) == blocked { return try await readDevices() }
        if blocked {
            if !filter.state.enabled || filter.state.mode != .blacklist {
                try await submit(filter.enablePayload(), to: F460MACFilter.page)
                filter = try await verifiedFilter { $0.enabled && $0.mode == .blacklist }
            }
            try await submit(filter.blockPayload(mac), to: F460MACFilter.page)
        } else {
            try await submit(filter.unblockPayload(mac), to: F460MACFilter.page)
        }
        _ = try await verifiedFilter { $0.blockedMACs.contains(mac) == blocked }
        return try await readDevices()
    }

    /// Sends the observed reboot form once. The admin session dies with the
    /// reboot, so local session state is dropped either way.
    public func restart() async throws {
        try beginOperation()
        defer { operationInFlight = false }
        let restart = try F460Restart(form: await form(F460Restart.page))
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        // Explicit rejections surface; a dropped connection is expected as
        // the router goes down and is judged by reachability afterwards.
        try await submit(restart.payload(), to: F460Restart.page)
        logoutBody = nil
        sessionUncertain = false
        if let cookies = session.configuration.httpCookieStorage?.cookies {
            for cookie in cookies { session.configuration.httpCookieStorage?.deleteCookie(cookie) }
        }
    }

    // MARK: Status

    public func status() async throws -> RouterStatus {
        try beginOperation()
        defer { operationInFlight = false }
        let info = try F460Status.device(await protectedHTML(F460Status.devicePage))
        let wan = try F460Status.wan(await protectedHTML(F460Status.wanPage))
        let optical = try F460Status.optical(await protectedHTML(F460Status.opticalPage))
        let wlan = try F460Status.wlan(await protectedHTML(F460Status.wlanPage))
        return RouterStatus(info: info, wan: wan, optical: optical, wlan: wlan)
    }

    // MARK: Wi-Fi name and password

    /// Sends the new name and/or passphrase once. The Mac usually loses
    /// Wi-Fi right after, so verification may only succeed after it rejoins.
    public func changeCredentials(ssid: String?, passphrase: String?, expected: RouterSnapshot) async throws -> RouterSnapshot {
        try beginOperation()
        defer { operationInFlight = false }
        let latest = try await page()
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard latest.snapshot.revision == expected.revision else { throw RouterError.configurationChanged }
        let newSSID = ssid == latest.snapshot.ssid ? nil : ssid
        let newPassphrase = passphrase.flatMap { latest.hasPassphrase($0) ? nil : $0 }
        guard newSSID != nil || newPassphrase != nil else { return latest.snapshot }
        let body = try latest.credentialsPayload(ssid: newSSID, passphrase: newPassphrase)
        let before = latest.settingsRevisionExcludingCredentials
        do {
            _ = try F460Page(html: await request(path: F460Page.path, body: body))
        } catch let error as RouterError {
            switch error {
            case .rejected, .invalidSession, .loginRequired, .adminSessionInUse, .httpStatus(401), .httpStatus(403): throw error
            default: break
            }
        } catch {
            // Never replay; the Wi-Fi link usually drops at this point.
        }
        for attempt in 0..<5 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            let result: F460Page
            do { result = try await page() }
            catch let error as RouterError where [.loginRequired, .adminSessionInUse].contains(error) { throw error }
            catch { continue }
            let nameOK = newSSID.map { result.snapshot.ssid == $0 } ?? true
            let keyOK = newPassphrase.map { result.hasPassphrase($0) } ?? true
            if nameOK && keyOK {
                guard result.settingsRevisionExcludingCredentials == before else { throw RouterError.otherSettingsChanged }
                return result.snapshot
            }
        }
        throw RouterError.unverified
    }

    // MARK: DHCP reservations

    public func reservations() async throws -> DHCPReservations {
        try beginOperation()
        defer { operationInFlight = false }
        return try F460DHCPStatic(form: await form(F460DHCPStatic.page)).state
    }

    public func addReservation(ip: String, mac: String, expected: DHCPReservations) async throws -> DHCPReservations {
        try await change(F460DHCPStatic.page, parse: F460DHCPStatic.init, revision: { $0.state.revision }, expected: expected.revision,
                         payloads: { [try $0.addPayload(ip: ip, mac: mac)] },
                         done: { $0.state.reservations.contains { $0.mac == MACAddress.normalize(mac) && $0.ip == IPv4.normalize(ip) } }).state
    }

    public func removeReservation(mac: String, expected: DHCPReservations) async throws -> DHCPReservations {
        try await change(F460DHCPStatic.page, parse: F460DHCPStatic.init, revision: { $0.state.revision }, expected: expected.revision,
                         payloads: { [try $0.removePayload(mac: mac)] },
                         done: { !$0.state.reservations.contains { $0.mac == mac } }).state
    }

    // MARK: Port forwarding

    public func portForwards() async throws -> PortForwards {
        try beginOperation()
        defer { operationInFlight = false }
        return try F460PortForward(form: await form(F460PortForward.page)).state
    }

    public func addPortForward(_ rule: PortForward, connection: WANConnection, expected: PortForwards) async throws -> PortForwards {
        try await change(F460PortForward.page, parse: F460PortForward.init, revision: { $0.state.revision }, expected: expected.revision,
                         payloads: { [try $0.addPayload(rule, connection: connection)] },
                         done: { $0.state.rules.contains { $0.name == rule.name } }).state
    }

    public func removePortForward(name: String, expected: PortForwards) async throws -> PortForwards {
        try await change(F460PortForward.page, parse: F460PortForward.init, revision: { $0.state.revision }, expected: expected.revision,
                         payloads: { [try $0.removePayload(name: name)] },
                         done: { !$0.state.rules.contains { $0.name == name } }).state
    }

    // MARK: Website blocking

    public func siteFilter() async throws -> SiteFilter {
        try beginOperation()
        defer { operationInFlight = false }
        return try F460URLFilter(form: await form(F460URLFilter.page, allowingDuplicates: F460URLFilter.duplicates)).state
    }

    public func blockSite(_ input: String, expected: SiteFilter) async throws -> SiteFilter {
        guard let site = SiteFilter.normalize(input) else {
            throw RouterError.invalidRule("Alamat situs hanya boleh berisi huruf, angka, dan tanda baca URL (maks. 256).")
        }
        return try await change(
            F460URLFilter.page, duplicates: F460URLFilter.duplicates, parse: F460URLFilter.init,
            revision: { $0.state.revision }, expected: expected.revision,
            // Mirrors ticking Enable (blacklist) first, then Add.
            payloads: { $0.state.enabled && $0.state.mode == .blacklist ? nil : [try $0.enablePayload()] },
            done: { $0.state.enabled && $0.state.mode == .blacklist },
            then: { [try $0.addPayload(site)] },
            finally: { $0.state.sites.contains(site) }
        ).state
    }

    public func unblockSite(_ site: String, expected: SiteFilter) async throws -> SiteFilter {
        try await change(F460URLFilter.page, duplicates: F460URLFilter.duplicates, parse: F460URLFilter.init,
                         revision: { $0.state.revision }, expected: expected.revision,
                         payloads: { [try $0.removePayload(site)] },
                         done: { !$0.state.sites.contains(site) }).state
    }

    // MARK: DNS blocking (Hosts)

    public func dnsBlocklist() async throws -> DNSBlocklist {
        try beginOperation()
        defer { operationInFlight = false }
        return try F460Hosts(form: await form(F460Hosts.page, allowingDuplicates: F460Hosts.duplicates)).state
    }

    /// Adds names one at a time, each sent once and verified before the
    /// next, as the page itself only adds a single row per submit.
    public func blockNames(_ names: [String], expected: DNSBlocklist) async throws -> DNSBlocklist {
        try beginOperation()
        defer { operationInFlight = false }
        var current = try F460Hosts(form: await form(F460Hosts.page, allowingDuplicates: F460Hosts.duplicates))
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard current.state.revision == expected.revision else { throw RouterError.configurationChanged }
        for name in names.compactMap(DNSBlocklist.normalize) where !current.state.hosts.contains(where: { $0.name == name }) {
            try await submit(current.addPayload(name), to: F460Hosts.page, allowingDuplicates: F460Hosts.duplicates)
            current = try await verified(F460Hosts.page, duplicates: F460Hosts.duplicates, parse: F460Hosts.init) { list in
                list.state.hosts.contains { $0.name == name }
            }
        }
        return current.state
    }

    public func unblockNames(_ names: Set<String>, expected: DNSBlocklist) async throws -> DNSBlocklist {
        try beginOperation()
        defer { operationInFlight = false }
        var current = try F460Hosts(form: await form(F460Hosts.page, allowingDuplicates: F460Hosts.duplicates))
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard current.state.revision == expected.revision else { throw RouterError.configurationChanged }
        // Indexes shift after each delete, so every removal re-reads first.
        for name in names.sorted() where current.state.hosts.contains(where: { $0.name == name }) {
            try await submit(current.removePayload(name), to: F460Hosts.page, allowingDuplicates: F460Hosts.duplicates)
            current = try await verified(F460Hosts.page, duplicates: F460Hosts.duplicates, parse: F460Hosts.init) { list in
                !list.state.hosts.contains { $0.name == name }
            }
        }
        return current.state
    }

    /// One verified change: read, compare revision, POST once, read back.
    /// An optional second step runs after the first is verified.
    private func change<P>(
        _ page: String, duplicates: Set<String> = [], parse: (F460Form) throws -> P,
        revision: (P) -> String, expected: String,
        payloads: (P) throws -> [Data]?, done: (P) -> Bool,
        then next: ((P) throws -> [Data]?)? = nil, finally finished: ((P) -> Bool)? = nil
    ) async throws -> P {
        try beginOperation()
        defer { operationInFlight = false }
        var current = try parse(await form(page, allowingDuplicates: duplicates))
        guard logoutBody != nil else { throw RouterError.logoutUnavailable }
        guard revision(current) == expected else { throw RouterError.configurationChanged }
        current = try await step(page, duplicates, parse, current, payloads, done)
        if let next, let finished {
            current = try await step(page, duplicates, parse, current, next, finished)
        }
        return current
    }

    private func step<P>(
        _ page: String, _ duplicates: Set<String>, _ parse: (F460Form) throws -> P, _ current: P,
        _ bodies: (P) throws -> [Data]?, _ condition: (P) -> Bool
    ) async throws -> P {
        if condition(current) { return current }
        guard let requests = try bodies(current) else { return current }
        for body in requests { try await submit(body, to: page, allowingDuplicates: duplicates) }
        return try await verified(page, duplicates: duplicates, parse: parse, condition)
    }

    private func verified<P>(_ page: String, duplicates: Set<String>, parse: (F460Form) throws -> P, _ condition: (P) -> Bool) async throws -> P {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let value: P
            do { value = try parse(await form(page, allowingDuplicates: duplicates)) }
            catch let error as RouterError where [.loginRequired, .adminSessionInUse].contains(error) { throw error }
            catch { continue }
            if condition(value) { return value }
        }
        throw RouterError.unverified
    }

    private func protectedHTML(_ page: String) async throws -> String {
        let html = try await request(path: F460Form.path(page))
        if F460Page.isAdminSessionInUse(html) { throw RouterError.adminSessionInUse }
        if F460Page.isLoginPage(html) || F460Page.isSessionTimeout(html) {
            if let root = try? await request(path: ""), F460Page.isAdminSessionInUse(root) {
                throw RouterError.adminSessionInUse
            }
            throw RouterError.loginRequired
        }
        if logoutBody == nil { sessionUncertain = true }
        return html
    }

    /// Read-only reachability probe used while waiting for a reboot.
    public func isReachable() async -> Bool {
        (try? await request(path: "", observeSession: false)) != nil
    }

    private func readDevices() async throws -> DeviceList {
        let devices = try F460Devices.devices(await form(F460Devices.lanPage))
        let active = try F460Devices.activeMACs(await form(F460Devices.arpPage))
        let filter = try F460MACFilter(form: await form(F460MACFilter.page))
        return DeviceList(devices: devices, activeMACs: active, filter: filter.state)
    }

    private func verifiedFilter(_ condition: (MACFilterState) -> Bool) async throws -> F460MACFilter {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let filter: F460MACFilter
            do {
                filter = try F460MACFilter(form: await form(F460MACFilter.page))
            } catch let error as RouterError where [.loginRequired, .adminSessionInUse].contains(error) {
                throw error
            } catch {
                continue
            }
            if condition(filter.state) { return filter }
        }
        throw RouterError.unverified
    }

    private func submit(_ body: Data, to page: String, allowingDuplicates: Set<String> = []) async throws {
        try Task.checkCancellation()
        do {
            // A successful transport response is not proof; callers verify.
            _ = try F460Form(html: await request(path: F460Form.path(page), body: body), page: page, allowingDuplicates: allowingDuplicates)
        } catch let error as RouterError {
            switch error {
            case .rejected, .invalidSession, .loginRequired, .adminSessionInUse, .httpStatus(401), .httpStatus(403): throw error
            default: break
            }
        } catch {
            // Never replay a POST after a timeout. Verify with reads.
        }
    }

    private func form(_ page: String, allowingDuplicates: Set<String> = []) async throws -> F460Form {
        do {
            let form = try F460Form(html: await request(path: F460Form.path(page)), page: page, allowingDuplicates: allowingDuplicates)
            if logoutBody == nil { sessionUncertain = true }
            return form
        } catch RouterError.loginRequired {
            if let root = try? await request(path: ""), F460Page.isAdminSessionInUse(root) {
                throw RouterError.adminSessionInUse
            }
            throw RouterError.loginRequired
        }
    }

    /// Uses the last token issued to this URLSession. No login or token refresh
    /// is attempted to force logout of a different/newer admin session.
    @discardableResult
    public func logout() async throws -> Bool {
        try beginOperation()
        defer { operationInFlight = false }
        guard let body = logoutBody else {
            if sessionUncertain { throw RouterError.logoutUnverified }
            return false
        }
        logoutBody = nil
        sessionUncertain = true
        // A dropped response may mean logout already committed. Never replay it.
        _ = try? await request(path: "", body: body, observeSession: false)
        let verification: String
        do {
            verification = try await request(path: F460Page.path, observeSession: false)
        } catch {
            throw RouterError.logoutUnverified
        }
        if F460Page.isLoginPage(verification) || F460Page.isSessionTimeout(verification)
            || F460Page.isAdminSessionInUse(verification) {
            sessionUncertain = false
            if let cookies = session.configuration.httpCookieStorage?.cookies {
                for cookie in cookies { session.configuration.httpCookieStorage?.deleteCookie(cookie) }
            }
            return true
        }
        // The protected page is still accessible. Preserve this session's fresh
        // receipt for an explicit retry, without claiming logout succeeded.
        observe(verification)
        throw RouterError.logoutUnverified
    }

    private func beginOperation() throws {
        guard !operationInFlight else { throw RouterError.operationInProgress }
        operationInFlight = true
    }

    private func observe(_ html: String) {
        if F460Page.isLoginPage(html) || F460Page.isSessionTimeout(html) || F460Page.isAdminSessionInUse(html) {
            logoutBody = nil
            sessionUncertain = false
        } else if let body = try? F460Page.logoutPayload(in: html) {
            logoutBody = body
            sessionUncertain = false
        } else if html.contains("CONFIG_PARA") {
            logoutBody = nil
            sessionUncertain = true
        }
    }

    private func page() async throws -> F460Page {
        do {
            let page = try F460Page(html: await request(path: F460Page.path))
            if logoutBody == nil { sessionUncertain = true }
            return page
        } catch RouterError.loginRequired {
            // F460 returns a timeout page for WLAN requests even when a
            // different admin session is keeping the login page locked.
            if let root = try? await request(path: ""), F460Page.isAdminSessionInUse(root) {
                throw RouterError.adminSessionInUse
            }
            throw RouterError.loginRequired
        }
    }

    private func request(path: String, body: Data? = nil, observeSession: Bool = true) async throws -> String {
        let destination = path.isEmpty ? address.url : URL(string: path, relativeTo: address.url)?.absoluteURL
        guard let url = destination, address.contains(url) else {
            throw RouterError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("iwifyou/0.3.0", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(String(address.url.absoluteString.dropLast()), forHTTPHeaderField: "Origin")
            request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, address.contains(response.url) else {
            throw RouterError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw RouterError.httpStatus(response.statusCode) }
        guard data.count < 2_000_000 else { throw RouterError.invalidResponse }
        // Legacy firmware contains non-UTF8 HTML comments, while scalar values
        // use ASCII JavaScript escapes. Lossy decoding preserves those values.
        let html = String(decoding: data, as: UTF8.self)
        if observeSession { observe(html) }
        return html
    }
}

private final class LocalRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let address: RouterAddress
    init(address: RouterAddress) { self.address = address }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(address.contains(request.url) ? request : nil)
    }
}
