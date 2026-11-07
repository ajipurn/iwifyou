import Darwin
import Foundation
import IWiFiYouCore
import Observation
import UserNotifications

@Observable
final class AppModel {
    enum State {
        case idle
        case loading
        case ready(RouterSnapshot)
        case applying(RouterSnapshot, WiFiChannel)
        case releasing(RouterSnapshot?)
        case released(RouterSnapshot?)
        case needsLogin(String)
        case adminBusy(String)
        case rejected(RouterSnapshot?, String)
        case failed(String)

        var snapshot: RouterSnapshot? {
            switch self {
            case .ready(let value), .applying(let value, _): value
            case .rejected(let previous, _), .releasing(let previous), .released(let previous): previous
            default: nil
            }
        }

        var isBusy: Bool {
            switch self { case .loading, .applying, .releasing: true; default: false }
        }
    }

    enum RestartPhase: Equatable {
        case idle, sending, goingDown, comingBack, done
        case failed(String)

        var isActive: Bool {
            switch self { case .sending, .goingDown, .comingBack: true; default: false }
        }
    }

    private(set) var state = State.idle
    private(set) var message: String?
    private(set) var deviceList: DeviceList?
    private(set) var deviceMessage: String?
    private(set) var deviceError: String?
    private(set) var isLoadingDevices = false
    private(set) var pendingMAC: String?
    private(set) var restartPhase = RestartPhase.idle

    enum RouterArea: Hashable { case status, wifi, network, sites }

    private(set) var routerStatus: RouterStatus?

    struct ChannelSuggestion: Equatable {
        let channel: Int
        let reason: String
        let date: Date
    }

    private(set) var channelSuggestion: ChannelSuggestion?
    private(set) var reservations: DHCPReservations?
    private(set) var portForwards: PortForwards?
    private(set) var siteFilter: SiteFilter?
    private(set) var dnsBlocklist: DNSBlocklist?
    /// Sites the user added, remembered on this Mac so an unblocked site
    /// stays in the list until it is removed.
    private(set) var customSites: [String]
    /// Built-in presets the user removed from the list.
    private(set) var hiddenPresets: Set<String>
    private(set) var activeTask: String?
    private(set) var areaErrors: [RouterArea: String] = [:]
    private(set) var areaMessages: [RouterArea: String] = [:]
    private(set) var deviceNames: [String: String]
    private(set) var watchesNewDevices: Bool
    private(set) var knownMACs: Set<String>
    private(set) var lastWatchCheck: Date?
    private(set) var watchNote: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored let watchInterval: Duration = .seconds(600)
    private(set) var addressText: String
    private(set) var username: String
    private(set) var remembersPassword: Bool
    var selectedChannel = WiFiChannel.automatic
    let isDemo: Bool

    @ObservationIgnored private var client: F460Client?
    @ObservationIgnored private let keychain: any RouterCredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let idleTimeout: Duration
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var handingOffToBrowser = false

    init(
        demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"),
        defaults: UserDefaults? = nil,
        credentialStore: any RouterCredentialStore = KeychainStore(),
        idleTimeout: Duration = .seconds(120)
    ) {
        isDemo = demo
        self.defaults = defaults ?? (demo ? UserDefaults(suiteName: "app.iwifyou.demo")! : .standard)
        keychain = credentialStore
        self.idleTimeout = idleTimeout
        addressText = demo ? "192.168.1.1" : self.defaults.string(forKey: "routerAddress") ?? "192.168.1.1"
        username = demo ? "" : self.defaults.string(forKey: "routerUsername") ?? ""
        remembersPassword = !demo && self.defaults.bool(forKey: "rememberPassword")
        deviceNames = self.defaults.dictionary(forKey: "deviceNames") as? [String: String] ?? [:]
        watchesNewDevices = !demo && self.defaults.bool(forKey: "watchNewDevices")
        knownMACs = Set(self.defaults.stringArray(forKey: "knownDevices") ?? [])
        customSites = self.defaults.stringArray(forKey: "customBlockedSites") ?? (demo ? ["instagram.com"] : [])
        hiddenPresets = Set(self.defaults.stringArray(forKey: "hiddenSitePresets") ?? [])
        if demo { state = .ready(.demo) }
    }

