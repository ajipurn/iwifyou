import Foundation

public enum RouterError: Error, LocalizedError, Equatable, Sendable {
    case invalidAddress
    case loginRequired
    case loginFailed
    case invalidSession
    case adminSessionInUse
    case unsupportedFirmware
    case radioDisabled
    case unavailableChannel
    case configurationChanged
    case otherSettingsChanged
    case rejected
    case unverified
    case httpStatus(Int)
    case invalidResponse
    case operationInProgress
    case logoutUnavailable
    case logoutUnverified
    case filterModeUnsupported
    case invalidDevice
    case protectedDevice
    case restartUnverified
    case invalidAddressInPool
    case duplicateEntry
    case invalidRule(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Masukkan alamat IP lokal router, misalnya 192.168.1.1."
        case .loginRequired:
            "Sesi router berakhir. Masuk melalui Pengaturan."
        case .loginFailed:
            "Login belum berhasil. Periksa akun admin; percobaan tidak diulang otomatis."
        case .invalidSession:
            "Token sesi router tidak berlaku. Klik Perbarui sebelum mencoba lagi."
        case .adminSessionInUse:
            "Router masih dipakai sesi admin lain. Logout dari sesi tersebut atau tunggu sampai berakhir, lalu klik Perbarui."
        case .unsupportedFirmware:
            "Format respons router belum dikenali oleh iwifyou."
        case .radioDisabled:
            "Radio Wi-Fi sedang nonaktif. Aktifkan melalui panel router terlebih dahulu."
        case .unavailableChannel:
            "Channel ini tidak tersedia pada router. Perbarui daftar channel."
        case .configurationChanged:
            "Pengaturan router berubah sejak terakhir dibaca. Klik Perbarui sebelum mencoba lagi."
        case .otherSettingsChanged:
            "Channel sudah berubah, tetapi pengaturan lain juga berbeda. Periksa panel router."
        case .rejected:
            "Router menolak perubahan. Perbarui untuk membaca pengaturan terbaru."
        case .unverified:
            "Perubahan sudah dikirim, tetapi hasilnya belum terverifikasi. Tunggu Wi-Fi tersambung, lalu klik Perbarui."
        case .httpStatus(let code):
            "Router merespons dengan HTTP \(code). Coba Perbarui."
        case .invalidResponse:
            "Respons router tidak dapat dibaca."
        case .operationInProgress:
            "Tunggu proses router yang sedang berjalan selesai."
        case .logoutUnavailable:
            "Form logout router belum dikenali. Sesi belum dapat dilepas otomatis."
        case .logoutUnverified:
            "Logout belum terverifikasi. Klik Perbarui, lalu coba Buka admin router lagi."
        case .filterModeUnsupported:
            "Filter MAC router memakai mode whitelist. iwifyou hanya mengelola mode blacklist; ubah lewat panel router."
        case .invalidDevice:
            "Perangkat ini tidak ditemukan atau alamat MAC-nya tidak valid. Klik Perbarui."
        case .protectedDevice:
            "Mac ini tidak bisa memblokir dirinya sendiri; koneksi ke router akan terputus."
        case .invalidAddressInPool:
            "Alamat IP harus berada di dalam rentang DHCP router."
        case .duplicateEntry:
            "Data yang sama sudah ada di router."
        case .invalidRule(let reason):
            reason
        case .restartUnverified:
            "Perintah restart terkirim, tetapi router tidak terlihat mati lalu menyala lagi. Periksa lampu router, lalu klik Perbarui."
        }
    }
}

public struct RouterAddress: Hashable, Sendable {
    public let url: URL

    public init(_ input: String) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = input.contains("://") ? input : "http://" + input
        guard var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, Self.isLocalIPv4(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              !raw.contains("\\")
        else { throw RouterError.invalidAddress }
        parts.scheme = scheme
        parts.path = "/"
        guard let url = parts.url else { throw RouterError.invalidAddress }
        self.url = url
    }

    public var displayName: String { url.host() ?? "Router" }
    public var storageID: String { url.absoluteString }

    public func contains(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.user == nil, candidate.password == nil else { return false }
        return candidate.scheme == url.scheme && candidate.host() == url.host()
            && effectivePort(candidate) == effectivePort(url)
    }

    private func effectivePort(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }

    private static func isLocalIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), (0...255).contains(number), String(number) == part
            else { return nil }
            return number
        }
        guard numbers.count == 4 else { return false }
        return numbers[0] == 10 || numbers[0] == 127
            || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }
}

public enum WiFiChannel: Hashable, Sendable {
    case automatic
    case fixed(Int)

    public var label: String {
        switch self { case .automatic: "Auto"; case .fixed(let number): String(number) }
    }
}

public struct RouterSnapshot: Equatable, Sendable {
    public let ssid: String
    public let channel: WiFiChannel
    public let availableChannels: [WiFiChannel]
    public let bandwidth: String
    public let radioEnabled: Bool
    public let details: WLANDetails
    // Hashes detect stale configuration without retaining Wi-Fi secrets in view state.
    public let revision: String
    public let otherSettingsRevision: String

    public static let demo = RouterSnapshot(
        ssid: "iwifyou demo", channel: .automatic,
        availableChannels: [.automatic] + (1...13).map(WiFiChannel.fixed),
        bandwidth: "20 MHz", radioEnabled: true, details: .demo,
        revision: "demo", otherSettingsRevision: "demo"
    )

    public func demoChangingChannel(to channel: WiFiChannel) -> RouterSnapshot {
        RouterSnapshot(
            ssid: ssid, channel: channel, availableChannels: availableChannels,
            bandwidth: bandwidth, radioEnabled: radioEnabled, details: details,
            revision: "demo", otherSettingsRevision: "demo"
        )
    }
}

enum FormEncoding {
    static func data(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        return Data(fields.keys.sorted().map { encode($0) + "=" + encode(fields[$0]!) }.joined(separator: "&").utf8)
    }
}
