import AppKit
import IWiFiYouCore
import SwiftUI

extension Int {
    var durationText: String {
        let days = self / 86_400, hours = self % 86_400 / 3600, minutes = self % 3600 / 60
        if days > 0 { return "\(days) hari \(hours) jam" }
        if hours > 0 { return "\(hours) jam \(minutes) menit" }
        return "\(Swift.max(minutes, 0)) menit"
    }
}

private func fiberLabel(_ health: Health) -> String {
    switch health {
    case .good: "Normal"
    case .warning: "Mendekati batas"
    case .bad: "Buruk"
    case .unknown: "—"
    }
}

// MARK: - Status

struct StatusView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Group {
            if let status = model.routerStatus {
                Form {
                    if StaleNotice.isVisible(model) || AreaNotice(model: model, area: .status).isVisible {
                        Section {
                            StaleNotice(model: model)
                            AreaNotice(model: model, area: .status)
                        }
                    }
                    Section {
                        summary(status)
                        MetricsRow(metrics: metrics(status))
                    }
                    Section("Internet") {
                        LabeledContent("Status") {
                            StatusLabel(text: status.wan.connected ? "Tersambung" : "Terputus", color: status.wan.connected ? Brand.good : Brand.bad)
                        }
                        KeyValueRow(label: "Lama online", value: status.wan.connected ? (status.wan.onlineSeconds?.durationText ?? "—") : "—")
                        KeyValueRow(label: "Mode", value: status.wan.mode)
                        KeyValueRow(label: "Koneksi", value: status.wan.name)
                        KeyValueRow(label: "IP WAN", value: status.wan.address ?? "—")
                        KeyValueRow(label: "Gateway ISP", value: status.wan.gateway ?? "—")
                        KeyValueRow(label: "DNS", value: status.wan.dns.isEmpty ? "—" : status.wan.dns.joined(separator: ", "))
                        if let reason = status.wan.disconnectReason { KeyValueRow(label: "Alasan putus", value: reason, tint: Brand.bad) }
                    }
                    Section {
                        if let fiber = status.optical.fiber {
                            LabeledContent("Redaman (RX)") {
                                StatusLabel(text: String(format: "%.1f dBm · %@", fiber.rx, fiberLabel(fiber.health)), color: fiber.health.color)
                            }
                            KeyValueRow(label: "Daya kirim (TX)", value: fiber.tx.map { String(format: "%.1f dBm", $0) } ?? "—")
                        } else {
                            LabeledContent("Redaman") { StatusLabel(text: "Sinyal hilang (LOS)", color: Brand.bad) }
                        }
                        KeyValueRow(label: "Registrasi ke ISP", value: status.optical.registration ?? "—")
                        KeyValueRow(label: "Suhu modul", value: status.optical.temperature.map { String(format: "%.0f °C", $0) } ?? "—")
                        KeyValueRow(label: "Tegangan", value: status.optical.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                        KeyValueRow(label: "Arus bias", value: status.optical.biasCurrent.map { String(format: "%.1f mA", $0) } ?? "—")
                    } header: {
                        Text("Fiber Optik")
                    } footer: {
                        Text("RX −8 s.d. −25 dBm normal; −25 s.d. −27 dBm mendekati batas; di bawah −27 dBm biasanya perlu dilaporkan ke ISP.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Wi-Fi") {
                        KeyValueRow(label: "Nama", value: model.state.snapshot?.ssid ?? "—")
                        LabeledContent("Radio") {
                            StatusLabel(text: status.wlan.enabled ? "Aktif" : "Mati", color: status.wlan.enabled ? Brand.good : Brand.bad)
                        }
                        KeyValueRow(label: "Channel aktif", value: status.wlan.channel.map(String.init) ?? "—")
                        KeyValueRow(label: "Setelan channel", value: model.state.snapshot?.channel == .automatic ? "Otomatis" : (model.state.snapshot?.channel.label ?? "—"))
                    }
                    Section {
                        KeyValueRow(label: "Model", value: "ZTE \(status.info.model)")
                        KeyValueRow(label: "Hardware", value: status.info.hardware)
                        KeyValueRow(label: "Software", value: status.info.software)
                        if let boot = status.info.bootLoader { KeyValueRow(label: "Boot loader", value: boot) }
                        KeyValueRow(label: "Alamat", value: model.displayAddress)
                    } header: {
                        Text("Router")
                    } footer: {
                        Text("Dibaca pukul \(status.date.formatted(date: .omitted, time: .shortened)).").foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                LoadPrompt(model: model, section: .status,
                           detail: model.areaErrors[.status] ?? "Status internet, redaman fiber, channel aktif, dan versi router.",
                           openSettings: openSettings) { await model.refreshStatus() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshStatus() } } label: { Label("Baca Ulang Status", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Baca ulang status dari router").disabled(model.isWorking || model.state.snapshot == nil)
            }
        }
        .task { if model.routerStatus == nil, model.hasLiveSession { await model.refreshStatus() } }
    }

    private func summary(_ status: RouterStatus) -> some View {
        let online = status.wan.connected
        let healthy = online && (status.optical.fiber?.health ?? .bad) != .bad
        let color = healthy ? Brand.good : (online ? Brand.warn : Brand.bad)
        return HStack(spacing: 14) {
            Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(online ? (healthy ? "Internet tersambung" : "Internet tersambung, fiber bermasalah") : "Internet terputus")
                    .font(.app(size: 16, weight: .semibold))
                Text(detail(status)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func detail(_ status: RouterStatus) -> String {
        var parts: [String] = []
        if let seconds = status.wan.onlineSeconds, status.wan.connected { parts.append("Online \(seconds.durationText)") }
        parts.append(status.wan.mode)
        if let reason = status.wan.disconnectReason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    private func metrics(_ status: RouterStatus) -> [MetricsRow.Metric] {
        var result: [MetricsRow.Metric] = []
        if let fiber = status.optical.fiber {
            result.append(.init(label: "Redaman", value: String(format: "%.1f", fiber.rx), unit: "dBm", color: fiber.health == .good ? nil : fiber.health.color))
        } else {
            result.append(.init(label: "Redaman", value: "LOS", color: Brand.bad))
        }
        result.append(.init(label: "Channel aktif", value: status.wlan.channel.map(String.init) ?? "—"))
        result.append(.init(label: "Perangkat", value: model.deviceList.map { String($0.devices.count) } ?? "—"))
        result.append(.init(label: "Online", value: status.wan.connected ? (status.wan.onlineSeconds.map { $0 >= 86_400 ? "\($0 / 86_400)" : "\($0 / 3600)" } ?? "—") : "—",
                            unit: status.wan.connected ? ((status.wan.onlineSeconds ?? 0) >= 86_400 ? "hari" : "jam") : nil))
        return result
    }
}

// MARK: - Wi-Fi name and password

struct WiFiCredentialsSheet: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @ViewState<String> private var ssid = ""
    @ViewState<String> private var password = ""
    @ViewState<String> private var confirmation = ""
    @ViewState<Bool> private var reveal = false
    @ViewState<Bool> private var confirming = false

    private var current: String { model.state.snapshot?.ssid ?? "" }
    private var newName: String? { ssid == current ? nil : ssid }
    private var newPassword: String? { password.isEmpty ? nil : password }
    private var nameProblem: String? { newName != nil && !WiFiCredentials.validSSID(ssid) ? "1–32 karakter ASCII, tanpa spasi di awal atau akhir." : nil }
    private var passwordProblem: String? {
        guard let newPassword else { return nil }
        if !WiFiCredentials.validPassphrase(newPassword) { return "8–63 karakter ASCII (huruf, angka, tanda baca)." }
        if confirmation != password { return "Konfirmasi belum sama." }
        return nil
    }
    private var canSave: Bool { (newName != nil || newPassword != nil) && nameProblem == nil && passwordProblem == nil && !model.isWorking }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Nama Wi-Fi", text: $ssid)
                    if let nameProblem { Text(nameProblem).foregroundStyle(Brand.bad) }
                } header: {
                    Text("Ubah Nama & Password Wi-Fi").font(.app(.headline))
                }
                Section {
                    if reveal {
                        TextField("Password baru", text: $password)
                        TextField("Ulangi password", text: $confirmation)
                    } else {
                        SecureField("Password baru", text: $password)
                        SecureField("Ulangi password", text: $confirmation)
                    }
                    Toggle("Tampilkan password", isOn: $reveal)
                    if let passwordProblem { Text(passwordProblem).foregroundStyle(Brand.bad) }
                } footer: {
                    Text("Kosongkan jika password tidak diubah. Semua perangkat akan terputus dan harus tersambung ulang, termasuk Mac ini jika memakai Wi-Fi.")
                        .foregroundStyle(.secondary)
                }
                if AreaNotice(model: model, area: .wifi).isVisible {
                    Section { AreaNotice(model: model, area: .wifi) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Divider()
            HStack {
                Spacer()
                Button("Batal") { close() }.keyboardShortcut(.cancelAction)
                Button("Simpan…") { confirming = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 460, height: 400)
        .onAppear { ssid = current }
        .onDisappear { password = ""; confirmation = "" }
        .confirmationDialog("Ubah Wi-Fi sekarang?", isPresented: $confirming) {
            Button("Ubah dan Putuskan Semua Perangkat", role: .destructive) {
                Task {
                    let saved = await model.changeWiFi(ssid: newName, passphrase: newPassword)
                    password = ""
                    confirmation = ""
                    if saved { close() }
                }
            }
            Button("Batal", role: .cancel) {}
        } message: {
            Text([newName.map { "Nama baru: \($0)." }, newPassword == nil ? nil : "Password diganti."].compactMap { $0 }.joined(separator: " "))
        }
    }
}

// MARK: - Network: DHCP reservations and port forwarding

struct NetworkView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @ViewState<String> private var reserveMAC = ""
    @ViewState<String> private var reserveIP = ""
    @ViewState<String> private var ruleName = ""
    @ViewState<PortProtocol> private var ruleProtocol = PortProtocol.tcp
    @ViewState<String> private var externalPort = ""
    @ViewState<String> private var externalEnd = ""
    @ViewState<String> private var ruleHost = ""
    @ViewState<String> private var internalPort = ""

    private var knownDevices: [ConnectedDevice] { model.deviceList?.devices ?? [] }

    var body: some View {
        Group {
            if let reservations = model.reservations, let forwards = model.portForwards {
                Form {
                    if StaleNotice.isVisible(model) || AreaNotice(model: model, area: .network).isVisible {
                        Section {
                            StaleNotice(model: model)
                            AreaNotice(model: model, area: .network)
                        }
                    }
                    reservationSection(reservations)
                    forwardSection(forwards)
                }
                .formStyle(.grouped)
            } else {
                LoadPrompt(model: model, section: .network,
                           detail: model.areaErrors[.network] ?? "Atur alamat IP tetap untuk perangkat dan buka port untuk CCTV, game, atau server.",
                           openSettings: openSettings) { await model.refreshNetwork() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshNetwork() } } label: { Label("Baca Ulang", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.isWorking || model.state.snapshot == nil)
            }
        }
        .task { if model.reservations == nil, model.hasLiveSession { await model.refreshNetwork() } }
    }

    private func reservationSection(_ reservations: DHCPReservations) -> some View {
        Section {
            ForEach(reservations.reservations) { entry in
                let known = model.knownName(mac: entry.mac)
                LabeledContent {
                    Button("Hapus", role: .destructive) { Task { await model.removeReservation(mac: entry.mac) } }
                        .disabled(model.isWorking)
                } label: {
                    Text(known ?? entry.ip)
                    Text(known == nil ? entry.mac : "\(entry.ip) · \(entry.mac)").monospacedDigit()
                }
            }
            if knownDevices.isEmpty {
                TextField("Alamat MAC", text: $reserveMAC, prompt: Text("aa:bb:cc:dd:ee:ff"))
            } else {
                Picker("Perangkat", selection: $reserveMAC) {
                    Text("Pilih…").tag("")
                    ForEach(knownDevices) { device in
                        Text("\(model.displayName(device)) · \(device.ip)").tag(device.mac)
                    }
                }
                .onChange(of: reserveMAC) { _, mac in
                    if let device = knownDevices.first(where: { $0.mac == mac }) { reserveIP = device.ip }
                }
            }
            TextField("IP tetap", text: $reserveIP, prompt: Text(reservations.poolStart))
            HStack {
                Spacer()
                Button("Tambah IP Tetap") {
                    let mac = reserveMAC, ip = reserveIP
                    Task {
                        await model.addReservation(ip: ip, mac: mac)
                        if model.areaErrors[.network] == nil { reserveMAC = ""; reserveIP = "" }
                    }
                }
                .disabled(model.isWorking || MACAddress.normalize(reserveMAC) == nil || !reservations.contains(ip: reserveIP))
            }
        } header: {
            Text("IP Tetap")
        } footer: {
            Text("Perangkat selalu mendapat alamat yang sama. Rentang DHCP router: \(reservations.poolStart) – \(reservations.poolEnd)." + (knownDevices.isEmpty ? " Muat bagian Perangkat untuk memilih dari daftar." : ""))
                .foregroundStyle(.secondary)
        }
    }

    private func forwardSection(_ forwards: PortForwards) -> some View {
        Section {
            if let address = model.routerStatus?.wan.address, Self.isPrivateWAN(address) {
                Label("IP WAN router (\(address)) bukan IP publik. Port yang dibuka di sini kemungkinan besar tetap tidak bisa diakses dari internet tanpa IP publik dari ISP.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.warn).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(forwards.rules) { rule in
                LabeledContent {
                    Button("Hapus", role: .destructive) { Task { await model.removePortForward(name: rule.name) } }
                        .disabled(model.isWorking)
                } label: {
                    Text(rule.name)
                    Text("\(rule.proto.label) \(rule.externalStart == rule.externalEnd ? "\(rule.externalStart)" : "\(rule.externalStart)–\(rule.externalEnd)") → \(rule.internalHost):\(rule.internalPort)\(rule.enabled ? "" : " · nonaktif")")
                        .monospacedDigit()
                }
            }
            TextField("Nama aturan baru", text: $ruleName, prompt: Text("contoh: CCTV"))
            Picker("Protokol", selection: $ruleProtocol) { ForEach(PortProtocol.allCases) { Text($0.label).tag($0) } }
            LabeledContent("Port luar") {
                HStack(spacing: 6) {
                    TextField("Port awal", text: $externalPort, prompt: Text("8080")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("sampai").foregroundStyle(.secondary)
                    TextField("Port akhir", text: $externalEnd, prompt: Text("opsional")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
            }
            LabeledContent("Perangkat tujuan") {
                HStack(spacing: 6) {
                    if !knownDevices.isEmpty {
                        Menu("Pilih") {
                            ForEach(knownDevices) { device in Button("\(model.displayName(device)) · \(device.ip)") { ruleHost = device.ip } }
                        }
                        .fixedSize()
                    }
                    TextField("IP perangkat", text: $ruleHost, prompt: Text("192.168.1.20")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 130)
                }
            }
            TextField("Port tujuan", text: $internalPort, prompt: Text("80"))
            HStack {
                Spacer()
                Button("Tambah Aturan") {
                    guard let connection = forwards.connections.first(where: { $0.name.uppercased().contains("INTERNET") }) ?? forwards.connections.first,
                          let start = Int(externalPort), let port = Int(internalPort) else { return }
                    let rule = PortForward(name: ruleName, proto: ruleProtocol, externalStart: start,
                                           externalEnd: Int(externalEnd) ?? start, internalHost: ruleHost, internalPort: port)
                    Task {
                        await model.addPortForward(rule, connection: connection)
                        if model.areaErrors[.network] == nil { ruleName = ""; externalPort = ""; externalEnd = ""; ruleHost = ""; internalPort = "" }
                    }
                }
                .disabled(model.isWorking || ruleName.isEmpty || Int(externalPort) == nil || Int(internalPort) == nil
                          || IPv4.normalize(ruleHost) == nil || (!externalEnd.isEmpty && Int(externalEnd) == nil) || forwards.connections.isEmpty)
            }
        } header: {
            Text("Port Forwarding")
        } footer: {
            Text("Membuka port membuat perangkat itu bisa dijangkau dari luar rumah. Hanya buka yang benar-benar perlu.").foregroundStyle(.secondary)
        }
    }

    static func isPrivateWAN(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
}

// MARK: - Website blocking

struct SecurityView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @ViewState<String> private var domain = ""
    @ViewState<String> private var site = ""
    @ViewState<[String: SiteProbe.Result]> private var probes = [:]
    @ViewState<[String: SiteProbe.DNSAnswer]> private var dnsProbes = [:]
    @ViewState<String?> private var probing: String?

    var body: some View {
        Group {
            if let filter = model.siteFilter, let list = model.dnsBlocklist {
                Form {
                    if StaleNotice.isVisible(model) || AreaNotice(model: model, area: .sites).isVisible {
                        Section {
                            StaleNotice(model: model)
                            AreaNotice(model: model, area: .sites)
                        }
                    }
                    dnsSection(list)
                    urlSection(filter)
                }
                .formStyle(.grouped)
            } else {
                LoadPrompt(model: model, section: .security,
                           detail: model.areaErrors[.sites] ?? "Blokir situs untuk semua perangkat di jaringan rumah lewat DNS router.",
                           openSettings: openSettings) { await model.refreshSites() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshSites() } } label: { Label("Baca Ulang", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.isWorking || model.state.snapshot == nil)
            }
        }
        .task { if model.siteFilter == nil, model.hasLiveSession { await model.refreshSites() } }
    }

    // MARK: DNS blocking

    private func dnsSection(_ list: DNSBlocklist) -> some View {
        let foreign = list.hosts.filter { !$0.isBlock }
        let presets = model.visiblePresets(list)
        let sites = model.customSiteList(list)
        return Section {
            ForEach(presets) { preset in
                siteRow(title: preset.title, names: Set(preset.hosts), list: list, probeName: preset.hosts[1],
                        block: { await model.blockNames(preset.hosts, label: preset.title) },
                        remove: { await model.removePreset(preset) })
            }
            ForEach(sites, id: \.self) { site in
                let names = model.namesForSite(site, in: list)
                siteRow(title: site, names: names, list: list, probeName: site,
                        block: { await model.blockNames(Array(names).sorted(), label: site) },
                        remove: { await model.removeSite(site) })
            }
            if presets.isEmpty && sites.isEmpty {
                Text("Belum ada situs di daftar.").foregroundStyle(.secondary)
            }
            LabeledContent("Tambah situs") {
              HStack(spacing: 8) {
                TextField("Tambah situs", text: $domain, prompt: Text("instagram.com")).labelsHidden()
                    .textFieldStyle(.roundedBorder).frame(minWidth: 180).onSubmit(addDomain)
                if !model.removedPresets.isEmpty {
                    Menu("Tambah Cepat") {
                        ForEach(model.removedPresets) { preset in
                            Button("Blokir \(preset.title)") { Task { await model.addPreset(preset) } }
                        }
                    }
                    .fixedSize()
                    .disabled(model.isWorking)
                }
                Button("Blokir", action: addDomain)
                    .disabled(model.isWorking || DNSBlocklist.names(forDomain: domain).isEmpty)
              }
            }
            if !foreign.isEmpty {
                Text("Entri Hosts lain di router (tidak diubah): " + foreign.map { "\($0.name) → \($0.address)" }.joined(separator: ", "))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Blokir lewat DNS Router")
                Spacer()
                Text("\(list.entries.count) dari \(DNSBlocklist.capacity) entri").font(.app(.caption)).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Router menjawab 0.0.0.0 untuk situs yang diblokir, jadi situs HTTPS ikut tertutup. Berlaku untuk perangkat yang memakai DNS bawaan router; efeknya bisa tertunda beberapa menit karena cache DNS. App YouTube/TikTok kadang tetap memuat sebagian konten, dan perangkat dengan VPN atau Private DNS tidak terpengaruh.")
                .foregroundStyle(.secondary)
        }
    }

    private func siteRow(title: String, names: Set<String>, list: DNSBlocklist, probeName: String,
                         block: @escaping () async -> Void, remove: @escaping () async -> Void) -> some View {
        let blocked = names.intersection(list.blockedNames)
        return LabeledContent {
            HStack(spacing: 8) {
                probeButton(probeName)
                if blocked.isEmpty {
                    Button("Blokir") { Task { await block() } }.disabled(model.isWorking)
                } else {
                    if blocked.count < names.count {
                        Button("Lengkapi") { Task { await block() } }.disabled(model.isWorking)
                    }
                    Button("Buka Blokir") { Task { await model.unblockNames(blocked, label: title) } }.disabled(model.isWorking)
                }
                Button(role: .destructive) { Task { await remove() } } label: {
                    Image(systemName: "trash")
                }
                .help("Buka blokir dan hapus \(title) dari daftar")
                .disabled(model.isWorking)
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(blocked.isEmpty ? Color.secondary.opacity(0.4) : Brand.bad).frame(width: 8, height: 8)
                Text(title)
            }
            Text(probeText(probeName) ?? (blocked.isEmpty ? "Tidak diblokir" : blocked.count == names.count ? "Diblokir · \(blocked.count) nama" : "Sebagian diblokir · \(blocked.count) dari \(names.count) nama"))
        }
    }

    private func addDomain() {
        let input = domain
        Task {
            await model.addSite(input)
            if model.areaErrors[.sites] == nil { domain = "" }
        }
    }

    private func probeText(_ name: String) -> String? {
        switch dnsProbes[name] {
        case .blocked: "Uji: DNS router menjawab 0.0.0.0 (diblokir)"
        case .open: "Uji: DNS router masih menjawab alamat asli"
        case .unknown: "Uji: DNS router tidak menjawab"
        case nil: nil
        }
    }

    @ViewBuilder
    private func probeButton(_ name: String) -> some View {
        if probing == name {
            ProgressView().controlSize(.small)
        } else {
            Button("Uji") {
                probing = name
                Task {
                    dnsProbes[name] = await SiteProbe.routerDNS(name, router: model.routerHost)
                    probing = nil
                }
            }
            .disabled(probing != nil)
            .help("Tanya DNS router langsung, tanpa cache Mac")
        }
    }

    // MARK: URL filter (HTTP only)

    private func urlSection(_ filter: SiteFilter) -> some View {
        Section {
            if !filter.canBlock {
                Label("Filter URL router memakai mode whitelist. iwifyou tidak mengubahnya.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Brand.warn)
            }
            ForEach(filter.sites, id: \.self) { entry in
                LabeledContent {
                    HStack(spacing: 8) {
                        if probing == entry {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Uji") {
                                probing = entry
                                Task {
                                    probes[entry] = await SiteProbe.check(entry)
                                    probing = nil
                                }
                            }
                            .disabled(probing != nil)
                        }
                        Button(role: .destructive) { Task { await model.unblockSite(entry) } } label: { Image(systemName: "trash") }
                            .disabled(model.isWorking || !filter.canBlock)
                    }
                } label: {
                    Text(entry)
                    if let result = probes[entry] {
                        Text("HTTP: \(result.http ? "masih terbuka" : "diblokir") · HTTPS: \(result.https ? "masih terbuka" : "diblokir")")
                    }
                }
            }
            LabeledContent("Tambah alamat HTTP") {
                HStack(spacing: 8) {
                    TextField("Alamat HTTP", text: $site, prompt: Text("situs-lama.example")).labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(minWidth: 180).onSubmit(addSite)
                    Button("Tambah", action: addSite)
                        .disabled(model.isWorking || SiteFilter.normalize(site) == nil || !filter.canBlock)
                }
            }
        } header: {
            HStack {
                Text("Filter URL Router")
                Spacer()
                Text(filter.enabled ? (filter.mode == .blacklist ? "Aktif" : "Whitelist") : "Mati").font(.app(.caption)).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Filter URL bawaan F460 hanya memeriksa koneksi HTTP tanpa enkripsi; situs HTTPS seperti YouTube dan TikTok tetap terbuka. Pakai blokir lewat DNS router di atas.")
                .foregroundStyle(.secondary)
        }
    }

    private func addSite() {
        let value = site
        Task {
            await model.blockSite(value)
            if model.areaErrors[.sites] == nil { site = "" }
        }
    }
}