    /// Router operations share one admin session and must never overlap.
    var isWorking: Bool { state.isBusy || isLoadingDevices || pendingMAC != nil || restartPhase.isActive || activeTask != nil }

    /// True while the admin session is live, so screens may load on appear
    /// without logging in just because they were opened.
    var hasLiveSession: Bool {
        if case .ready = state { return true }
        return false
    }

    var canApply: Bool {
        guard canSelectChannel, !isWorking, let snapshot = state.snapshot else { return false }
        return snapshot.channel != selectedChannel && snapshot.availableChannels.contains(selectedChannel)
    }

    var canSelectChannel: Bool {
        switch state {
        case .ready(let snapshot), .released(.some(let snapshot)): snapshot.radioEnabled
        default: false
        }
    }

    var requiresLoginBeforeApply: Bool {
        if case .released = state { return !isDemo && !remembersPassword }
        return false
    }

    var statusText: String {
        switch state {
        case .idle: "Belum terhubung"
        case .loading: "Menghubungkan…"
        case .ready: isDemo ? "Mode demo" : "Terhubung"
        case .applying: "Memverifikasi…"
        case .releasing: "Melepas sesi admin…"
        case .released: "Sesi admin dilepas"
        case .needsLogin: "Perlu login"
        case .adminBusy: "Sesi admin dipakai"
        case .rejected: "Permintaan ditolak"
        case .failed: "Koneksi bermasalah"
        }
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await refresh()
    }

    func selectChannel(_ channel: WiFiChannel) {
        guard canSelectChannel else { return }
        selectedChannel = channel
        if idleTask != nil { armIdleLogout() }
    }

    func noteInteraction() {
        if idleTask != nil { armIdleLogout() }
    }

    func refresh() async {
        guard !isWorking else { return }
        beginActivity()
        let previous = state.snapshot
        message = nil
        state = .loading
        if isDemo { accept(previous ?? .demo); return }
        do {
            let address = try RouterAddress(addressText)
            let connection = client ?? F460Client(address: address)
            client = connection
            accept(try await authenticatedRead(connection))
        } catch { fail(error, lastKnown: previous) }
        await scheduleIdleLogout()
    }

    /// Owns the candidate client even on failure so a partially opened session
    /// is not abandoned when credential storage or a later read fails.
    func connect(address input: String, username inputUsername: String, password: String, remember: Bool) async -> Bool {
        guard !isWorking, !isDemo else { return false }
        beginActivity()
        message = nil
        state = .loading
        var connected = false
        do {
            let address = try RouterAddress(input)
            let name = inputUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if let client { try await client.logout() }
            let connection = F460Client(address: address)
            client = connection
            var storedPassword: String?
            if password.isEmpty && remember && !name.isEmpty {
                storedPassword = try await keychain.password(for: accountID(address, name))
            }
            let secret = password.isEmpty ? (storedPassword ?? "") : password
            let snapshot: RouterSnapshot
            if !secret.isEmpty {
                guard !name.isEmpty else { throw RouterError.loginFailed }
                snapshot = try await connection.login(username: name, password: secret)
            } else {
                snapshot = try await connection.read()
            }
            var saveError: String?
            var savedPassword = remember && !secret.isEmpty
            do {
                if remember && !password.isEmpty && !name.isEmpty {
                    try await keychain.save(password, for: accountID(address, name))
                } else if !remember && !name.isEmpty {
                    try await keychain.remove(account: accountID(address, name))
                }
            } catch {
                savedPassword = false
                saveError = error.localizedDescription
            }
            addressText = address.url.absoluteString
            username = name
            remembersPassword = savedPassword
            defaults.set(addressText, forKey: "routerAddress")
            defaults.set(name, forKey: "routerUsername")
            defaults.set(savedPassword, forKey: "rememberPassword")
            accept(snapshot)
            message = saveError
            connected = saveError == nil
        } catch { fail(error) }
        await scheduleIdleLogout()
        return connected
    }

