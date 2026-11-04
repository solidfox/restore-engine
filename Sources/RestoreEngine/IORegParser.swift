import Foundation

/// Reads Apple-silicon Macs out of `ioreg -p IOUSB -w0 -l` (no root, sends nothing).
///
/// What a Mac on the other end of a USB-C data cable looks like:
/// - normal mode: `USB Serial Number` is its serial, `UsbAppleDeviceECID` its ECID;
/// - DFU (0x1227) or recovery (0x1280–0x1283): `CPID:8103 … ECID:<hex> …`, recovery
///   sometimes `SRNM:[serial]`;
/// - restore mode (0x12AC): `0000<CPID>-<ECID>`.
/// iPhones and iPads share the DFU/recovery/restore product IDs; their chip tells them apart.
public enum IORegParser {
    static let appleVendor = 0x05AC
    static let dfuProduct = 0x1227
    static let recoveryProducts = 0x1280...0x1283
    static let restoreProduct = 0x12AC
    /// iPhone/iPad normal-mode product IDs (never a Mac's).
    static let iOSNormalProducts = 0x1290...0x12AF

    public static func parse(_ text: String) -> [USBMac] {
        var blocks: [[String: String]] = []
        var current: [String: String]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("+-o ") {
                if let current { blocks.append(current) }
                current = [:]
                continue
            }
            guard current != nil,
                  let open = line.firstIndex(of: "\""),
                  let separator = line.range(of: "\" = ", range: line.index(after: open)..<line.endIndex)
            else { continue }
            let key = String(line[line.index(after: open)..<separator.lowerBound])
            // A device's own properties come first; nested dictionaries are one line with -l.
            guard current?[key] == nil else { continue }
            var value = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            current?[key] = value
        }
        if let current { blocks.append(current) }
        return blocks.compactMap(mac(from:))
    }

    static func mac(from p: [String: String]) -> USBMac? {
        guard integer(p["idVendor"]) == UInt64(appleVendor),
              let product = integer(p["idProduct"]).map(Int.init),
              let location = integer(p["locationID"]).flatMap({ UInt32(exactly: $0) })
        else { return nil }
        let usbSerial = p["USB Serial Number"] ?? p["kUSBSerialNumberString"] ?? ""
        let reportedECID = integer(p["UsbAppleDeviceECID"]).flatMap { $0 == 0 ? nil : ECID($0) }

        switch product {
        case dfuProduct, recoveryProducts:
            let chip = hexField("CPID", in: usbSerial).flatMap { UInt32(exactly: $0) }
            guard let chip, isMacChip(chip),
                  let ecid = hexField("ECID", in: usbSerial).flatMap({ $0 == 0 ? nil : ECID($0) }) ?? reportedECID
            else { return nil }
            let mode: MacMode = product == dfuProduct ? .dfu : .recovery
            return USBMac(ecid: ecid, mode: mode, productID: product, locationID: location,
                          serial: mode == .recovery ? bracketed("SRNM", in: usbSerial) : nil, chip: chip)
        case restoreProduct:
            guard let (chip, ecid) = restoreModeSerial(usbSerial), isMacChip(chip) else { return nil }
            return USBMac(ecid: reportedECID ?? ecid, mode: .restore, productID: product, locationID: location, chip: chip)
        case iOSNormalProducts:
            return nil
        default:
            // Normal mode (0x1903 Air, 0x1902 Pro, and whatever newer models use).
            guard let ecid = reportedECID else { return nil }
            return USBMac(ecid: ecid, mode: .normal, productID: product, locationID: location,
                          serial: plausibleSerial(usbSerial))
        }
    }

    /// Mac chips: M1 0x8103, base M2 and later 0x81x2, Pro/Max/Ultra 0x60xx. iPhone
    /// A-chips (0x8101, 0x81x0, 0x80xx) are left out. An iPad with an M chip has a Mac's
    /// CPID; that's why callers act on a Mac they've seen in normal mode, by ECID.
    public static func isMacChip(_ cpid: UInt32) -> Bool {
        cpid == 0x8103 || ((0x8100...0x81FF).contains(cpid) && cpid & 0xF == 0x2) || (0x6000...0x60FF).contains(cpid)
    }

    /// ioreg prints numbers in decimal; hex (`0x…`) is accepted too.
    static func integer(_ text: String?) -> UInt64? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }

    /// `ECID:005100ABCDEF0123` → value.
    static func hexField(_ name: String, in text: String) -> UInt64? {
        guard let range = text.range(of: "\(name):") else { return nil }
        let hex = text[range.upperBound...].prefix { $0.isHexDigit }
        return hex.isEmpty || hex.count > 16 ? nil : UInt64(hex, radix: 16)
    }

    /// `SRNM:[C02XXXXXXXXX]` → `C02XXXXXXXXX`.
    static func bracketed(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name):[") else { return nil }
        return plausibleSerial(String(text[range.upperBound...].prefix { $0 != "]" }))
    }

    /// Restore mode serial string `00008103-0001234ABCD5001E` → (chip, ECID).
    static func restoreModeSerial(_ text: String) -> (UInt32, ECID)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2, parts[0].count == 8, parts[0].hasPrefix("0000"), parts[1].count == 16,
              let chip = UInt32(parts[0].dropFirst(4), radix: 16),
              let ecid = ECID(hex: String(parts[1]))
        else { return nil }
        return (chip, ecid)
    }

    /// Apple serials: 10 random characters (2021 on) or 12 (before).
    static func plausibleSerial(_ text: String) -> String? {
        let serial = text.trimmingCharacters(in: .whitespaces).uppercased()
        let ok = (10...12).contains(serial.count) && serial.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
        return ok ? serial : nil
    }
}
