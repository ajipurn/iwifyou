import Foundation

/// Read-only presentation of the observed WLAN form. Secrets such as the
/// passphrase or WEP keys are never copied into this value.
public struct WLANDetails: Equatable, Sendable {
    public let standard: String
    public let security: String
    public let encryption: String?
    public let transmitPower: String
    public let region: String
    public let hiddenSSID: Bool
    public let maxClients: Int?
    public let clientIsolation: Bool
    public let wmm: Bool
    public let sideBand: String?
    public let macFilter: String

    public static let demo = WLANDetails(
        standard: "802.11b/g/n", security: "WPA/WPA2-Personal", encryption: "AES",
        transmitPower: "100%", region: "CN", hiddenSSID: false, maxClients: 32,
        clientIsolation: false, wmm: true, sideBand: nil, macFilter: "Nonaktif"
    )

    init(
        standard: String, security: String, encryption: String?, transmitPower: String, region: String,
        hiddenSSID: Bool, maxClients: Int?, clientIsolation: Bool, wmm: Bool, sideBand: String?, macFilter: String
    ) {
        self.standard = standard
        self.security = security
        self.encryption = encryption
        self.transmitPower = transmitPower
        self.region = region
        self.hiddenSSID = hiddenSSID
        self.maxClients = maxClients
        self.clientIsolation = clientIsolation
        self.wmm = wmm
        self.sideBand = sideBand
        self.macFilter = macFilter
    }

    init(fields: [String: String]) {
        let value = { (key: String) in fields[key] ?? "" }

        let modes = value("Standard").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        standard = modes.isEmpty ? "—" : "802.11" + modes.joined(separator: "/")

        let beacon = value("BeaconType")
        let auth = beacon == "WPA" ? value("WPAAuthMode") : value("11iAuthMode")
        let suffix = switch auth {
        case "PSKAuthentication": "-Personal"
        case "EAPAuthentication": "-Enterprise"
        default: ""
        }
        switch beacon {
        case "None":
            security = "Terbuka (tanpa password)"
            encryption = nil
        case "Basic":
            security = "WEP"
            encryption = value("WEPEncryptionLevel").isEmpty ? nil : value("WEPEncryptionLevel")
        case "WPA":
            security = "WPA" + suffix
            encryption = Self.cipher(value("WPAEncryptType"))
        case "11i":
            security = "WPA2" + suffix
            encryption = Self.cipher(value("11iEncryptType"))
        case "WPAand11i":
            security = "WPA/WPA2" + suffix
            encryption = Self.cipher(value("11iEncryptType"))
        default:
            security = beacon.isEmpty ? "—" : beacon
            encryption = nil
        }

        transmitPower = value("TxPower").isEmpty ? "—" : value("TxPower")
        let country = value("CountryCode")
        if country.count == 3, country.hasSuffix("I"), country.prefix(2).allSatisfy(\.isLetter) {
            region = country.prefix(2).uppercased()
        } else {
            region = country.isEmpty ? "—" : country
        }
        hiddenSSID = value("ESSIDHideEnable") == "1"
        maxClients = Int(value("MaxUserNum"))
        clientIsolation = value("SSIDIsolationEnable") == "1"
        wmm = value("QosType") == "WMM"
        if value("BandWidth") != "20Mhz" {
            sideBand = switch value("SideBand") {
            case "Upper": "Atas"
            case "Lower": "Bawah"
            case "": nil
            default: value("SideBand")
            }
        } else {
            sideBand = nil
        }
        macFilter = switch value("ACLPolicy") {
        case "Disabled": "Nonaktif"
        case "Allow": "Hanya izinkan daftar"
        case "Deny": "Blokir daftar"
        case "": "—"
        default: value("ACLPolicy")
        }
    }

    private static func cipher(_ value: String) -> String? {
        switch value {
        case "AESEncryption": "AES"
        case "TKIPEncryption": "TKIP"
        case "TKIPandAESEncryption": "TKIP+AES"
        case "": nil
        default: value
        }
    }
}