    func applySelectedChannel() async {
        guard canApply, let previous = state.snapshot else { return }
        beginActivity()
        let target = selectedChannel
        state = .applying(previous, target)
        message = nil
        do {
            let updated: RouterSnapshot
            if isDemo {
                try await Task.sleep(for: .milliseconds(100))
                updated = previous.demoChangingChannel(to: target)
            } else {
                guard let client else { throw RouterError.loginRequired }
                // Reuse the existing session. If it was released, Keychain can
                // authenticate once; never replay an Apply after it was sent.
                _ = try await authenticatedRead(client)
                updated = try await client.apply(target, expected: previous)
            }
            accept(updated)
            message = isDemo ? "Demo: channel \(target.label) dipilih. Router tidak diubah." : "Channel \(target.label) tersimpan dan terverifikasi. Sesi dilepas setelah 2 menit idle."
        } catch { fail(error, lastKnown: previous) }
        await scheduleIdleLogout()
    }

    /// This returns a URL only after the app's session has been released.
    /// It deliberately does not log in just to open the admin page.
    func prepareAdminBrowser() async -> URL? {
        guard !isWorking, !isDemo else { return nil }
        beginActivity()
        handingOffToBrowser = true
        hasStarted = true
        guard await releaseSession() else { return nil }
        return try? RouterAddress(addressText).url
    }

    @discardableResult
    func releaseSession() async -> Bool {
        guard !isWorking else { return false }
        cancelIdleLogout()
        let previous = state.snapshot
        let original = state
        state = .releasing(previous)
        do {
            let didRelease: Bool
            if let client, !isDemo { didRelease = try await client.logout() }
            else { didRelease = isDemo }
            state = .released(previous)
            message = didRelease ? "Sesi admin app sudah dilepas." : "App tidak memegang sesi admin."
            return true
        } catch {
            state = original
            message = error.localizedDescription
            return false
        }
    }

    // MARK: Devices

    func displayName(_ device: ConnectedDevice) -> String {
        deviceNames[device.mac] ?? device.hostName ?? "Perangkat tanpa nama"
    }

    /// A custom or DHCP name when one is known, without falling back to the MAC.
    func knownName(mac: String) -> String? {
        deviceNames[mac] ?? deviceList?.devices.first(where: { $0.mac == mac })?.hostName
    }

    func displayName(mac: String) -> String {
        if let device = deviceList?.devices.first(where: { $0.mac == mac }) { return displayName(device) }
        return deviceNames[mac] ?? mac
    }

    func rename(_ mac: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceNames[mac] = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        defaults.set(deviceNames, forKey: "deviceNames")
    }

    /// Matches the router's DHCP address against this Mac's own IPv4
    /// addresses, so the app never offers to cut off its own connection.
    func isThisMac(_ device: ConnectedDevice) -> Bool {
        isDemo ? device.ip == "192.168.1.3" : Self.localIPv4Addresses().contains(device.ip)
    }

    func refreshDevices() async {
        guard !isWorking else { return }
        beginActivity()
        isLoadingDevices = true
        deviceError = nil
        deviceMessage = nil
        if isDemo {
            try? await Task.sleep(for: .milliseconds(300))
            deviceList = deviceList ?? .demo
            isLoadingDevices = false
            return
        }
        do {
            let address = try RouterAddress(addressText)
            let connection = client ?? F460Client(address: address)
            client = connection
            acceptKeepingSelection(try await authenticatedRead(connection))
            let list = try await connection.devices()
            deviceList = list
            rememberSeen(list)
        } catch { failDevices(error) }
        isLoadingDevices = false
        await scheduleIdleLogout()
    }

