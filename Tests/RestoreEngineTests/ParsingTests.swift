import Foundation
import Testing
@testable import RestoreEngine

@Suite struct ParsingTests {
    @Test func eCID() throws {
        #expect(ECID(hex: "0x1a2b")?.value == 0x1A2B)
        #expect(ECID(hex: "1A2B")?.description == "0x1A2B")
        #expect(ECID(hex: "0x0") == nil)
        #expect(ECID(hex: "") == nil)
        #expect(ECID(hex: "0x12345678901234567") == nil)
        #expect(ECID(hex: "xyz") == nil)
        // Past 2^53: a string on the wire, never a JSON number.
        let big = ECID(0x0051_00AB_CDEF_0123)
        let json = try JSONEncoder().encode([big])
        #expect(String(decoding: json, as: UTF8.self) == #"["0x5100ABCDEF0123"]"#)
        #expect(try JSONDecoder().decode([ECID].self, from: json) == [big])
        #expect(throws: (any Error).self) { try JSONDecoder().decode([ECID].self, from: Data(#"["nope"]"#.utf8)) }
    }

    @Test func iPSWName() {
        let image = IPSWImage(path: "/Users/Shared/x/UniversalMac_27.2_26B123_Restore.ipsw")
        #expect(image?.version == "27.2")
        #expect(image?.build == "26B123")
        #expect(IPSWImage(path: "/x/iPhone_27.2_26B123_Restore.ipsw") == nil)
        #expect(IPSWImage(path: "/x/UniversalMac_27.2_26B123_Restore.ipsw.part") == nil)
        #expect(IPSWImage(path: "/x/UniversalMac__26B123_Restore.ipsw") == nil)
    }

    // ioreg -p IOUSB -w0 -l, trimmed to what matters. Serials and ECIDs are made up.
    static let ioreg = """
    +-o Root  <class IORegistryEntry, id 0x100000100, retain 20>
      +-o AppleT8103USBXHCI@00000000  <class AppleT8103USBXHCI>
      | +-o MacBook Air@00100000  <class IOUSBHostDevice, id 0x100001000>
      |     {
      |       "idProduct" = 6403
      |       "idVendor" = 1452
      |       "locationID" = 1048576
      |       "USB Serial Number" = "SIMSERIAL01"
      |       "UsbAppleDeviceECID" = 175921860444161
      |       "IOCFPlugInTypes" = {"9dc7b780-9ec0-11d4-a54f-000a27052861"="IOUSBHostFamily.kext/Contents/PlugIns/IOUSBLib.bundle"}
      |     }
      +-o AppleT8103USBXHCI@01000000  <class AppleT8103USBXHCI>
      | +-o Apple Mobile Device (DFU Mode)@01100000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 0x1227
      |       "idVendor" = 0x5ac
      |       "locationID" = 17825792
      |       "USB Serial Number" = "CPID:8103 CPRV:11 CPFM:03 SCEP:01 BDID:26 ECID:0000B00000000002 IBFL:3C SRTG:[iBoot-7459.101.3]"
      |     }
      +-o AppleT8103USBXHCI@02000000  <class AppleT8103USBXHCI>
      | +-o Apple Mobile Device (Recovery Mode)@02100000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 4737
      |       "idVendor" = 1452
      |       "locationID" = 34603008
      |       "USB Serial Number" = "CPID:6000 CPRV:11 ECID:0000C00000000003 SRNM:[SIMSERIAL3X] IBFL:3C"
      |     }
      | +-o iPhone DFU@02200000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 4647
      |       "idVendor" = 1452
      |       "locationID" = 35651584
      |       "USB Serial Number" = "CPID:8101 ECID:0000D00000000004"
      |     }
      | +-o Restore@02300000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 4780
      |       "idVendor" = 1452
      |       "locationID" = 36700160
      |       "USB Serial Number" = "00008112-0000E00000000005"
      |     }
      | +-o iPad@02400000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 4779
      |       "idVendor" = 1452
      |       "locationID" = 37748736
      |       "UsbAppleDeviceECID" = 99
      |     }
      | +-o Keyboard@02500000  <class IOUSBHostDevice>
      |     {
      |       "idProduct" = 6403
      |       "idVendor" = 1133
      |       "locationID" = 38797312
      |       "UsbAppleDeviceECID" = 98
      |     }
    """

