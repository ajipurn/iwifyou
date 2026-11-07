import AppKit
import IWiFiYouCore
import SwiftUI

// MARK: - Devices

struct DevicesView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @ViewState<ConnectedDevice?> private var confirming: ConnectedDevice?
    @ViewState<ConnectedDevice?> private var renaming: ConnectedDevice?
    @ViewState<String> private var newName = ""

    var body: some View {
        Group {
            if let list = model.deviceList {
                content(list)
            } else {
                LoadPrompt(model: model, section: .devices,
                           detail: model.deviceError ?? "Baca klien DHCP, tabel ARP, dan filter MAC dari router.",
                           openSettings: openSettings) { await model.refreshDevices() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshDevices() } } label: {
                    Label("Muat Ulang Perangkat", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Baca ulang daftar perangkat dari router")
                .disabled(model.isWorking || model.state.snapshot == nil)
            }
        }
        // Only auto-load while a session is live; never log in just because
        // the screen was opened.
        .task { if model.deviceList == nil, case .ready = model.state { await model.refreshDevices() } }
        .confirmationDialog(
            confirming.map { "Blokir \(model.displayName($0))?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { device in
            Button("Blokir", role: .destructive) { Task { await model.setBlocked(device, true) } }
            Button("Batal", role: .cancel) {}
        } message: { device in
            Text(blockExplanation(device))
        }
        .alert("Ganti Nama Perangkat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nama", text: $newName)
            Button("Simpan") { if let renaming { model.rename(renaming.mac, to: newName) } }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Nama hanya disimpan di Mac ini, tidak dikirim ke router.")
        }
    }

    private func content(_ list: DeviceList) -> some View {
        let blocked = list.filter.blockedMACs
        let devices = list.devices.sorted { lhs, rhs in
            let left = (list.activeMACs.contains(lhs.mac) ? 0 : 1, lhs.isWireless ? 0 : 1, Self.ipOrder(lhs.ip))
            let right = (list.activeMACs.contains(rhs.mac) ? 0 : 1, rhs.isWireless ? 0 : 1, Self.ipOrder(rhs.ip))
            return left < right
        }
        let absentBlocked = list.filter.entries.compactMap { $0 }.filter { mac in !list.devices.contains { $0.mac == mac } }
        return Form {
            if StaleNotice.isVisible(model) || model.deviceError != nil || model.deviceMessage != nil || list.filter.mode == .whitelist {
                Section {
                    StaleNotice(model: model)
                    if list.filter.mode == .whitelist {
                        Label("Filter MAC router memakai mode whitelist. Blokir dari iwifyou dinonaktifkan.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Brand.warn)
                    }
                    if let error = model.deviceError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
                    } else if let message = model.deviceMessage {
                        Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Brand.good)
                    }
                }
            }
            Section {
                MetricsRow(metrics: [
                    .init(label: "Perangkat", value: "\(list.devices.count)"),
                    .init(label: "Lewat Wi-Fi", value: "\(list.devices.filter(\.isWireless).count)"),
                    .init(label: "Aktif", value: "\(list.devices.filter { list.activeMACs.contains($0.mac) }.count)"),
                    .init(label: "Diblokir", value: "\(blocked.count)", color: blocked.isEmpty ? nil : Brand.bad),
                ])
            }
            Section("Tersambung") {
                ForEach(devices) { device in
                    deviceRow(device, list: list, blocked: blocked.contains(device.mac))
                }
                if devices.isEmpty {
                    Text("Router tidak melaporkan klien DHCP.").foregroundStyle(.secondary)
                }
            }
            if !absentBlocked.isEmpty {
                Section("Diblokir, Sedang Tidak Tersambung") {
                    ForEach(absentBlocked, id: \.self) { mac in
                        LabeledContent {
                            if model.pendingMAC == mac { ProgressView().controlSize(.small) }
                            else {
                                Button("Buka Blokir") { Task { await model.setBlocked(mac: mac, false) } }
                                    .disabled(model.isWorking)
                            }
                        } label: {
                            Text(model.displayName(mac: mac))
                            Text(mac).monospacedDigit()
                        }
                    }
                }
            }
            Section {
                LabeledContent("Batasi kecepatan per perangkat") { Text("Tidak didukung").foregroundStyle(.secondary) }
            } footer: {
                Text("Firmware F460 hanya punya batas kecepatan per port atau SSID (QoS › Entrance speed limit), yang memperlambat semua perangkat sekaligus.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func deviceRow(_ device: ConnectedDevice, list: DeviceList, blocked: Bool) -> some View {
        let active = list.activeMACs.contains(device.mac)
        return HStack(spacing: 12) {
            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .foregroundStyle(active ? Brand.accent : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName(device)).lineLimit(1)
                    if model.isThisMac(device) {
                        Text("Mac ini").font(.app(.caption)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(.separator))
                    }
                }
                Text("\(device.ip) · \(Self.portLabel(device.port)) · \(device.mac)")
                    .font(.app(.callout)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if blocked {
                StatusLabel(text: "Diblokir", color: Brand.bad).foregroundStyle(.secondary)
            } else {
                StatusLabel(text: active ? "Aktif" : "Tidak terlihat", color: active ? Brand.good : Color.secondary.opacity(0.4))
                    .foregroundStyle(.secondary)
            }
            Group {
                if model.pendingMAC == device.mac {
                    ProgressView().controlSize(.small)
                } else if blocked {
                    Button("Buka Blokir") { Task { await model.setBlocked(device, false) } }
                        .disabled(model.isWorking)
                } else {
                    Button("Blokir") { confirming = device }
                        .disabled(model.isWorking || model.isThisMac(device) || !list.filter.canBlock)
                        .help(model.isThisMac(device) ? "Mac ini tidak bisa memblokir dirinya sendiri" : "Buang semua trafik perangkat ini di router")
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
            Menu {
                Button("Ganti Nama…") { newName = model.deviceNames[device.mac] ?? device.hostName ?? ""; renaming = device }
                Button("Salin Alamat MAC") { copy(device.mac) }
                Button("Salin Alamat IP") { copy(device.ip) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Opsi untuk \(model.displayName(device))")
        }
        .padding(.vertical, 2)
    }

    private func blockExplanation(_ device: ConnectedDevice) -> String {
        var text = "Router akan membuang semua trafik dari \(device.mac) lewat filter MAC (mode blacklist). Perangkat masih bisa tersambung ke Wi-Fi, tetapi tidak bisa memakai internet maupun jaringan lokal."
        if model.deviceList?.filter.enabled == false {
            text += " Filter MAC router akan diaktifkan."
        }
        text += " Perangkat dengan alamat MAC acak bisa lolos jika alamatnya berganti."
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func portLabel(_ port: String) -> String {
        let upper = port.uppercased()
        if upper.hasPrefix("SSID") { return "Wi-Fi " + port.dropFirst(4) }
        if upper.hasPrefix("LAN") { return "LAN " + port.dropFirst(3) }
        return port.isEmpty ? "—" : port
    }

    static func ipOrder(_ ip: String) -> Int {
        ip.split(separator: ".").compactMap { Int($0) }.reduce(0) { $0 * 256 + $1 }
    }
}

// MARK: - System

struct SystemView: View {
    @Bindable var model: AppModel
    let monitor: ConnectionMonitor
    let openSettings: () -> Void
    @ViewState<Bool> private var confirmRestart = false

    var body: some View {
        Form {
            if let message = model.message {
                Section { Label(message, systemImage: "info.circle").foregroundStyle(.secondary) }
            }
            Section("Router") {
                KeyValueRow(label: "Alamat", value: model.isDemo ? "demo" : model.displayAddress)
                KeyValueRow(label: "Akun admin", value: model.username.isEmpty ? "—" : model.username)
                LabeledContent("Status") { StatusLabel(text: model.statusText, color: model.statusColor) }
                KeyValueRow(label: "Password", value: model.remembersPassword ? "Tersimpan di Keychain" : "Tidak disimpan")
                LabeledContent("Alamat atau akun") {
                    Button("Ubah…") { openSettings() }.disabled(model.isWorking)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { monitor.enabled }, set: { value in Task { await monitor.setEnabled(value) } })) {
                    Text("Koneksi lemot")
                    Text("Ukur tiap 2 menit dari Mac dan sarankan channel yang lebih lega.")
                }
                .disabled(model.isDemo)
                if monitor.enabled {
                    LabeledContent("Terakhir diukur") {
                        HStack(spacing: 8) {
                            Text(monitor.lastCheck.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Belum").foregroundStyle(.secondary)
                            Button(monitor.isChecking ? "Mengukur…" : "Ukur Sekarang") { Task { await monitor.check() } }
                                .disabled(monitor.isChecking)
                        }
                    }
                    if let summary = monitor.lastSummary { Text(summary).foregroundStyle(.secondary) }
                    if let alert = monitor.lastAlert { KeyValueRow(label: "Notifikasi terakhir", value: alert) }
                }
                if let note = monitor.note { Text(note).foregroundStyle(Brand.warn) }
                Toggle(isOn: Binding(get: { model.watchesNewDevices }, set: { value in Task { await model.setWatchingNewDevices(value) } })) {
                    Text("Perangkat baru tersambung")
                    Text("Cek daftar perangkat tiap 10 menit.")
                }
                .disabled(model.isDemo)
                if model.watchesNewDevices {
                    KeyValueRow(label: "Perangkat dikenal", value: "\(model.knownMACs.count)")
                    LabeledContent("Terakhir dicek") {
                        HStack(spacing: 8) {
                            Text(model.lastWatchCheck.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Belum").foregroundStyle(.secondary)
                            Button("Cek Sekarang") { Task { await model.checkForNewDevices() } }.disabled(model.isWorking)
                            Button("Lupakan Daftar") { model.forgetKnownDevices() }
                        }
                    }
                }
                if let note = model.watchNote { Text(note).foregroundStyle(Brand.warn) }
            } header: {
                Text("Notifikasi")
            } footer: {
                Text("Notifikasi lemot muncul jika terdeteksi 2 kali berturut-turut, paling sering 30 menit sekali; channel tidak pernah diubah otomatis. Pengecekan perangkat dilewati jika ada sesi admin lain, dan sesi yang dibuka khusus untuk mengecek langsung dilepas.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Restart…", role: .destructive) { confirmRestart = true }
                        .disabled(model.isWorking || model.state.snapshot == nil)
                } label: {
                    Text("Restart router")
                    Text("Internet dan Wi-Fi semua perangkat terputus 2–3 menit.")
                }
                if model.restartPhase != .idle {
                    HStack(spacing: 8) {
                        if model.restartPhase.isActive { ProgressView().controlSize(.small) }
                        Text(restartStatus).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if !model.restartPhase.isActive {
                            Button("Tutup") { model.dismissRestartStatus() }.buttonStyle(.link)
                        }
                    }
                }
            } header: {
                Text("Perawatan")
            }
            Section {
                LabeledContent("Sesi admin iwifyou") {
                    Button("Lepas Sekarang") { Task { await model.releaseSession() } }
                        .disabled(model.isWorking || model.isDemo)
                }
                if !model.isDemo {
                    LabeledContent("Panel web router") {
                        Button("Buka di Browser") {
                            Task { if let url = await model.prepareAdminBrowser() { NSWorkspace.shared.open(url) } }
                        }
                        .disabled(model.isWorking)
                    }
                }
            } header: {
                Text("Sesi Admin")
            } footer: {
                Text("Router hanya menerima satu sesi admin. iwifyou melepas sesinya setelah 2 menit idle, dan memverifikasi logout sebelum membuka browser.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Restart router sekarang?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await model.restartRouter() } }
            Button("Batal", role: .cancel) {}
        } message: {
            Text("Semua perangkat terputus dari internet dan Wi-Fi selama sekitar 2–3 menit. Sesi admin iwifyou juga berakhir.")
        }
    }

    private var restartStatus: String {
        switch model.restartPhase {
        case .idle: ""
        case .sending: "Mengirim perintah restart…"
        case .goingDown: "Menunggu router mati…"
        case .comingBack: "Router sedang menyala lagi. Wi-Fi Mac akan tersambung ulang otomatis."
        case .done: model.isDemo ? "Demo: restart selesai. Router tidak diubah." : "Router sudah menyala lagi. Klik Perbarui untuk masuk kembali."
        case .failed(let reason): reason
        }
    }
}

extension AppModel {
    var statusColor: Color {
        switch state {
        case .ready: Brand.good
        case .loading, .applying, .releasing, .rejected, .adminBusy: Brand.warn
        default: Color.secondary
        }
    }

    var displayAddress: String {
        addressText.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var disconnectedTitle: String {
        if case .adminBusy = state { return "Sesi admin masih aktif" }
        if case .rejected = state { return "Permintaan ditolak" }
        return state.isBusy ? "Membaca pengaturan router…" : "Hubungkan routermu"
    }

    var connectionMessage: String {
        switch state {
        case .adminBusy(let reason), .rejected(_, let reason), .needsLogin(let reason), .failed(let reason): reason
        case .loading: "Pastikan Mac tersambung ke jaringan yang sama."
        default: "Masukkan alamat router dan akun admin untuk mulai."
        }
    }

    var applyTitle: String {
        if requiresLoginBeforeApply { return "Masuk untuk Mengganti Channel" }
        if case .rejected = state { return "Perbarui Sebelum Mencoba Lagi" }
        if state.snapshot?.channel == selectedChannel { return "Channel Sudah Dipakai" }
        return selectedChannel == .automatic ? "Gunakan Channel Otomatis" : "Terapkan Channel \(selectedChannel.label)"
    }
}