    func setBlocked(_ device: ConnectedDevice, _ blocked: Bool) async {
        await setBlocked(mac: device.mac, blocked, protected: blocked && isThisMac(device))
    }

    func setBlocked(mac: String, _ blocked: Bool, protected: Bool = false) async {
        guard !isWorking, let list = deviceList else { return }
        deviceError = nil
        deviceMessage = nil
        if protected {
            deviceError = RouterError.protectedDevice.localizedDescription
            return
        }
        beginActivity()
        pendingMAC = mac
        let name = displayName(mac: mac)
        do {
            if isDemo {
                try await Task.sleep(for: .milliseconds(500))
                deviceList = list.demoBlocking(mac, blocked)
            } else {
                guard let client else { throw RouterError.loginRequired }
                acceptKeepingSelection(try await authenticatedRead(client))
                deviceList = try await client.setBlocked(mac, blocked: blocked, expected: list.filter)
            }
            deviceMessage = (blocked ? "\(name) diblokir" : "Blokir \(name) dibuka") + (isDemo ? " (demo, router tidak diubah)." : " dan terverifikasi.")
        } catch { failDevices(error) }
        pendingMAC = nil
        await scheduleIdleLogout()
    }

    // MARK: Channel suggestions

    func suggestChannel(_ channel: Int, reason: String) {
        channelSuggestion = ChannelSuggestion(channel: channel, reason: reason, date: .now)
    }

    /// Pre-selects the suggestion; applying still needs an explicit click.
    func openSuggestion(_ channel: Int) {
        if canSelectChannel, state.snapshot?.availableChannels.contains(.fixed(channel)) == true {
            selectChannel(.fixed(channel))
        }
    }

    func dismissSuggestion() { channelSuggestion = nil }

    // MARK: Router pages

    func refreshStatus() async {
        if let status = await perform(.status, "Membaca status router…", demo: { RouterStatus.demo }, { try await $0.status() }) {
            routerStatus = status
        }
    }

    func changeWiFi(ssid: String?, passphrase: String?) async -> Bool {
        let newName = ssid ?? state.snapshot?.ssid ?? ""
        let snapshot = await perform(.wifi, "Mengubah Wi-Fi…", demo: { RouterSnapshot.demo }) { client in
            guard let expected = self.state.snapshot else { throw RouterError.loginRequired }
            return try await client.changeCredentials(ssid: ssid, passphrase: passphrase, expected: expected)
        }
        guard let snapshot else {
            if areaErrors[.wifi] == RouterError.unverified.localizedDescription {
                areaErrors[.wifi] = "Perubahan sudah dikirim, tetapi Mac terputus sebelum hasilnya terbaca. Sambungkan Mac ke Wi-Fi \"\(newName)\"" + (passphrase == nil ? "" : " dengan password baru") + ", lalu klik Perbarui."
            }
            return false
        }
        if !isDemo { state = .ready(snapshot) }
        areaMessages[.wifi] = isDemo ? "Demo: router tidak diubah." : "Wi-Fi diperbarui dan terverifikasi. Perangkat lain perlu tersambung ulang" + (passphrase == nil ? "." : " dengan password baru.")
        return true
    }

    func refreshNetwork() async {
        let result = await perform(.network, "Membaca jaringan…", demo: { (DHCPReservations.demo, PortForwards.demo) }) { client in
            (try await client.reservations(), try await client.portForwards())
        }
        if let result { (reservations, portForwards) = result }
    }

    func addReservation(ip: String, mac: String) async {
        guard let current = reservations else { return }
        if let updated = await perform(.network, "Menyimpan IP tetap…", success: "IP tetap tersimpan dan terverifikasi.", demo: { current },
                                       { try await $0.addReservation(ip: ip, mac: mac, expected: current) }) {
            reservations = updated
        }
    }

    func removeReservation(mac: String) async {
        guard let current = reservations else { return }
        if let updated = await perform(.network, "Menghapus IP tetap…", success: "IP tetap dihapus.", demo: { current },
                                       { try await $0.removeReservation(mac: mac, expected: current) }) {
            reservations = updated
        }
    }

