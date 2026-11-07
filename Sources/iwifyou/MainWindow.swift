import AppKit
import IWiFiYouCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case status, devices, wlan, channel, diagnosis, network, security, system

    var id: Self { self }

    var title: String {
        switch self {
        case .status: "Status"
        case .devices: "Perangkat"
        case .wlan: "Wi-Fi"
        case .channel: "Channel"
        case .diagnosis: "Diagnosa"
        case .network: "Jaringan"
        case .security: "Blokir Situs"
        case .system: "Sistem"
        }
    }

    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .devices: "laptopcomputer.and.iphone"
        case .wlan: "wifi"
        case .channel: "dot.radiowaves.left.and.right"
        case .diagnosis: "stethoscope"
        case .network: "point.3.connected.trianglepath.dotted"
        case .security: "hand.raised"
        case .system: "gearshape"
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    let scan: ChannelScanModel
    let location: LocationAccess
    let diagnosis: DiagnosisModel
    let meter: SignalMeter
    let monitor: ConnectionMonitor
    let openSettings: () -> Void
    @AppStorage("mainSection") private var storedSection = MainSection.status

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { storedSection }, set: { if let value = $0 { storedSection = value } })) {
                Section("Ringkasan") { row(.status); row(.diagnosis) }
                Section("Jaringan Rumah") { row(.devices); row(.wlan); row(.channel); row(.network) }
                Section("Kontrol") { row(.security); row(.system) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { routerFooter }
        } detail: {
            Group {
                switch storedSection {
                case .status: StatusView(model: model, openSettings: openSettings)
                case .devices: DevicesView(model: model, openSettings: openSettings)
                case .wlan: WLANInfoView(model: model, openSettings: openSettings)
                case .channel: ChannelView(model: model, scan: scan, location: location, openSettings: openSettings)
                case .diagnosis: DiagnosisView(model: model, diagnosis: diagnosis, meter: meter)
                case .network: NetworkView(model: model, openSettings: openSettings)
                case .security: SecurityView(model: model, openSettings: openSettings)
                case .system: SystemView(model: model, monitor: monitor, openSettings: openSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(storedSection.title)
            .navigationSubtitle(model.isDemo ? "Mode demo" : "\(model.displayAddress) · \(model.activeTask ?? model.statusText)")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.state.isBusy || model.activeTask != nil { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Label("Perbarui", systemImage: "arrow.clockwise")
                }
                .help("Baca ulang pengaturan router")
                .disabled(model.isWorking)
                Button { openSettings() } label: {
                    Label("Akun Router", systemImage: "person.crop.circle")
                }
                .help("Alamat dan akun admin router")
                .disabled(model.isWorking)
            }
        }
        .font(.app(.body))
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { model.noteInteraction() }
        .task { await model.startIfNeeded() }
    }

    private func row(_ item: MainSection) -> some View {
        Label(item.title, systemImage: item.icon).tag(item)
    }

    private var routerFooter: some View {
        HStack(spacing: 10) {
            LogoMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isDemo ? "ZTE F460 · demo" : "ZTE F460").font(.app(size: 12, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(model.statusColor).frame(width: 6, height: 6)
                    Text(model.activeTask ?? model.statusText).font(.app(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Shared pieces

struct DisconnectedView: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(model.disconnectedTitle)
            } icon: {
                LogoMark(size: 56)
            }
        } description: {
            Text(model.connectionMessage)
        } actions: {
            if model.state.isBusy {
                ProgressView().controlSize(.small)
            } else {
                switch model.state {
                case .rejected, .adminBusy, .failed:
                    Button("Perbarui Status") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                default:
                    Button("Hubungkan Router…") { openSettings() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct StaleNotice: View {
    let model: AppModel

    var body: some View {
        switch model.state {
        case .released:
            Label("Sesi admin sudah dilepas. Data di bawah adalah pembacaan terakhir.", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
        case .rejected(_, let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.warn)
        default:
            EmptyView()
        }
    }

    static func isVisible(_ model: AppModel) -> Bool {
        switch model.state {
        case .released, .rejected: true
        default: false
        }
    }
}

// MARK: - Wi-Fi

struct WLANInfoView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    @ViewState<Bool> private var editing = false

    var body: some View {
        if let snapshot = model.state.snapshot {
            Form {
                if StaleNotice.isVisible(model) || AreaNotice(model: model, area: .wifi).isVisible {
                    Section {
                        StaleNotice(model: model)
                        AreaNotice(model: model, area: .wifi)
                    }
                }
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: snapshot.radioEnabled ? "wifi" : "wifi.slash")
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(Brand.accent)
                            .frame(width: 40, height: 40)
                            .background(Brand.accent.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.ssid).font(.app(size: 16, weight: .semibold)).textSelection(.enabled)
                            Text("2,4 GHz · \(snapshot.bandwidth) · \(snapshot.details.standard)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusLabel(text: snapshot.radioEnabled ? "Aktif" : "Mati", color: snapshot.radioEnabled ? Brand.good : Brand.bad)
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Nama dan password") {
                        Button("Ubah…") { editing = true }
                            .disabled(model.isWorking || !snapshot.radioEnabled)
                    }
                }
                Section {
                    KeyValueRow(label: "Keamanan", value: snapshot.details.security)
                    KeyValueRow(label: "Enkripsi", value: snapshot.details.encryption ?? "—")
                    KeyValueRow(label: "SSID disembunyikan", value: snapshot.details.hiddenSSID ? "Ya" : "Tidak")
                    KeyValueRow(label: "Filter MAC", value: snapshot.details.macFilter)
                } header: {
                    Text("Keamanan")
                } footer: {
                    Text("Password Wi-Fi tidak ditampilkan dan tidak disimpan oleh iwifyou.").foregroundStyle(.secondary)
                }
                Section("Radio") {
                    KeyValueRow(label: "Standar", value: snapshot.details.standard)
                    KeyValueRow(label: "Lebar channel", value: snapshot.bandwidth)
                    if let sideBand = snapshot.details.sideBand {
                        KeyValueRow(label: "Channel tambahan (40 MHz)", value: sideBand)
                    }
                    KeyValueRow(label: "Setelan channel", value: snapshot.channel == .automatic ? "Otomatis" : snapshot.channel.label)
                    KeyValueRow(label: "Channel aktif", value: model.routerStatus?.wlan.channel.map(String.init) ?? "Buka Status untuk membaca")
                    KeyValueRow(label: "Daya pancar", value: snapshot.details.transmitPower)
                    KeyValueRow(label: "Kode wilayah", value: snapshot.details.region)
                }
                Section("Klien") {
                    KeyValueRow(label: "Maksimal perangkat", value: snapshot.details.maxClients.map(String.init) ?? "—")
                    KeyValueRow(label: "Isolasi antar perangkat", value: snapshot.details.clientIsolation ? "Aktif" : "Nonaktif")
                    KeyValueRow(label: "WMM (QoS)", value: snapshot.details.wmm ? "Aktif" : "Nonaktif")
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $editing) { WiFiCredentialsSheet(model: model) { editing = false } }
        } else {
            DisconnectedView(model: model, openSettings: openSettings)
        }
    }
}

// MARK: - Channel

struct ChannelView: View {
    @Bindable var model: AppModel
    let scan: ChannelScanModel
    let location: LocationAccess
    let openSettings: () -> Void

    private var snapshot: RouterSnapshot? { model.state.snapshot }

    private var channels: [Int] {
        let fixed = snapshot?.availableChannels.compactMap { channel -> Int? in
            if case .fixed(let number) = channel { return number }
            return nil
        } ?? []
        return fixed.isEmpty ? Array(1...13) : fixed
    }

    private var samples: [[ChannelQuality]] { scan.samples(channels: channels, ownSSID: snapshot?.ssid) }

    /// The chart shows the average of recent scans, not one noisy snapshot.
    private var qualities: [ChannelQuality] {
        let samples = samples
        return samples.isEmpty ? ChannelSurvey.qualities(for: channels, networks: [], ownSSID: nil) : ChannelSurvey.averaged(samples)
    }

    private var currentChannel: Int? {
        if case .fixed(let number) = snapshot?.channel { return number }
        return model.routerStatus?.wlan.channel ?? scan.phase.result?.connectedChannel
    }

    /// Only a channel that is consistently and clearly quieter than the
    /// current one is suggested.
    private var recommended: Int? { ChannelAdvice.stableSuggestion(samples, current: currentChannel) }

    private var highlightedChannel: Int? {
        if case .fixed(let number) = model.selectedChannel { return number }
        return nil
    }

    var body: some View {
        Form {
            if StaleNotice.isVisible(model) { Section { StaleNotice(model: model) } }
            if let suggestion = model.channelSuggestion { suggestionSection(suggestion) }
            Section {
                KeyValueRow(label: "Wi-Fi", value: snapshot?.ssid ?? "Belum terhubung")
                KeyValueRow(label: "Setelan router", value: routerChannelText)
                KeyValueRow(label: "Mac tersambung di", value: scan.phase.result?.connectedChannel.map { "Channel \($0)" } ?? "—")
                LabeledContent("Pindaian") {
                    HStack(spacing: 10) {
                        Text(scanText).foregroundStyle(.secondary)
                        if scan.isScanning { ProgressView().controlSize(.small) }
                        Button("Pindai Ulang") { Task { await scan.scan() } }.disabled(scan.isScanning)
                    }
                }
            }
            Section {
                QualityChart(qualities: qualities, recommended: recommended, highlighted: highlightedChannel)
                    .padding(.vertical, 6)
            } header: {
                Text("Kualitas Tiap Channel")
            } footer: {
                Text(averageText).foregroundStyle(.secondary)
            }
            pickerSection
            NearbyNetworksSection(result: scan.phase.result, ownSSID: snapshot?.ssid, location: location) {
                Task { await scan.scan() }
            }
        }
        .formStyle(.grouped)
        .task { if case .idle = scan.phase { await scan.scan() } }
        .onChange(of: location.isGranted) { _, granted in
            if granted { Task { await scan.scan() } }
        }
    }

    private var routerChannelText: String {
        guard let snapshot else { return "—" }
        if snapshot.channel == .automatic {
            return model.routerStatus?.wlan.channel.map { "Otomatis (kini channel \($0))" } ?? "Otomatis"
        }
        return "Channel \(snapshot.channel.label)"
    }

    private var scanText: String {
        if let step = scan.burstProgress { return "Memindai \(step) dari \(scan.burstSize)…" }
        switch scan.phase {
        case .idle: return "Belum dipindai"
        case .scanning: return "Memindai…"
        case .failed(let reason, _): return reason
        case .done(let result): return "\(scan.history.count) pindaian · terakhir \(result.date.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var averageText: String {
        guard let first = scan.history.first, let last = scan.history.last else {
            return "Kepadatan berubah dari waktu ke waktu, jadi saran dihitung dari rata-rata beberapa pindaian."
        }
        let minutes = max(1, Int(last.date.timeIntervalSince(first.date) / 60 + 0.5))
        return "Rata-rata \(scan.history.count) pindaian dalam \(minutes) menit terakhir. Satu pindaian bisa meleset 5–10 dB, jadi saran hanya muncul jika sebuah channel konsisten jauh lebih lega daripada channel yang dipakai."
    }

    private func suggestionSection(_ suggestion: AppModel.ChannelSuggestion) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "tortoise.fill").font(.title2).foregroundStyle(Brand.warn)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Disarankan pindah ke channel \(suggestion.channel)").font(.app(.headline))
                    Text(suggestion.reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Terdeteksi pukul \(suggestion.date.formatted(date: .omitted, time: .shortened)).").font(.app(.caption)).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Pilih Channel \(suggestion.channel)") { model.openSuggestion(suggestion.channel) }
                        .disabled(!model.canSelectChannel)
                    Button("Abaikan") { model.dismissSuggestion() }.buttonStyle(.link)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var pickerSection: some View {
        let byChannel = Dictionary(uniqueKeysWithValues: qualities.map { ($0.channel, $0) })
        return Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 8)], spacing: 8) {
                ChannelTile(
                    title: "Auto", detail: "Router", level: nil,
                    isSelected: model.selectedChannel == .automatic,
                    isCurrent: snapshot?.channel == .automatic, isRecommended: false
                ) { model.selectChannel(.automatic) }
                ForEach(channels, id: \.self) { number in
                    let quality = scan.phase.result == nil ? nil : byChannel[number]
                    ChannelTile(
                        title: String(number),
                        detail: quality.map { $0.neighbours == 0 ? "Sepi" : "\($0.neighbours) jaringan" } ?? " ",
                        level: quality?.level,
                        isSelected: model.selectedChannel == .fixed(number),
                        isCurrent: snapshot?.channel == .fixed(number) || (snapshot?.channel == .automatic && model.routerStatus?.wlan.channel == number),
                        isRecommended: number == recommended
                    ) { model.selectChannel(.fixed(number)) }
                }
            }
            .padding(.vertical, 4)
            .disabled(!model.canSelectChannel)

            if snapshot == nil {
                LabeledContent("Router belum terhubung") {
                    Button("Hubungkan Router…") { openSettings() }
                }
            } else {
                if snapshot?.radioEnabled == false {
                    Label("Radio Wi-Fi nonaktif.", systemImage: "wifi.slash").foregroundStyle(.secondary)
                }
                if let number = [highlightedChannel, recommended].compactMap({ $0 }).first(where: { $0 >= 12 }) {
                    Label("Channel \(number): sebagian perangkat buatan pasar Amerika hanya mengenal channel 1–11 dan tidak akan menemukan Wi-Fi ini.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let message = model.message {
                        Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Wi-Fi bisa terputus sebentar saat channel berubah.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.state.isBusy ? model.statusText : model.applyTitle) {
                        if model.requiresLoginBeforeApply { openSettings() }
                        else { Task { await model.applySelectedChannel() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApply)
                }
            }
        } header: {
            HStack {
                Text("Pilih Channel")
                Spacer()
                if let recommended, model.canSelectChannel, snapshot?.channel != .fixed(recommended) {
                    Button("Pakai saran: channel \(recommended)") { model.selectChannel(.fixed(recommended)) }
                        .buttonStyle(.link).font(.app(.callout))
                } else if scan.history.count >= 3 {
                    Text("Channel sekarang sudah cukup lega").font(.app(.callout)).foregroundStyle(.secondary)
                } else if !scan.isScanning {
                    Text("Saran muncul setelah 3 pindaian").font(.app(.callout)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ChannelTile: View {
    let title: String
    let detail: String
    let level: ChannelQuality.Level?
    let isSelected: Bool
    let isCurrent: Bool
    let isRecommended: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    Text(title).font(.app(size: 15, weight: isSelected ? .bold : .semibold)).monospacedDigit()
                    if isRecommended {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Brand.warn)
                            .accessibilityLabel("Disarankan")
                    }
                }
                HStack(spacing: 4) {
                    if let level { Circle().fill(level.color).frame(width: 6, height: 6) }
                    Text(detail).font(.app(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(isCurrent ? "Aktif" : " ").font(.app(size: 10, weight: .semibold)).foregroundStyle(Brand.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .background(isSelected ? Brand.accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Brand.accent : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct NearbyNetworksSection: View {
    let result: WiFiScanResult?
    let ownSSID: String?
    let location: LocationAccess
    let rescan: () -> Void

    var body: some View {
        Section {
            if let result, !result.namesAvailable {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "location.slash").foregroundStyle(.secondary)
                    Text("macOS menyembunyikan nama jaringan sampai iwifyou diberi akses Lokasi. Tanpa nama, Wi-Fi kamu sendiri ikut dihitung sebagai gangguan.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if location.canAsk {
                        Button("Izinkan Lokasi") { location.request() }
                    } else if !location.isGranted {
                        Button("Buka Privasi…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else {
                        Button("Pindai Ulang", action: rescan)
                    }
                }
            }
            if let result, !result.networks.isEmpty {
                ForEach(Array(result.networks.prefix(40).enumerated()), id: \.offset) { _, network in
                    let isOwn = network.name != nil && network.name == ownSSID
                    HStack(spacing: 10) {
                        Image(systemName: "wifi", variableValue: ChannelSurvey.signalWeight(network.rssi))
                            .foregroundStyle(.secondary).frame(width: 18)
                        Text(network.name ?? "Tanpa nama").foregroundStyle(network.name == nil ? .secondary : .primary).lineLimit(1)
                        if isOwn { Text("Wi-Fi kamu").font(.app(.caption)).foregroundStyle(Brand.accent) }
                        Spacer()
                        Text("Ch \(network.channel) · \(network.widthMHz) MHz · \(network.rssi) dBm")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(result == nil ? "Hasil pindaian akan muncul di sini." : "Tidak ada jaringan 2,4 GHz lain yang terdengar.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Jaringan di Sekitar")
                Spacer()
                if let result {
                    Text("\(result.networks.count) di 2,4 GHz" + (result.otherBandCount > 0 ? " · \(result.otherBandCount) di 5/6 GHz diabaikan" : ""))
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Dihitung dari jaringan yang terdengar oleh Mac ini di posisinya sekarang. Gangguan non-Wi-Fi seperti microwave atau Bluetooth tidak terdeteksi.")
                .foregroundStyle(.secondary)
        }
    }
}

extension ChannelQuality.Level {
    var color: Color {
        switch self {
        case .good: Brand.good
        case .fair: Brand.warn
        case .busy: Brand.bad
        }
    }

    var label: String {
        switch self {
        case .good: "Lega"
        case .fair: "Sedang"
        case .busy: "Padat"
        }
    }
}
