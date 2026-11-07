import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    let close: () -> Void
    @ViewState<String> private var address = ""
    @ViewState<String> private var username = ""
    @ViewState<String> private var password = ""
    @ViewState<Bool> private var remember = false
    @ViewState<Bool> private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                LogoMark(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hubungkan iwifyou").font(.app(.title2).weight(.semibold))
                    Text("ZTE F460 · Wi-Fi 2,4 GHz").font(.app(.subheadline)).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("Alamat router", text: $address, prompt: Text("192.168.1.1"))
                    .autocorrectionDisabled()
                TextField("Username admin", text: $username, prompt: Text("Akun panel router"))
                    .autocorrectionDisabled()
                SecureField("Password admin", text: $password, prompt: Text(model.remembersPassword ? "Tersimpan di Keychain" : "Password panel router"))
                Toggle("Simpan password di Keychain", isOn: $remember)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 215)
            .disabled(model.state.isBusy || model.isDemo)

            Text("Gunakan akun admin router, bukan password Wi-Fi. Jika sesi router masih aktif, kolom akun boleh dikosongkan.")
                .font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Sesi dilepas setelah 2 menit idle. Keychain memungkinkan login otomatis saat kamu memakai app lagi.")
                .font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Login dikirim hanya ke alamat IP lokal di atas. F460 memakai HTTP; gunakan pada jaringan yang kamu percaya.")
                .font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if model.isDemo {
                Label("Mode demo aktif. Jalankan ulang tanpa --demo untuk menghubungkan router.", systemImage: "testtube.2")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            } else if attempted, let feedback {
                Text(feedback).font(.app(.caption)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("iwifyou \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0")")
                    .font(.app(.caption)).foregroundStyle(.tertiary)
                Spacer()
                Button("Tutup") { password = ""; close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.state.isBusy ? model.statusText : "Hubungkan") {
                    attempted = true
                    Task {
                        let connected = await model.connect(address: address, username: username, password: password, remember: remember)
                        password = ""
                        if connected { close() }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.state.isBusy || model.isDemo)
            }
        }
        .padding(24)
        .frame(width: 460)
        .font(.app(.body))
        .onAppear {
            address = model.addressText
            username = model.username
            remember = model.remembersPassword
        }
        .onDisappear { password = "" }
    }

    private var feedback: String? {
        if let message = model.message { return message }
        switch model.state {
        case .adminBusy(let value): return value
        case .rejected(_, let value): return value
        case .needsLogin(let value), .failed(let value): return value
        default: return nil
        }
    }
}