    @Test func iOReg() {
        let macs = IORegParser.parse(Self.ioreg)
        #expect(macs.map(\.mode) == [.normal, .dfu, .recovery, .restore])
        #expect(macs[0].ecid == macA)
        #expect(macs[0].serial == "SIMSERIAL01")
        #expect(macs[0].port == 0)
        #expect(macs[1].ecid == macB)
        #expect(macs[1].chip == 0x8103)
        #expect(macs[1].port == 1)
        #expect(macs[1].serial == nil)
        #expect(macs[2].ecid == macC)
        #expect(macs[2].serial == "SIMSERIAL3X")
        #expect(macs[2].port == 2)
        #expect(macs[3].ecid == ECID(0xE000_0000_0005))
        #expect(macs[3].chip == 0x8112)
        #expect(IORegParser.parse("") == [])
    }

    @Test func macChips() {
        for chip: UInt32 in [0x8103, 0x8112, 0x8122, 0x8132, 0x6000, 0x6021] { #expect(IORegParser.isMacChip(chip), "\(chip)") }
        for chip: UInt32 in [0x8101, 0x8110, 0x8120, 0x8015] { #expect(!(IORegParser.isMacChip(chip)), "\(chip)") }
    }

    @Test func restoreOutput() {
        let parser = RestoreOutputParser()
        var events: [RestoreEvent] = []
        for line in [
            #"Step = "Waiting for the device";"#, #"Progress = "0.25";"#, #"Step = "Waiting for the device";"#,
            "Progress = -1;", #"Step = "Installing System";"#, "Progress = 1.5;",
            "Restored System on Apple Mobile Device (DFU Mode)",
        ] { events += parser.feed(line) }
        #expect(events == [.step("Waiting for the device"), .progress(0.25), .step("Installing System"), .progress(1)])
        #expect(parser.finish(exitStatus: 0) == .succeeded)

        let failed = RestoreOutputParser()
        _ = failed.feed("cfgutil: error: The device was disconnected.")
        _ = failed.feed("(Domain: AMRestoreErrorDomain Code: 9)")
        _ = failed.feed(#""restore" failed on Apple Mobile Device"#)
        #expect(failed.finish(exitStatus: 0) == .failed("The device was disconnected. (Domain: AMRestoreErrorDomain Code: 9)"))

        // Exit 0 alone isn't success.
        #expect(RestoreOutputParser().finish(exitStatus: 0) == .failed("cfgutil exited with status 0."))
    }

    @Test func rootReply() {
        #expect(RootReply.parse("noise\n{\"outcome\":\"sink\"}\n") == RootReply(outcome: .sink))
        #expect(RootReply.parse("sudo: a password is required") == nil)
        #expect(RootReply(outcome: .inDFU).exitStatus == 0)
        #expect(RootReply(outcome: .busy).exitStatus == 6)
    }

    @Test func hPMPortActive() {
        #expect(MacBench.portActive(hpm: "  \"ConnectionActive\" = Yes\n  \"ConnectionActive\" = No") == true)
        #expect(MacBench.portActive(hpm: "  \"ConnectionActive\" = No") == false)
        #expect(MacBench.portActive(hpm: "") == nil)
    }

    @Test func rootToolTrust() {
        let dir = UInt32(S_IFDIR) | 0o755
        let file = UInt32(S_IFREG) | 0o755
        let good: [String: RootTool.Entry] = [
            "/": .init(uid: 0, mode: dir), "/usr": .init(uid: 0, mode: dir), "/usr/local": .init(uid: 0, mode: dir),
            "/usr/local/libexec": .init(uid: 0, mode: dir), "/usr/local/libexec/macvdmtool": .init(uid: 0, mode: file),
        ]
        func check(_ fs: [String: RootTool.Entry], _ path: String = "/usr/local/libexec/macvdmtool") -> String? {
            RootTool.untrusted(path) { fs[$0] }
        }
        #expect(check(good) == nil)
        var fs = good; fs["/usr/local"] = .init(uid: 501, mode: dir)
        #expect(check(fs) == "/usr/local isn't owned by root.")
        fs = good; fs["/usr/local/libexec"] = .init(uid: 0, mode: dir | 0o020)
        #expect(check(fs) == "/usr/local/libexec is writable by others.")
        fs = good; fs["/usr/local/libexec/macvdmtool"] = .init(uid: 0, mode: UInt32(S_IFLNK) | 0o755)
        #expect(check(fs) == "/usr/local/libexec/macvdmtool is a symlink.")
        fs = good; fs["/usr/local/libexec/macvdmtool"] = .init(uid: 0, mode: file | 0o002)
        #expect(check(fs) != nil)
        fs = good; fs["/usr/local/libexec/macvdmtool"] = nil
        #expect(check(fs) == "/usr/local/libexec/macvdmtool is missing.")
        #expect(check(good, "usr/local/libexec/macvdmtool") != nil)
        #expect(check(good, "/usr/local/../local/libexec/macvdmtool") != nil)
        #expect(check(good, "/usr/local/libexec") != nil)  // a folder isn't a tool
    }
}
