import Foundation

public struct EngineConfig: Sendable {
    /// The host's USB-C port controllers that may send DFU.
    public var ports: [Int] = [0, 1, 2]
    /// More than 2 restores at once failed twice: one Mac per cfgutil, at most 2.
    public var maxRestores = 2
    /// After the DFU run, how long a DFU device may take to show up.
    public var dfuAppearWait: Double = 40
    public var poll: Double = 1
    /// A restored Mac must be back in normal mode within this.
    public var bootWait: Double = 15 * 60

    public init() {}
}

public enum JobPhase: String, Codable, Sendable {
    /// On USB (or seen before), nothing running.
    case connected
    /// Its port's DFU run is going.
    case enteringDFU
    /// In DFU, waiting for a restore slot.
    case queued
    case restoring
    /// cfgutil succeeded; waiting for it to boot (normal mode, same ECID).
    case rebooting
    case done
    case failed
}

/// One Mac the engine knows, by ECID.
public struct Job: Equatable, Sendable, Codable {
    public var ecid: ECID
    public var phase: JobPhase = .connected
    /// Where it is now; nil mode = not on USB right now.
    public var mode: MacMode?
    public var port: Int?
    /// Last serial seen (normal or recovery mode). DFU hides it.
    public var serial: String?
    /// The port its restore runs on: that cable must not move.
    public var restorePort: Int?
    public var step: String?
    public var progress: Double?
    /// Failed restores in a row. A Mac with failures restores alone.
    public var failures = 0
    public var solo = false
    public var error: String?
    public var ipsw: IPSWImage?

    public init(ecid: ECID) { self.ecid = ecid }

    public var isActive: Bool { [.enteringDFU, .queued, .restoring, .rebooting].contains(phase) }
}

public enum RefusalCode: String, Codable, Sendable {
    case unknownPort, scanFailed, dfuRunning, portRestoring, portHasDFUMac, portJustRestored
    case notAlone, notOnPort, wrongMac, notInDFU, alreadyActive, noIPSW, notQueued, unknownMac, shuttingDown, badCommand
}

/// Why the engine won't do something. `code` is the contract; `message` is English for
/// people and logs. Callers show their own words per code.
public struct Refusal: Error, Equatable, Sendable, Codable {
    public var code: RefusalCode
    public var message: String

