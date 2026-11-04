import Foundation

/// A Mac's ECID: the one identity that survives normal, DFU, recovery and restore mode.
/// On the wire it's cfgutil's hex form (`0x1234ABCD5001E`): ECIDs pass 2^53, so never a JSON number.
public struct ECID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    /// `0x1A2B`, `1A2B`, any case. Zero is no ECID.
    public init?(hex text: String) {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.lowercased().hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        guard !hex.isEmpty, hex.count <= 16, let value = UInt64(hex, radix: 16), value != 0 else { return nil }
        self.value = value
    }

    public var description: String { "0x" + String(value, radix: 16, uppercase: true) }

    public static func < (a: ECID, b: ECID) -> Bool { a.value < b.value }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let ecid = ECID(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ECID: \(text)"))
        }
        self = ecid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The USB mode an Apple-silicon Mac shows up in.
public enum MacMode: String, Codable, Sendable {
    case normal, dfu, recovery, restore
}

/// One Apple-silicon Mac on the host's USB-C ports.
public struct USBMac: Equatable, Sendable, Codable {
    public var ecid: ECID
    public var mode: MacMode
    public var productID: Int
    public var locationID: UInt32
    /// The real serial number, when this mode shows it (normal, sometimes recovery).
    public var serial: String?
    /// Chip ID (CPID), when this mode shows it (DFU, recovery, restore).
    public var chip: UInt32?

    public init(ecid: ECID, mode: MacMode, productID: Int, locationID: UInt32, serial: String? = nil, chip: UInt32? = nil) {
        self.ecid = ecid
        self.mode = mode
        self.productID = productID
        self.locationID = locationID
        self.serial = serial
        self.chip = chip
    }

    /// The host's USB-C port controller (hpmN): the location ID's top byte. Each
    /// USB-C port on an Apple-silicon Mac is its own controller.
    public var port: Int { Int(locationID >> 24) }
}

/// A restore image on local disk. cfgutil's own download fails (701), so restores
/// only ever run from a local file.
public struct IPSWImage: Equatable, Sendable, Codable {
    public var path: String
    public var version: String
    public var build: String

    public init(path: String, version: String, build: String) {
        self.path = path
        self.version = version
        self.build = build
    }

    /// `UniversalMac_27.2_26B123_Restore.ipsw` → version 27.2, build 26B123.
    public init?(path: String) {
        let name = (path as NSString).lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count == 4, parts[0] == "UniversalMac", parts[3] == "Restore.ipsw",
              parts[1].allSatisfy({ $0.isNumber || $0 == "." }), parts[1].first?.isNumber == true,
              parts[2].allSatisfy({ $0.isASCII && ($0.isNumber || $0.isUppercase) }), !parts[2].isEmpty
        else { return nil }
        self.init(path: path, version: String(parts[1]), build: String(parts[2]))
    }
}
