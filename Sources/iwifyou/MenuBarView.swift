import AppKit
import IWiFiYouCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    let openMainWindow: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                LogoMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iwifyou").font(.app(.headline))
                    Text("Wi-Fi, tinggal klik.").font(.app(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.state.isBusy { ProgressView().controlSize(.small).accessibilityLabel(model.statusText) }
            }

            HStack(spacing: 6) {
                Circle().fill(model.statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(model.statusText).font(.app(.caption).weight(.medium))
                Spacer()
                Text(model.isDemo ? "F460 · demo" : model.displayAddress)
                    .font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if model.isDemo {
                Label("Mode demo. Router tidak diubah.", systemImage: "testtube.2")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }

            if let snapshot = model.state.snapshot {
                connectedContent(snapshot)
                if case .rejected(_, let reason) = model.state {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                disconnectedContent
            }

            if let message = model.message {
                Label(message, systemImage: "info.circle")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.isDemo {
                Button {
                    Task {
                        if let url = await model.prepareAdminBrowser() { NSWorkspace.shared.open(url) }
                    }
                } label: { Label("Buka admin router", systemImage: "arrow.up.right.square") }
                .buttonStyle(.borderless).font(.app(.caption)).disabled(model.state.isBusy)
                .help("Lepas sesi iwifyou sebelum membuka browser")
            }

            Divider()
            HStack {
                Button { openMainWindow() } label: { Label("Buka jendela", systemImage: "macwindow") }
                    .buttonStyle(.plain).font(.app(.caption))
                Button { showSettings() } label: { Label("Akun…", systemImage: "gearshape") }
                    .buttonStyle(.plain).font(.app(.caption))
                    .disabled(model.state.isBusy)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Perbarui status router")
                    .accessibilityLabel("Perbarui status router").disabled(model.state.isBusy)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless).help("Keluar dari iwifyou").accessibilityLabel("Keluar dari iwifyou")
                    .disabled(model.state.isBusy)
            }
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 348)
        .font(.app(.body))
        .onAppear { model.noteInteraction() }
        .task { await model.startIfNeeded() }
    }

    private func connectedContent(_ snapshot: RouterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.ssid).font(.app(size: 17, weight: .semibold)).lineLimit(2)
                        .textSelection(.enabled)
                    Text("2,4 GHz · \(snapshot.bandwidth)").font(.app(.caption)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snapshot.channel.label).font(.app(size: 30, weight: .medium)).monospacedDigit()
                    Text(snapshotCaption).font(.app(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 9) {
                Text("Pilih channel").font(.app(.subheadline).weight(.medium))
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(snapshot.availableChannels, id: \.self) { channel in
                        let selected = model.selectedChannel == channel
                        Button { model.selectChannel(channel) } label: {
                            Text(channel.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .background(selected ? Brand.accent.opacity(0.14) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 1.5))
                        .foregroundStyle(selected ? Brand.accent : .primary)
                        .accessibilityLabel(channel == .automatic ? "Channel otomatis" : "Channel \(channel.label)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .disabled(!model.canSelectChannel)
                    }
                }
            }
            if !snapshot.radioEnabled {
                Label("Radio Wi-Fi nonaktif.", systemImage: "wifi.slash").font(.app(.caption)).foregroundStyle(.secondary)
            }
            Button {
                if model.requiresLoginBeforeApply { showSettings() }
                else { Task { await model.applySelectedChannel() } }
            } label: {
                Text(model.state.isBusy ? model.statusText : model.applyTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canApply)
            Text("Wi-Fi bisa terputus sebentar saat channel berubah.")
                .font(.app(.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var disconnectedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: model.state.isBusy ? "wifi" : "wifi.exclamationmark")
                .font(.app(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.disconnectedTitle)
                .font(.app(.headline))
            Text(model.connectionMessage).font(.app(.subheadline)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.state.isBusy {
                switch model.state {
                case .rejected, .adminBusy:
                    Button("Perbarui status") { Task { await model.refresh() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                default:
                    Button("Buka pengaturan") { showSettings() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var snapshotCaption: String {
        if case .released = model.state { return "Terakhir dibaca" }
        if case .rejected = model.state { return "Terakhir dibaca" }
        return "Tersimpan"
    }

    private func showSettings() {
        openSettings()
    }
}
