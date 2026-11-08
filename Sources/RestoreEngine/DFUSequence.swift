import Foundation

/// Time, so tests can run a 30 s DFU loop in no time.
public protocol EngineClock: Sendable {
    /// Seconds since some fixed point.
    func now() async -> Double
    func sleep(_ seconds: Double) async
}

public struct SystemClock: EngineClock {
    public init() {}
    public func now() async -> Double { Date().timeIntervalSince1970 }
    public func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// The macvdmtool verbs the DFU sequence uses. `swapsource` and `replug` (and picking the
/// port with `MACVDMTOOL_RID`) need the patched macvdmtool.
public enum VDMVerb: String, Sendable, CaseIterable {
    case nop, dfu, swapsource, replug
}

/// Runs macvdmtool (as root) on one USB-C port controller.
public protocol VDMTool: Sendable {
    func run(_ verb: VDMVerb, port: Int) async -> (status: Int32, output: String)
}

/// How a DFU run on one port went.
public enum DFUOutcome: String, Equatable, Sendable, Codable {
    /// A Mac in DFU showed up on that port.
    case inDFU
    /// `dfu` was sent for the whole time with the host as power source, but no DFU device
    /// showed on that port yet. It often shows a few seconds later: the caller keeps watching.
    case sentNotSeen
    /// `Connection: Sink` even after asking for a power role swap: the target keeps
    /// powering the host (host not on its charger, or the target won't swap).
    case sink
    /// `VDM failed (reply: 0x05ac8092)`: the cable is in the target's wrong port.
    case wrongTargetPort
    /// Nothing answered on that port.
    case noReply
    /// Another DFU run is going on (the root door allows one at a time).
    case busy
    /// The root door couldn't run (missing or untrusted macvdmtool, no helper, bad port).
    case unavailable
    /// The run took too long and was stopped.
    case timedOut
}

/// The fixed DFU sequence: the only thing that ever runs as root. Proven by hand on an
/// Apple-silicon host, 2026-11-02/04:
/// 1. `nop`: a Mac that's on is USB host and powers the host (`Connection: Sink`); only the
///    power source can send DFU, so ask it to swap (`swapsource`) and check again.
/// 2. Resend `dfu` about twice a second: one send often only reboots the target. Stop when a
///    DFU device shows on that port, or after `seconds`.
/// 3. A Mac that was USB host when it went into DFU only shows after the roles are
///    negotiated again: `replug` every 10 s (the port drops for about a second). Only for a
///    target that was on (it needed a swap, or showed on USB, as in recovery): one that
///    showed nothing may be running on the host's power alone (a flat battery), and a
///    replug cuts that power every time.
public struct DFUSequence: Sendable {
    public var seconds: Double = 30
    public var resendEvery: Double = 0.5
    public var replugEvery: Double = 10
    public var afterReplug: Double = 2

    public init() {}

    /// `macOnPort` is the mode of the Mac on that port right now, nil if none shows
    /// (read-only USB scan). The caller refuses to start while one is in DFU already, so a
    /// DFU hit is the target.
    public func run(port: Int, tool: VDMTool, clock: EngineClock,
                    macOnPort: @Sendable (Int) async -> MacMode?,
                    log: @Sendable (String) -> Void = { _ in }) async -> DFUOutcome {
        var nop = await tool.run(.nop, port: port)
        log(nop.output)
        if let early = Self.connectionProblem(nop.output) { return early }
        let swapped = nop.output.contains("Connection: Sink")
        if swapped {
            let swap = await tool.run(.swapsource, port: port)
            log("Asked for the power role (swapsource: \(swap.status))")
            nop = await tool.run(.nop, port: port)
            log(nop.output)
            if nop.output.contains("Connection: Sink") { return .sink }
        }
        guard nop.output.contains("Connection: Source") else {
            return Self.connectionProblem(nop.output) ?? .noReply
        }

        let replugs = swapped ? true : await macOnPort(port) != nil
        let start = await clock.now()
        var replugged = start
        var first = true
        while true {
            let sent = await tool.run(.dfu, port: port)
            if first {
                log(sent.output)
                first = false
                if sent.output.contains("0x05ac8092") { return .wrongTargetPort }
                if sent.output.contains("Did not get a reply") { return .noReply }
            }
            if await macOnPort(port) == .dfu { return .inDFU }
            let now = await clock.now()
            let last = now - start >= seconds
            // Last time round, replug once more: a target that went into DFU after the
            // previous replug would stay hidden, and on a retry it no longer shows on USB.
            if replugs, last || now - replugged >= replugEvery {
                let replug = await tool.run(.replug, port: port)
                log("Replugged (replug: \(replug.status))")
                replugged = now
                await clock.sleep(afterReplug)
                if await macOnPort(port) == .dfu { return .inDFU }
            }
            if last { return .sentNotSeen }
            await clock.sleep(resendEvery)
        }
    }

    static func connectionProblem(_ output: String) -> DFUOutcome? {
        if output.contains("No connection detected") || output.contains("Did not get a reply") { return .noReply }
        if output.contains("0x05ac8092") { return .wrongTargetPort }
        return nil
    }
}