    func addPortForward(_ rule: PortForward, connection: WANConnection) async {
        guard let current = portForwards else { return }
        if let updated = await perform(.network, "Menyimpan port forwarding…", success: "Aturan \(rule.name) tersimpan dan terverifikasi.", demo: { current },
                                       { try await $0.addPortForward(rule, connection: connection, expected: current) }) {
            portForwards = updated
        }
    }

    func removePortForward(name: String) async {
        guard let current = portForwards else { return }
        if let updated = await perform(.network, "Menghapus port forwarding…", success: "Aturan \(name) dihapus.", demo: { current },
                                       { try await $0.removePortForward(name: name, expected: current) }) {
            portForwards = updated
        }
    }

    func refreshSites() async {
        let result = await perform(.sites, "Membaca blokir situs…", demo: { (SiteFilter.demo, DNSBlocklist.demo) }) { client in
            (try await client.siteFilter(), try await client.dnsBlocklist())
        }
        if let result { (siteFilter, dnsBlocklist) = result }
    }

    func blockNames(_ names: [String], label: String) async {
        guard let current = dnsBlocklist else { return }
        if let updated = await perform(.sites, "Memblokir \(label)…", success: "\(label) diblokir lewat DNS router dan terverifikasi. Perangkat mungkin perlu beberapa menit atau sambung ulang Wi-Fi.",
                                       demo: { current.demoAdding(names) }, { try await $0.blockNames(names, expected: current) }) {
            dnsBlocklist = updated
        }
    }

    /// Custom sites in display order: remembered ones first, then any site
    /// blocked on the router that iwifyou did not add (outside presets).
    func customSiteList(_ list: DNSBlocklist) -> [String] {
        let presets = Set(SitePreset.allCases.flatMap(\.hosts))
        let discovered = list.hosts.filter { $0.isBlock && !presets.contains($0.name) }.map { DNSBlocklist.site(of: $0.name) }
        var seen = Set<String>()
        return (customSites + discovered).filter { seen.insert($0).inserted }
    }

    func namesForSite(_ site: String, in list: DNSBlocklist) -> Set<String> {
        Set(DNSBlocklist.names(forDomain: site)).union(list.blockedNames.filter { DNSBlocklist.site(of: $0) == site })
    }

    func addSite(_ input: String) async {
        let names = DNSBlocklist.names(forDomain: input)
        guard let site = names.first else { return }
        rememberSite(site)
        await blockNames(names, label: site)
    }

    /// Hapus: unblock everything for the site, then forget it. The site is
    /// only forgotten once the router confirms the entries are gone.
    func removeSite(_ site: String) async {
        guard let list = dnsBlocklist else { return }
        let blocked = namesForSite(site, in: list).intersection(list.blockedNames)
        if !blocked.isEmpty {
            await unblockNames(blocked, label: site)
            guard areaErrors[.sites] == nil else { return }
        }
        customSites.removeAll { $0 == site }
        defaults.set(customSites, forKey: "customBlockedSites")
        areaMessages[.sites] = "\(site) dihapus dari daftar" + (blocked.isEmpty ? "." : " dan tidak diblokir lagi.")
    }

    /// Presets stay visible while any of their names is blocked, so a
    /// block made elsewhere is never hidden from view.
    func visiblePresets(_ list: DNSBlocklist) -> [SitePreset] {
        SitePreset.allCases.filter { preset in
            !hiddenPresets.contains(preset.rawValue) || preset.hosts.contains(where: list.blockedNames.contains)
        }
    }

    var removedPresets: [SitePreset] { SitePreset.allCases.filter { hiddenPresets.contains($0.rawValue) } }

