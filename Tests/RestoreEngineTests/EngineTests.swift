import Foundation
import Testing
@testable import RestoreEngine

// Restores overlap in time, so these run one at a time.
@Suite(.serialized) final class EngineTests {
    let ipsw: IPSWImage

    init() throws { ipsw = try makeIPSW() }
    deinit { try? FileManager.default.removeItem(atPath: (ipsw.path as NSString).deletingLastPathComponent) }

    func makeEngine(_ macs: [SimulatedHost.Mac], restoreSeconds: Double = 4, events: Events = Events(),
                    configure: (inout EngineConfig) -> Void = { _ in }) async -> (Engine, SimulatedHost) {
        let clock = FastClock()
        let host = SimulatedHost(clock: clock, macs: macs)
        await host.setRestoreSeconds(restoreSeconds)
        var config = EngineConfig()
        config.bootWait = 60
        configure(&config)
        let engine = Engine(config: config, bench: host.bench, door: host.door(), clock: clock, onEvent: events.add)
        await engine.refresh()
        return (engine, host)
    }

    func mac(_ ecid: ECID, port: Int, mode: MacMode? = .normal) -> SimulatedHost.Mac {
        .init(ecid: ecid, serial: "SIMSERIAL0\(port)", port: port, mode: mode)
    }

    /// The refusal code `body` threw, or nil if it didn't throw.
    func refusal(_ body: () async throws -> Void) async -> RefusalCode? {
        do { try await body(); return nil } catch { return (error as? Refusal)?.code }
    }

    @Test func dFUThenRestoreThenBoot() async throws {
        let events = Events()
        let (engine, host) = await makeEngine([mac(macA, port: 0)], events: events)
        let result = try await engine.dfu(port: 0, expect: macA)
        #expect(result == DFUResult(port: 0, outcome: .inDFU, ecid: macA))
        let afterDFU = await engine.state()
        #expect(afterDFU.phase(macA) == .connected)
        #expect(afterDFU.macs.first?.mode == .dfu)

        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .done }
        #expect(await host.mac(macA)?.mode == .normal)
        let state = await engine.state()
        #expect(state.restoredPorts == [0])
        #expect(state.job(macA)?.startedUp == true)
        #expect(events.list.contains(.dfuStarted(port: 0)))
        #expect(events.list.contains { if case .job(let job) = $0 { job.phase == .restoring } else { false } })