    public init(_ code: RefusalCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct DFUResult: Equatable, Sendable, Codable {
    public var port: Int
    public var outcome: DFUOutcome
    /// The Mac that showed up in DFU on that port, if one did.
    public var ecid: ECID?
}

public enum EngineEvent: Equatable, Sendable {
    case macs([USBMac])
    case job(Job)
    case dfuStarted(port: Int)
    case dfuFinished(DFUResult)
}

public struct EngineState: Equatable, Sendable, Codable {
    public var macs: [USBMac]
    public var jobs: [Job]
    public var dfuPort: Int?
    public var charger: Bool?
    /// Ports where a Mac was restored and the cable hasn't been unplugged since.
    public var restoredPorts: [Int]
}

/// The bench rules, in one place, whoever is pressing the button:
/// - one DFU run at a time; never DFU a port with a restoring, DFU'd, booting or
///   just-restored Mac on it, or with more than one Mac on it;
/// - restore only a Mac that is in DFU now, from a local IPSW file;
/// - at most `maxRestores` restores at once; a Mac whose restore failed restores alone;
/// - nothing starts restoring on the port a DFU run is going on.
/// Callers decide *whether* a Mac may be restored; the engine decides whether it's safe.
public actor Engine {
    public let config: EngineConfig
    private let bench: Bench
    private let door: DFUDoor
    private let clock: EngineClock
    private let onEvent: @Sendable (EngineEvent) -> Void

    private var macs: [USBMac] = []
    private var jobs: [ECID: Job] = [:]
    private var queue: [ECID] = []
    private var dfuPort: Int?
    private var charger: Bool?
    /// Port → the Mac restored there, until that cable is unplugged.
    private var restoredOn: [Int: ECID] = [:]
    private var bootDeadline: [ECID: Double] = [:]
    /// Bumped per restore start, so a superseded cfgutil stream is ignored.
    private var runs: [ECID: Int] = [:]
    private var closed = false

    public init(config: EngineConfig = EngineConfig(), bench: Bench, door: DFUDoor,
                clock: EngineClock = SystemClock(), onEvent: @escaping @Sendable (EngineEvent) -> Void = { _ in }) {
        self.config = config
        self.bench = bench
        self.door = door
        self.clock = clock
        self.onEvent = onEvent
    }

    // MARK: Reading

    public func state() -> EngineState {
        EngineState(macs: macs, jobs: jobs.values.sorted { $0.ecid < $1.ecid }, dfuPort: dfuPort,
                    charger: charger, restoredPorts: restoredOn.keys.sorted())
    }

    public func job(_ ecid: ECID) -> Job? { jobs[ecid] }

    /// Reads USB and the ports. A failed scan changes nothing.
    @discardableResult
    public func refresh() async -> Bool {
        charger = await bench.chargerConnected()
        for port in config.ports {
            if await bench.portActive(port) == false { restoredOn[port] = nil }
        }
        guard let scanned = await bench.usbMacs() else { return false }
        apply(scanned, at: await clock.now())
        return true
    }

    private func apply(_ scanned: [USBMac], at now: Double) {
        if scanned != macs { onEvent(.macs(scanned)) }
        macs = scanned
        let seen = Dictionary(scanned.map { ($0.ecid, $0) }, uniquingKeysWith: { first, _ in first })
        for mac in scanned where jobs[mac.ecid] == nil { jobs[mac.ecid] = Job(ecid: mac.ecid) }
        for ecid in jobs.keys {
            update(ecid) { job in
                let mac = seen[ecid]
                job.mode = mac?.mode
                job.port = mac?.port
                if let serial = mac?.serial { job.serial = serial }
            }
            guard let job = jobs[ecid], job.phase == .rebooting else { continue }
            if seen[ecid]?.mode == .normal {
                bootDeadline[ecid] = nil
                update(ecid) { $0.phase = .done; $0.step = nil; $0.progress = nil }
            } else if let deadline = bootDeadline[ecid], now > deadline {
                bootDeadline[ecid] = nil
                update(ecid) { $0.phase = .failed; $0.error = "Restored, but it didn't start up again." }
            }
        }
        // A queued Mac that left DFU (unplugged, or rebooted) can't restore from there.
        for ecid in queue where seen[ecid]?.mode != .dfu {
            dequeue(ecid)
            update(ecid) { $0.phase = .failed; $0.error = "Left DFU before its restore started." }
        }
        pump()
    }

    // MARK: DFU

    /// Why DFU on `port` isn't safe now, or nil. `expect`: the caller's Mac must be the only
    /// one on that port (fail closed: the signal goes to whatever is there).
    public func dfuRefusal(port: Int, expect: ECID? = nil) -> Refusal? {
        guard config.ports.contains(port) else { return Refusal(.unknownPort, "No DFU port \(port) on this host.") }
        if closed { return Refusal(.shuttingDown, "The engine is stopping.") }
        if dfuPort != nil { return Refusal(.dfuRunning, "A DFU run is already going.") }
        if jobs.values.contains(where: { $0.phase == .restoring && ($0.restorePort == port || $0.port == port) }) {
            return Refusal(.portRestoring, "A Mac is restoring on port \(port).")
        }
        if jobs.values.contains(where: { $0.phase == .rebooting && ($0.restorePort == port || $0.port == port) }) {
            return Refusal(.portJustRestored, "A just-restored Mac is starting up on port \(port).")
        }
        let here = macs.filter { $0.port == port }
        if here.count > 1 { return Refusal(.notAlone, "More than one Mac is on port \(port).") }
        if let mac = here.first, mac.mode == .dfu {
            return Refusal(.portHasDFUMac, "The Mac on port \(port) is already in DFU.")
        }
        // The restored Mac may be off and invisible; only another Mac on that cable shows it left.
        if let restored = restoredOn[port], here.first.map({ $0.ecid == restored }) ?? true {
            return Refusal(.portJustRestored, "The Mac on port \(port) was just restored. Unplug it first.")
        }
        if let expect {
            guard let mac = here.first else { return Refusal(.notOnPort, "\(expect) isn't on port \(port).") }
            if mac.ecid != expect { return Refusal(.wrongMac, "Another Mac (\(mac.ecid)) is on port \(port).") }
            if jobs[expect]?.isActive == true { return Refusal(.alreadyActive, "\(expect) is already being worked on.") }
        }
        return nil
    }

    /// Sends DFU on `port` and waits for a Mac in DFU there. Reads USB afresh first.
    public func dfu(port: Int, expect: ECID? = nil) async throws(Refusal) -> DFUResult {
        if let refusal = dfuRefusal(port: port, expect: expect) { throw refusal }
        dfuPort = port
        defer {
            dfuPort = nil
            pump()
        }
        guard await refresh() else { throw Refusal(.scanFailed, "Couldn't read USB.") }
        // The world may have moved while USB was read.
        dfuPort = nil
        if let refusal = dfuRefusal(port: port, expect: expect) { throw refusal }
        dfuPort = port

        // No Mac on USB is fine: a Mac that's off isn't on USB but takes the signal.
        let target = macs.first { $0.port == port }.map(\.ecid)
        let before = target.flatMap { jobs[$0]?.phase }
        if let target { update(target) { $0.phase = .enteringDFU; $0.error = nil } }
        onEvent(.dfuStarted(port: port))

        var outcome = await door.enterDFU(port: port)
        var appeared: ECID?
        if outcome == .inDFU || outcome == .sentNotSeen {
            appeared = await waitForDFU(on: port)
            outcome = appeared == nil ? .sentNotSeen : .inDFU
        }
        if let target, jobs[target]?.phase == .enteringDFU {
            // In DFU now: ready for a restore. Otherwise back to how it was.
            update(target) { $0.phase = appeared == target ? .connected : before ?? .connected }
        }
        let result = DFUResult(port: port, outcome: outcome, ecid: appeared)
        onEvent(.dfuFinished(result))
        if let expect, let appeared, appeared != expect {
            throw Refusal(.wrongMac, "Another Mac (\(appeared)) went into DFU on port \(port).")
        }
        return result
    }

    private func waitForDFU(on port: Int) async -> ECID? {
        let deadline = await clock.now() + config.dfuAppearWait
        while true {
            if await refresh(), let mac = macs.first(where: { $0.port == port && $0.mode == .dfu }) { return mac.ecid }
            if await clock.now() >= deadline { return nil }
            await clock.sleep(config.poll)
        }
    }

    // MARK: Restore

    /// Queues a restore of a Mac that is in DFU now. It starts when a slot is free.
    @discardableResult
    public func restore(_ ecid: ECID, ipsw: IPSWImage) throws(Refusal) -> Job {
        if closed { throw Refusal(.shuttingDown, "The engine is stopping.") }
        guard let job = jobs[ecid], let mac = macs.first(where: { $0.ecid == ecid }) else {
            throw Refusal(.unknownMac, "\(ecid) isn't on USB.")
        }
        guard !job.isActive else { throw Refusal(.alreadyActive, "\(ecid) is already being worked on.") }
        // Restores begun from recovery or restore mode failed; only DFU works.
        guard mac.mode == .dfu else { throw Refusal(.notInDFU, "\(ecid) isn't in DFU (it's in \(mac.mode.rawValue) mode).") }
        guard dfuPort != mac.port else { throw Refusal(.dfuRunning, "A DFU run is going on port \(mac.port).") }
        var isDirectory: ObjCBool = false
        guard ipsw.path.hasPrefix("/"), FileManager.default.fileExists(atPath: ipsw.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { throw Refusal(.noIPSW, "No restore image at \(ipsw.path).") }
        update(ecid) { job in
            job.phase = .queued
            job.solo = job.failures > 0
            job.ipsw = ipsw
            job.error = nil
            job.step = nil
            job.progress = nil
        }
        queue.append(ecid)
        pump()
        return jobs[ecid] ?? job
    }

    /// Takes a Mac out of the restore queue. A running restore can't be cancelled: killing
    /// cfgutil mid-restore leaves a Mac that needs DFU again.
    public func cancel(_ ecid: ECID) throws(Refusal) {
        guard jobs[ecid]?.phase == .queued else { throw Refusal(.notQueued, "\(ecid) isn't waiting for a restore.") }
        dequeue(ecid)
        update(ecid) { $0.phase = .connected }
    }

    /// Forgets finished Macs that are no longer on USB.
    public func clearFinished() {
        for (ecid, job) in jobs where !job.isActive && job.mode == nil { jobs[ecid] = nil }
    }

    /// No new work from now on. Running restores carry on; true once none are left.
    public func close() -> Bool {
        closed = true
        for ecid in queue {
            update(ecid) { $0.phase = .connected }
        }
        queue = []
        return !jobs.values.contains { $0.phase == .restoring }
    }

    public var restoring: Int { jobs.values.filter { $0.phase == .restoring }.count }

    private func pump() {
        guard !closed else { return }
        let running = jobs.values.filter { $0.phase == .restoring }
        if running.contains(where: \.solo) { return }
        let ready = queue.filter { ecid in
            let mac = macs.first { $0.ecid == ecid }
            return mac?.mode == .dfu && mac?.port != dfuPort
        }
        // Retries run alone: wait for the rest to finish and start nothing new meanwhile.
        if let solo = queue.first(where: { jobs[$0]?.solo == true }) {
            if running.isEmpty, ready.contains(solo) { start(solo) }
            return
        }
        var slots = config.maxRestores - running.count
        for ecid in ready where slots > 0 {
            start(ecid)
            slots -= 1
        }
    }

    private func dequeue(_ ecid: ECID) { queue.removeAll { $0 == ecid } }

    private func start(_ ecid: ECID) {
        guard let ipsw = jobs[ecid]?.ipsw else { return }
        dequeue(ecid)
        let run = (runs[ecid] ?? 0) + 1
        runs[ecid] = run
        update(ecid) { job in
            job.phase = .restoring
            job.restorePort = job.port
            job.step = "Starting"
            job.progress = 0
        }
        let stream = bench.restore(ecid: ecid, ipsw: ipsw)
        Task {
            var ended = false
            for await event in stream {
                if case .succeeded = event { ended = true }
                if case .failed = event { ended = true }
                await self.handle(event, ecid: ecid, run: run)
            }
            if !ended { await self.handle(.failed("cfgutil ended without a result."), ecid: ecid, run: run) }
        }
    }

    private func handle(_ event: RestoreEvent, ecid: ECID, run: Int) async {
        guard runs[ecid] == run, jobs[ecid]?.phase == .restoring else { return }
        switch event {
        case .step(let step): update(ecid) { $0.step = step; $0.progress = 0 }
        case .progress(let value): update(ecid) { $0.progress = value }
        case .succeeded:
            if let port = jobs[ecid]?.restorePort { restoredOn[port] = ecid }
            bootDeadline[ecid] = await clock.now() + config.bootWait
            update(ecid) { job in
                job.phase = .rebooting
                job.failures = 0
                job.solo = false
                job.step = nil
                job.progress = nil
            }
            pump()
        case .failed(let message):
            update(ecid) { job in
                job.phase = .failed
                job.failures += 1
                job.error = message
            }
            pump()
        }
    }

    private func update(_ ecid: ECID, _ change: (inout Job) -> Void) {
        guard var job = jobs[ecid] else { return }
        let old = job
        change(&job)
        jobs[ecid] = job
        if job != old { onEvent(.job(job)) }
    }
}