    /// Hapus for a preset: unblock its names, then hide it from the list.
    func removePreset(_ preset: SitePreset) async {
        guard let list = dnsBlocklist else { return }
        let blocked = Set(preset.hosts).intersection(list.blockedNames)
        if !blocked.isEmpty {
            await unblockNames(blocked, label: preset.title)
            guard areaErrors[.sites] == nil else { return }
        }
        hiddenPresets.insert(preset.rawValue)
        defaults.set(Array(hiddenPresets).sorted(), forKey: "hiddenSitePresets")
        areaMessages[.sites] = "\(preset.title) dihapus dari daftar" + (blocked.isEmpty ? "." : " dan tidak diblokir lagi.")
    }

    /// Brings a removed preset back and blocks it.
    func addPreset(_ preset: SitePreset) async {
        hiddenPresets.remove(preset.rawValue)
        defaults.set(Array(hiddenPresets).sorted(), forKey: "hiddenSitePresets")
        await blockNames(preset.hosts, label: preset.title)
    }

    private func rememberSite(_ site: String) {
        guard !customSites.contains(site) else { return }
        customSites.append(site)
        defaults.set(customSites, forKey: "customBlockedSites")
    }

    func unblockNames(_ names: Set<String>, label: String) async {
        guard let current = dnsBlocklist else { return }
        if let updated = await perform(.sites, "Membuka blokir \(label)…", success: "Blokir \(label) dibuka.",
                                       demo: { current.demoRemoving(names) }, { try await $0.unblockNames(names, expected: current) }) {
            dnsBlocklist = updated
        }
    }

    func blockSite(_ site: String) async {
        guard let current = siteFilter else { return }
        if let updated = await perform(.sites, "Memblokir situs…", success: "Situs diblokir dan terverifikasi.", demo: { current },
                                       { try await $0.blockSite(site, expected: current) }) {
            siteFilter = updated
        }
    }

    func unblockSite(_ site: String) async {
        guard let current = siteFilter else { return }
        if let updated = await perform(.sites, "Membuka blokir situs…", success: "Blokir \(site) dibuka.", demo: { current },
                                       { try await $0.unblockSite(site, expected: current) }) {
            siteFilter = updated
        }
    }

    func diagnosisRouterSide() async -> DiagnosisModel.RouterSide {
        guard hasLiveSession || remembersPassword else {
            return DiagnosisModel.RouterSide(note: "Masuk ke router untuk membaca")
        }
        await refreshStatus()
        guard let status = routerStatus, areaErrors[.status] == nil else {
            return DiagnosisModel.RouterSide(note: "Tidak terbaca")
        }
        return DiagnosisModel.RouterSide(
            wanConnected: status.wan.connected, fiber: status.optical.fiber,
            note: status.optical.lossOfSignal ? "Sinyal fiber hilang (LOS)" : nil
        )
    }

    /// Runs one router operation with the shared session rules: never while
    /// another is running, authenticate once (Keychain if stored), and start
    /// the idle timer afterwards. Errors are reported per screen.
    private func perform<T>(
        _ area: RouterArea, _ label: String, success: String? = nil,
        demo: () -> T, _ operation: (F460Client) async throws -> T
    ) async -> T? {
        guard !isWorking else { return nil }
        beginActivity()
        activeTask = label
        areaErrors[area] = nil
        areaMessages[area] = nil
        var result: T?
        if isDemo {
            try? await Task.sleep(for: .milliseconds(400))
            result = demo()
        } else {
            do {
                let address = try RouterAddress(addressText)
                let connection = client ?? F460Client(address: address)
                client = connection
                acceptKeepingSelection(try await authenticatedRead(connection))
                result = try await operation(connection)
            } catch {
                if let routerError = error as? RouterError,
                   [.loginRequired, .loginFailed, .adminSessionInUse].contains(routerError) {
                    fail(routerError, lastKnown: state.snapshot)
                } else if error is URLError {
                    fail(error, lastKnown: state.snapshot)
                }
                areaErrors[area] = error.localizedDescription
            }
        }
        if result != nil, let success { areaMessages[area] = isDemo ? "Demo: router tidak diubah." : success }
        activeTask = nil
        await scheduleIdleLogout()
        return result
    }

