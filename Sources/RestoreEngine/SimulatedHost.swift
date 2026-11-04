import Foundation

/// A pretend host with Macs on its USB-C ports. It behaves as real hardware did:
/// - the host can only send DFU as power source: it must be on its charger, and a Mac that's
///   on powers the host (`Sink`) until it agrees to a power role swap;
/// - one `dfu` send often only reboots the target (`sendsNeeded`);
/// - a Mac that was USB host when it went into DFU only shows after a `replug`;
/// - restores fail on demand, and a restored Mac boots back into normal mode.
/// Nothing here touches USB.
public actor SimulatedHost {
    public struct Mac: Sendable {
        public var ecid: ECID
        public var serial: String
        public var port: Int
        public var mode: MacMode?  // nil = off
        public var refusesSwap = false
        public var sendsNeeded = 1
        public var restoreFailures = 0
        /// The cable is in the Mac's wrong port.
        public var wrongPort = false
        var powersHost: Bool
        var sends = 0
        var hiddenUntilReplug = false
        var moved = 0

        public init(ecid: ECID, serial: String, port: Int, mode: MacMode? = .normal) {
            self.ecid = ecid
            self.serial = serial
            self.port = port
            self.mode = mode
            powersHost = mode == .normal
        }
    }

    public var charger = true
    public var scanFails = false
    public private(set) var macs: [Mac] = []
    /// Every macvdmtool call, as "verb@port".
    public private(set) var calls: [String] = []
    public private(set) var restoresRunning = 0
    public private(set) var mostRestoresAtOnce = 0
    /// How long a pretend restore takes, in clock seconds.
    public var restoreSeconds: Double = 4
    public var bootSeconds: Double = 2
    /// A restored Mac stays off instead of starting up (as when it shuts down).
    public var staysOffAfterRestore = false
    let clock: EngineClock

    public init(clock: EngineClock = SystemClock(), macs: [Mac] = []) {
        self.clock = clock
        self.macs = macs
    }

    public func add(_ mac: Mac) { macs.append(mac) }
    public func unplug(_ ecid: ECID) { macs.removeAll { $0.ecid == ecid } }
    public func setCharger(_ on: Bool) { charger = on }
    public func setScanFails(_ fails: Bool) { scanFails = fails }
    public func setRestoreSeconds(_ seconds: Double) { restoreSeconds = seconds }
    public func setStaysOffAfterRestore(_ off: Bool) { staysOffAfterRestore = off }
    /// Moves a Mac's cable to another port. It stays in whatever mode it's in (a Mac in
    /// DFU stays in DFU); a restore running on it dies.
    public func move(_ ecid: ECID, to port: Int) {
        guard let index = macs.firstIndex(where: { $0.ecid == ecid }) else { return }
        macs[index].port = port
        macs[index].moved += 1
    }
    public func edit(_ ecid: ECID, _ change: @Sendable (inout Mac) -> Void) {
        if let index = macs.firstIndex(where: { $0.ecid == ecid }) { change(&macs[index]) }
    }
    public func mac(_ ecid: ECID) -> Mac? { macs.first { $0.ecid == ecid } }

    func usb() -> [USBMac]? {
        guard !scanFails else { return nil }
        return macs.compactMap { mac in
            guard let mode = mac.mode, !mac.hiddenUntilReplug else { return nil }
            let location = UInt32(mac.port) << 24 | 0x0010_0000
            switch mode {
            case .normal: return USBMac(ecid: mac.ecid, mode: .normal, productID: 0x1903, locationID: location, serial: mac.serial)
            case .dfu: return USBMac(ecid: mac.ecid, mode: .dfu, productID: 0x1227, locationID: location, chip: 0x8103)
            case .recovery: return USBMac(ecid: mac.ecid, mode: .recovery, productID: 0x1281, locationID: location, chip: 0x8103)
            case .restore: return USBMac(ecid: mac.ecid, mode: .restore, productID: 0x12AC, locationID: location, chip: 0x8103)
            }
        }
    }

    func vdm(_ verb: VDMVerb, port: Int) -> (Int32, String) {
        calls.append("\(verb.rawValue)@\(port)")
        guard let index = macs.firstIndex(where: { $0.port == port }) else {
            return (1, "Mac type: J313AP\nNo connection detected")
        }
        let source = charger && !macs[index].powersHost
        switch verb {
        case .nop:
            return (0, "Connection: \(source ? "Source" : "Sink")")
        case .swapsource:
            if charger, !macs[index].refusesSwap { macs[index].powersHost = false }
            return (0, "")
        case .replug:
            macs[index].hiddenUntilReplug = false
            return (0, "")
        case .dfu:
            if macs[index].wrongPort { return (1, "VDM failed (reply: 0x05ac8092)") }
            // As Sink the target just reboots normally.
            guard source else { return (0, "Status: OK") }
            macs[index].sends += 1
            if macs[index].sends >= macs[index].sendsNeeded, macs[index].mode != .dfu {
                // A Mac that was on was USB host: it shows only after the roles are renegotiated.
                macs[index].hiddenUntilReplug = macs[index].mode != nil
                macs[index].mode = .dfu
            }
            return (0, "Status: OK")
        }
    }

    func runRestore(_ ecid: ECID) async -> RestoreEvent {
        guard let index = macs.firstIndex(where: { $0.ecid == ecid }), macs[index].mode == .dfu else {
            return .failed("No device in DFU with ECID \(ecid).")
        }
        restoresRunning += 1
        mostRestoresAtOnce = max(mostRestoresAtOnce, restoresRunning)
        defer { restoresRunning -= 1 }
        let fails = macs[index].restoreFailures > 0
        if fails { macs[index].restoreFailures -= 1 }
        macs[index].mode = .restore
        let moves = macs[index].moved
        await clock.sleep(restoreSeconds)
        guard let after = macs.firstIndex(where: { $0.ecid == ecid }), macs[after].moved == moves else {
            return .failed("The device was disconnected. (Domain: AMRestoreErrorDomain Code: 9)")
        }
        if fails {
            macs[after].mode = .recovery
            return .failed("The restore failed. (Domain: AMRestoreErrorDomain Code: 4014)")
        }
        macs[after].mode = nil
        macs[after].sends = 0
        if staysOffAfterRestore { return .succeeded }
        let clock = clock
        let boot = bootSeconds
        Task {
            await clock.sleep(boot)
            self.edit(ecid) { $0.mode = .normal; $0.powersHost = true }
        }
        return .succeeded
    }

    public nonisolated var bench: Bench { SimBench(host: self) }
    public nonisolated var tool: VDMTool { SimVDM(host: self) }
    /// The root door, run in-process: the same `DFUSequence` as `restore-engine-dfu`.
    public nonisolated func door(sequence: DFUSequence = DFUSequence()) -> DFUDoor {
        SimDoor(host: self, sequence: sequence)
    }
}

struct SimBench: Bench {
    let host: SimulatedHost
    func usbMacs() async -> [USBMac]? { await host.usb() }
    func chargerConnected() async -> Bool? { await host.charger }
    func portActive(_ port: Int) async -> Bool? { await host.macs.contains { $0.port == port } }
    func restore(ecid: ECID, ipsw: IPSWImage) -> AsyncStream<RestoreEvent> {
        AsyncStream { continuation in
            Task {
                continuation.yield(.step("Installing System"))
                continuation.yield(.progress(0.5))
                continuation.yield(await host.runRestore(ecid))
                continuation.finish()
            }
        }
    }
}

struct SimVDM: VDMTool {
    let host: SimulatedHost
    func run(_ verb: VDMVerb, port: Int) async -> (status: Int32, output: String) {
        let (status, output) = await host.vdm(verb, port: port)
        return (status, output)
    }
}

struct SimDoor: DFUDoor {
    let host: SimulatedHost
    let sequence: DFUSequence
    func enterDFU(port: Int) async -> DFUOutcome {
        await sequence.run(port: port, tool: SimVDM(host: host), clock: host.clock) { port in
            await host.usb()?.contains { $0.port == port && $0.mode == .dfu } ?? false
        }
    }
}