        // The restored Mac is still on its cable: no second DFU until it's unplugged.
        let again = await refusal { _ = try await engine.dfu(port: 0) }
        #expect(again == .portJustRestored)
        await host.unplug(macA)
        await engine.refresh()
        await host.add(mac(macB, port: 0, mode: nil))
        let next = try await engine.dfu(port: 0)
        #expect(next.ecid == macB)
    }

    @Test func dFURefusals() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0), mac(macB, port: 0), mac(macC, port: 1, mode: .dfu)])
        var code = await refusal { _ = try await engine.dfu(port: 7) }
        #expect(code == .unknownPort)
        code = await refusal { _ = try await engine.dfu(port: 0) }
        #expect(code == .notAlone)
        code = await refusal { _ = try await engine.dfu(port: 1) }
        #expect(code == .portHasDFUMac)
        code = await refusal { _ = try await engine.dfu(port: 2, expect: macA) }
        #expect(code == .notOnPort)
        await host.unplug(macB)
        await engine.refresh()
        code = await refusal { _ = try await engine.dfu(port: 0, expect: macB) }
        #expect(code == .wrongMac)

        // Scan failure: refuse, don't guess.
        await host.setScanFails(true)
        code = await refusal { _ = try await engine.dfu(port: 0, expect: macA) }
        #expect(code == .scanFailed)
        #expect(await engine.state().dfuPort == nil)
        await host.setScanFails(false)
        #expect(await engine.state().phase(macA) == .connected)
    }

    @Test func oneDFURunAtATime() async throws {
        // Swap + replug: the run takes ~10 clock seconds, long enough to overlap.
        let (engine, _) = await makeEngine([mac(macA, port: 0), mac(macB, port: 1)])
        async let first = engine.dfu(port: 0)
        try await Task.sleep(nanoseconds: 10_000_000)
        let code = await refusal { _ = try await engine.dfu(port: 1) }
        #expect(code == .dfuRunning)
        let result = try await first
        #expect(result.outcome == .inDFU)
    }

    @Test func sinkLeavesTheMacAlone() async throws {
        var stubborn = mac(macA, port: 0)
        stubborn.refusesSwap = true
        let (engine, host) = await makeEngine([stubborn])
        let result = try await engine.dfu(port: 0, expect: macA)
        #expect(result.outcome == .sink)
        #expect(result.ecid == nil)
        #expect(await engine.state().phase(macA) == .connected)
        #expect(await host.mac(macA)?.mode == .normal)
    }

    @Test func restoreRefusals() async throws {
        let (engine, _) = await makeEngine([mac(macA, port: 0), mac(macB, port: 1, mode: .dfu)])
        var code = await refusal { try await engine.restore(macA, ipsw: self.ipsw) }
        #expect(code == .notInDFU)
        code = await refusal { try await engine.restore(macC, ipsw: self.ipsw) }
        #expect(code == .unknownMac)
        let missing = IPSWImage(path: "/nonexistent/UniversalMac_27.2_26B123_Restore.ipsw")!
        code = await refusal { try await engine.restore(macB, ipsw: missing) }
        #expect(code == .noIPSW)
        let relative = IPSWImage(path: "UniversalMac_27.2_26B123_Restore.ipsw")!
        code = await refusal { try await engine.restore(macB, ipsw: relative) }
        #expect(code == .noIPSW)
        try await engine.restore(macB, ipsw: ipsw)
        code = await refusal { try await engine.restore(macB, ipsw: self.ipsw) }
        #expect(code == .alreadyActive)
        // A restoring Mac's port is off limits.
        await eventually(engine) { $0.phase(macB) == .restoring }
        code = await refusal { _ = try await engine.dfu(port: 1) }
        #expect(code == .portRestoring)
    }

    @Test func atMostTwoAtOnce() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0, mode: .dfu), mac(macB, port: 1, mode: .dfu), mac(macC, port: 2, mode: .dfu)],
                                              restoreSeconds: 40)
        for ecid in [macA, macB, macC] { try await engine.restore(ecid, ipsw: ipsw) }
        let started = await engine.state()
        #expect(started.jobs.map(\.phase) == [.restoring, .restoring, .queued])
        await eventually(engine) { state in [macA, macB, macC].allSatisfy { state.phase($0) == .done } }
        #expect(await host.mostRestoresAtOnce == 2)
    }

    @Test func retryRunsAlone() async throws {
        var flaky = mac(macA, port: 0, mode: .dfu)
        flaky.restoreFailures = 1
        let (engine, host) = await makeEngine([flaky, mac(macB, port: 1, mode: .dfu), mac(macC, port: 2, mode: .dfu)],
                                              restoreSeconds: 40)
        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .failed }
        #expect(await engine.state().job(macA)?.failures == 1)
        #expect(await host.mac(macA)?.mode == .recovery)

        // Back to DFU, as the bench would (a fresh DFU run).
        await host.edit(macA) { $0.mode = .dfu }
        await engine.refresh()
        try await engine.restore(macB, ipsw: ipsw)
        try await engine.restore(macA, ipsw: ipsw)
        try await engine.restore(macC, ipsw: ipsw)
        var state = await engine.state()
        #expect(state.job(macA)?.solo == true)
        // B was already running; the retry waits for it, and C waits for the retry.
        #expect([state.phase(macA), state.phase(macB), state.phase(macC)] == [.queued, .restoring, .queued])
        await eventually(engine) { $0.phase(macA) == .restoring }
        state = await engine.state()
        #expect(state.phase(macC) == .queued)
        #expect(state.phase(macB) != .restoring)
        await eventually(engine) { $0.phase(macC) == .restoring }
        #expect(await engine.state().phase(macA) != .restoring)
        await eventually(engine) { state in [macA, macB, macC].allSatisfy { state.phase($0) == .done } }
        #expect(await engine.state().job(macA)?.failures == 0)
    }

    @Test func queuedMacThatLeavesDFUFails() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0, mode: .dfu), mac(macB, port: 1, mode: .dfu), mac(macC, port: 2, mode: .dfu)],
                                              restoreSeconds: 400)
        for ecid in [macA, macB, macC] { try await engine.restore(ecid, ipsw: ipsw) }
        await host.unplug(macC)
        await engine.refresh()
        let job = await engine.state().job(macC)
        #expect(job?.phase == .failed)
        #expect(job?.failures == 0, "it never ran")
    }

    @Test func cancelAndClose() async throws {
        let (engine, _) = await makeEngine([mac(macA, port: 0, mode: .dfu), mac(macB, port: 1, mode: .dfu), mac(macC, port: 2, mode: .dfu)],
                                           restoreSeconds: 40)
        for ecid in [macA, macB, macC] { try await engine.restore(ecid, ipsw: ipsw) }
        var code = await refusal { try await engine.cancel(macA) }
        #expect(code == .notQueued)
        try await engine.cancel(macC)
        #expect(await engine.state().phase(macC) == .connected)
        #expect(!(await engine.close()), "two restores still running")
        code = await refusal { try await engine.restore(macC, ipsw: self.ipsw) }
        #expect(code == .shuttingDown)
        await eventually(engine) { $0.phase(macA) != .restoring && $0.phase(macB) != .restoring }
        #expect(await engine.close())
    }

    @Test func restoreUnpluggedMidwayFails() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0, mode: .dfu)], restoreSeconds: 40)
        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .restoring }
        await host.unplug(macA)
        await eventually(engine) { $0.phase(macA) == .failed }
        #expect(await engine.state().job(macA)?.error?.contains("Code: 9") == true)
    }

    @Test func wire() async throws {
        let (engine, _) = await makeEngine([mac(macA, port: 0, mode: nil)])
        var reply = await WireServer.handle(#"{"id":"1","op":"dfu","port":0}"#, engine: engine)
        #expect(reply.ok == true)
        #expect(reply.dfu?.ecid == macA)
        #expect(reply.line().contains(#""ecid":"0xA00000000001""#))
        reply = await WireServer.handle(#"{"id":"2","op":"restore","ecid":"0xA00000000001","ipsw":"\#(ipsw.path)"}"#, engine: engine)
        #expect(reply.ok == true)
        #expect(reply.job?.ecid == macA)
        reply = await WireServer.handle(#"{"id":"3","op":"restore","ecid":"0xA00000000001","ipsw":"/x/other.ipsw"}"#, engine: engine)
        #expect(reply.refused?.code == .noIPSW)
        reply = await WireServer.handle(#"{"id":"4","op":"dfu"}"#, engine: engine)
        #expect(reply.refused?.code == .badCommand)
        reply = await WireServer.handle("not json", engine: engine)
        #expect(reply.refused?.code == .badCommand)
        reply = await WireServer.handle(#"{"id":"5","op":"state"}"#, engine: engine)
        #expect(reply.state?.jobs.first?.ecid == macA)
        let decoded = try JSONDecoder().decode(WireMessage.self, from: Data(reply.line().utf8))
        #expect(decoded == reply)
    }

    // Workshop's conveyor, and the station's hub: DFU on port 0, move the cable, restore
    // on port 1. Port 0 is free for the next Mac while the first one restores.
    @Test func conveyor() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0)], restoreSeconds: 200) { $0.ports = [0]; $0.restorePorts = [1] }
        _ = try await engine.dfu(port: 0, expect: macA)
        var code = await refusal { try await engine.restore(macA, ipsw: self.ipsw) }
        #expect(code == .restoreOnDFUPort)
        await host.move(macA, to: 1)
        await engine.refresh()
        #expect(await engine.state().macs.first?.mode == .dfu)
        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .restoring }

        await host.add(mac(macB, port: 0))
        let second = try await engine.dfu(port: 0, expect: macB)
        #expect(second.outcome == .inDFU)
        await host.move(macB, to: 1)
        await engine.refresh()
        try await engine.restore(macB, ipsw: ipsw)
        await eventually(engine) { $0.phase(macB) == .restoring }
        #expect(await engine.state().phase(macA) == .restoring)
        #expect(await host.mostRestoresAtOnce == 2)
        // DFU on a port that's not a DFU port is refused.
        code = await refusal { _ = try await engine.dfu(port: 1) }
        #expect(code == .unknownPort)
    }

    @Test func movingARestoringMacKillsIt() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 1, mode: .dfu)], restoreSeconds: 40)
        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .restoring }
        await host.move(macA, to: 2)
        // The port it's on now is locked too: cfgutil hasn't reported yet.
        await engine.refresh()
        if await engine.state().phase(macA) == .restoring {
            let code = await refusal { _ = try await engine.dfu(port: 2) }
            #expect(code == .portRestoring)
        }
        await eventually(engine) { $0.phase(macA) == .failed }
        #expect(await engine.state().job(macA)?.failures == 1)
    }

    @Test func aloneOnRequest() async throws {
        let (engine, _) = await makeEngine([mac(macA, port: 0, mode: .dfu), mac(macB, port: 1, mode: .dfu)], restoreSeconds: 40)
        try await engine.restore(macA, ipsw: ipsw, alone: true)
        try await engine.restore(macB, ipsw: ipsw)
        let state = await engine.state()
        #expect(state.job(macA)?.solo == true)
        #expect(state.phase(macA) == .restoring)
        #expect(state.phase(macB) == .queued)
    }

    @Test func doneWithoutStartingUp() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0, mode: .dfu)]) { $0.bootWait = 4 }
        await host.setStaysOffAfterRestore(true)
        try await engine.restore(macA, ipsw: ipsw)
        await eventually(engine) { $0.phase(macA) == .done }
        let job = await engine.state().job(macA)
        #expect(job?.startedUp == false)
        #expect(job?.failures == 0)
        #expect(job?.error == nil)
    }

    @Test func portsAndModeSince() async throws {
        let (engine, host) = await makeEngine([mac(macA, port: 0), mac(macB, port: 2, mode: nil)])
        var state = await engine.state()
        #expect(state.activePorts == [0, 2])
        #expect(state.unreadablePorts == [])
        let since = state.job(macA)?.modeSince
        #expect(since != nil)
        await host.unplug(macB)
        await engine.refresh()
        state = await engine.state()
        #expect(state.activePorts == [0])
        await engine.refresh()
        #expect(await engine.state().job(macA)?.modeSince == since)
    }
}