    // MARK: New-device notifications

    var routerHost: String { (try? RouterAddress(addressText))?.displayName ?? "192.168.1.1" }

    func setWatchingNewDevices(_ enabled: Bool) async {
        watchNote = nil
        guard !isDemo else { return }
        if enabled {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                watchNote = "Notifikasi iwifyou belum diizinkan. Aktifkan di Pengaturan Sistem › Notifikasi."
                return
            }
            if !remembersPassword {
                watchNote = "Simpan password di Keychain agar pengecekan bisa login sendiri setelah sesi dilepas."
            }
        }
        watchesNewDevices = enabled
        defaults.set(enabled, forKey: "watchNewDevices")
        startWatchingIfNeeded()
    }

    func forgetKnownDevices() {
        knownMACs = []
        defaults.removeObject(forKey: "knownDevices")
    }

    func startWatchingIfNeeded() {
        watchTask?.cancel()
        watchTask = nil
        guard watchesNewDevices, !isDemo else { return }
        let interval = watchInterval
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.checkForNewDevices()
            }
        }
    }

    /// Background check: never changes what the user is looking at, never
    /// forces another admin out, and releases a session it opened itself.
    func checkForNewDevices() async {
        guard watchesNewDevices, !isDemo, !isWorking else { return }
        let hadSession: Bool
        if case .ready = state { hadSession = true } else { hadSession = false }
        guard hadSession || remembersPassword else {
            watchNote = "Pengecekan dilewati: sesi admin sudah dilepas dan password tidak disimpan di Keychain."
            return
        }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            let address = try RouterAddress(addressText)
            let connection = client ?? F460Client(address: address)
            client = connection
            _ = try await authenticatedRead(connection)
            let list = try await connection.devices()
            deviceList = list
            notifyNewDevices(in: list)
            lastWatchCheck = .now
            watchNote = nil
            if !hadSession { _ = try? await connection.logout() }
        } catch RouterError.adminSessionInUse {
            watchNote = "Pengecekan terakhir dilewati karena ada sesi admin lain (misalnya browser)."
        } catch {
            watchNote = "Pengecekan terakhir gagal: \(error.localizedDescription)"
        }
    }

    private func rememberSeen(_ list: DeviceList) {
        guard watchesNewDevices else { return }
        knownMACs.formUnion(list.devices.map(\.mac))
        defaults.set(Array(knownMACs).sorted(), forKey: "knownDevices")
    }

    private func notifyNewDevices(in list: DeviceList) {
        let isBaseline = knownMACs.isEmpty
        let fresh = list.devices.filter { !knownMACs.contains($0.mac) }
        rememberSeen(list)
        guard !isBaseline else { return }
        for device in fresh {
            let content = UNMutableNotificationContent()
            content.title = "Perangkat baru tersambung"
            content.body = "\(displayName(device)) · \(device.ip) · \(device.isWireless ? "Wi-Fi" : "LAN") · \(device.mac)"
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "device-\(device.mac)", content: content, trigger: nil))
        }
    }

    // MARK: Restart

    func restartRouter() async {
        guard !isWorking else { return }
        beginActivity()
        deviceError = nil
        restartPhase = .sending
        if isDemo {
            for phase in [RestartPhase.goingDown, .comingBack, .done] {
                try? await Task.sleep(for: .milliseconds(900))
                restartPhase = phase
            }
            return
        }
        do {
            guard let client else { throw RouterError.loginRequired }
            acceptKeepingSelection(try await authenticatedRead(client))
            try await client.restart()
            // The session ended with the reboot; keep the last read visible.
            state = .released(state.snapshot)
            deviceList = nil
            restartPhase = .goingDown
            var wentDown = false
            for _ in 0..<30 where !wentDown {
                if await client.isReachable() { try await Task.sleep(for: .seconds(3)) } else { wentDown = true }
            }
            guard wentDown else { throw RouterError.restartUnverified }
            restartPhase = .comingBack
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(4))
                if await client.isReachable() {
                    restartPhase = .done
                    return
                }
            }
            restartPhase = .failed("Router belum terjangkau lagi setelah 4 menit. Periksa lampu dan kabel router.")
        } catch {
            if case .sending = restartPhase { failDevices(error) }
            restartPhase = .failed(error.localizedDescription)
        }
    }

    func dismissRestartStatus() {
        if !restartPhase.isActive { restartPhase = .idle }
    }

    /// Normal app termination tries to release the lease. Forced termination,
    /// power loss or a dead network can still leave server-side session state.
    func prepareToQuit() async {
        cancelIdleLogout()
        handingOffToBrowser = true
        _ = await releaseSession()
    }

    private func authenticatedRead(_ connection: F460Client) async throws -> RouterSnapshot {
        do { return try await connection.read() }
        catch RouterError.loginRequired {
            guard remembersPassword, !username.isEmpty,
                  let password = try await keychain.password(for: accountID(connection.address, username)) else {
                throw RouterError.loginRequired
            }
            return try await connection.login(username: username, password: password)
        }
    }

    private func beginActivity() {
        hasStarted = true
        handingOffToBrowser = false
        cancelIdleLogout()
    }

    private func cancelIdleLogout() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleLogout() async {
        guard !isDemo, let connection = client, await connection.hasSession else { return }
        // Recheck UI state after the actor hop: a browser handoff or a new
        // operation may have started while querying the session lease.
        guard client === connection, !handingOffToBrowser, !state.isBusy else { return }
        if case .released = state { return }
        armIdleLogout()
    }

    private func armIdleLogout() {
        cancelIdleLogout()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Clear the handle before cleanup so releaseSession does not cancel
            // the very task that is about to send the logout request.
            self.idleTask = nil
            _ = await self.releaseSession()
        }
    }

    private func accept(_ snapshot: RouterSnapshot) {
        selectedChannel = snapshot.channel
        state = .ready(snapshot)
    }

    /// Device operations re-read WLAN to authenticate; keep a pending
    /// channel choice when it is still offered by the router.
    private func acceptKeepingSelection(_ snapshot: RouterSnapshot) {
        if !snapshot.availableChannels.contains(selectedChannel) || state.snapshot == nil {
            selectedChannel = snapshot.channel
        }
        state = .ready(snapshot)
    }

    /// Session-level failures change the app state; anything else is
    /// reported on the device screen without discarding the last read.
    private func failDevices(_ error: any Error) {
        if let routerError = error as? RouterError,
           [.loginRequired, .loginFailed, .adminSessionInUse].contains(routerError) {
            fail(routerError, lastKnown: state.snapshot)
        } else if error is URLError {
            fail(error, lastKnown: state.snapshot)
        }
        deviceError = error.localizedDescription
    }

    nonisolated static func localIPv4Addresses() -> Set<String> {
        var result = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result
    }

    func fail(_ error: any Error, lastKnown: RouterSnapshot? = nil) {
        if let routerError = error as? RouterError, routerError == .adminSessionInUse {
            state = .adminBusy(routerError.localizedDescription)
            return
        }
        if let routerError = error as? RouterError, [.rejected, .invalidSession].contains(routerError) {
            state = .rejected(lastKnown, routerError.localizedDescription)
            return
        }
        if let routerError = error as? RouterError, [.loginRequired, .loginFailed].contains(routerError) {
            state = .needsLogin(routerError.localizedDescription)
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .timedOut, .networkConnectionLost:
                state = .failed("Router tidak terjangkau. Pastikan Mac terhubung ke jaringan router, lalu klik Perbarui.")
            default:
                state = .failed("Koneksi ke router gagal. Periksa alamat dan izin Jaringan Lokal untuk iwifyou.")
            }
        } else { state = .failed(error.localizedDescription) }
    }

    private func accountID(_ address: RouterAddress, _ name: String) -> String {
        address.storageID + "|" + name
    }
}
