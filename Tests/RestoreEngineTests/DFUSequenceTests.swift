import Foundation
import Testing
@testable import RestoreEngine

@Suite struct DFUSequenceTests {
    func run(_ host: SimulatedHost, port: Int = 0, clock: VirtualClock = VirtualClock()) async -> DFUOutcome {
        await DFUSequence().run(port: port, tool: host.tool, clock: clock) { await host.bench.usbMacs() }
    }

    @Test func macThatIsOffGoesStraightIn() async {
        let host = SimulatedHost(macs: [.init(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)])
        let outcome = await run(host)
        #expect(outcome == .inDFU)
        let calls = await host.calls
        #expect(calls == ["nop@0", "dfu@0"])
    }

    @Test func macThatIsOnSwapsAndReplugs() async {
        // Powers the host until swapped; once in DFU it only shows after a replug.
        let host = SimulatedHost(macs: [.init(ecid: macA, serial: "SIMSERIAL01", port: 0)])
        let clock = VirtualClock()
        let outcome = await run(host, clock: clock)
        #expect(outcome == .inDFU)
        let calls = await host.calls
        #expect(Array(calls.prefix(4)) == ["nop@0", "swapsource@0", "nop@0", "dfu@0"])
        #expect(calls.last == "replug@0")
        let time = await clock.time
        #expect(time >= 10)
        #expect(time < 30)
    }

    @Test func resendsUntilItTakes() async {
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)
        mac.sendsNeeded = 3
        let host = SimulatedHost(macs: [mac])
        #expect(await run(host) == .inDFU)
        let calls = await host.calls
        #expect(calls.filter { $0 == "dfu@0" }.count == 3)
    }

    @Test func refusedSwapIsSink() async {
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0)
        mac.refusesSwap = true
        let host = SimulatedHost(macs: [mac])
        #expect(await run(host) == .sink)
        let calls = await host.calls
        #expect(!(calls.contains("dfu@0")), "never sends DFU as sink")
    }

    @Test func hostOffChargerIsSink() async {
        let host = SimulatedHost(macs: [.init(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)])
        await host.setCharger(false)
        #expect(await run(host) == .sink)
    }

    @Test func wrongTargetPort() async {
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)
        mac.wrongPort = true
        let host = SimulatedHost(macs: [mac])
        #expect(await run(host) == .wrongTargetPort)
    }

    @Test func nothingOnPort() async {
        let host = SimulatedHost(macs: [.init(ecid: macA, serial: "SIMSERIAL01", port: 1, mode: nil)])
        #expect(await run(host, port: 0) == .noReply)
    }

    @Test func givesUpAfterTheTimeLimit() async {
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)
        mac.sendsNeeded = 1_000
        let host = SimulatedHost(macs: [mac])
        let clock = VirtualClock()
        #expect(await run(host, clock: clock) == .sentNotSeen)
        let time = await clock.time
        #expect(time >= 30)
        #expect(time < 35)
        let calls = await host.calls
        // Off (nothing on USB) with the host as source: it may live on the host's power,
        // so no replug.
        #expect(!calls.contains("replug@0"))
    }

    @Test func swappedMacReplugsUntilTheTimeLimit() async {
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0)
        mac.sendsNeeded = 1_000
        let host = SimulatedHost(macs: [mac])
        let clock = VirtualClock()
        #expect(await run(host, clock: clock) == .sentNotSeen)
        let calls = await host.calls
        // At ~10 s and ~20 s, and a last one at the limit.
        #expect(calls.filter { $0 == "replug@0" }.count == 3)
    }

    @Test func recoveryMacReplugs() async {
        // Already sinking from the host, but on: once in DFU it only shows after a replug.
        let host = SimulatedHost(macs: [.init(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: .recovery)])
        #expect(await run(host) == .inDFU)
        let calls = await host.calls
        #expect(!calls.contains("swapsource@0"))
        #expect(calls.last == "replug@0")
    }

    @Test func lateDFUShowsAfterTheLastReplug() async {
        // Goes into DFU after the 20 s replug: only the replug at the limit shows it.
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0)
        mac.sendsNeeded = 50
        let host = SimulatedHost(macs: [mac])
        #expect(await run(host) == .inDFU)
        let calls = await host.calls
        #expect(calls.filter { $0 == "replug@0" }.count == 3)
    }

    @Test func failedScanStillReplugs() async {
        // A failed scan says nothing about whether the target is on.
        var mac = SimulatedHost.Mac(ecid: macA, serial: "SIMSERIAL01", port: 0, mode: nil)
        mac.sendsNeeded = 1_000
        let host = SimulatedHost(macs: [mac])
        await host.setScanFails(true)
        #expect(await run(host) == .sentNotSeen)
        let calls = await host.calls
        #expect(calls.contains("replug@0"))
    }
}
