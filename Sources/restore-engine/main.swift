import Foundation
import RestoreEngine

// `restore-engine serve [--sim] [--dfu-tool PATH] [--ports 0,1,2]`
//     JSON lines on stdin/stdout (see `WireServer`). Runs as the user; DFU goes through
//     `sudo -n <dfu-tool> dfu --port N`. On stdin EOF it takes no new work and exits once
//     no restore is running: closing the pipe never kills a restore.
// `restore-engine status [--sim]`
//     One JSON line: what's on USB now.
//
// `--sim` runs against `SimulatedHost` (no hardware, no sudo): two Macs, one off.

setvbuf(stdout, nil, _IOLBF, 0)

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ message: WireMessage) {
        let line = message.line()
        lock.lock()
        print(line)
        lock.unlock()
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("restore-engine: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let verb = arguments.isEmpty ? "" : arguments.removeFirst()
var sim = false
var dfuTool = "/usr/local/libexec/restore-engine/restore-engine-dfu"
var config = EngineConfig()
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--sim": sim = true
    case "--dfu-tool":
        guard !arguments.isEmpty else { fail("--dfu-tool needs a path") }
        dfuTool = arguments.removeFirst()
    case "--ports":
        guard !arguments.isEmpty else { fail("--ports needs a list") }
        let ports = arguments.removeFirst().split(separator: ",").compactMap { Int($0) }
        guard !ports.isEmpty, ports.allSatisfy(RootTool.ports.contains) else { fail("bad --ports") }
        config.ports = ports
    default: fail("unknown flag \(flag)")
    }
}

let output = Output()
let bench: Bench
let door: DFUDoor
if sim {
    let host = SimulatedHost(macs: [
        .init(ecid: ECID(0x1A2B_3C4D_5E6F), serial: "SIMSERIAL01", port: 0),
        .init(ecid: ECID(0x0F1E_2D3C_4B5A), serial: "SIMSERIAL02", port: 1, mode: nil),
    ])
    bench = host.bench
    door = host.door()
} else {
    bench = MacBench()
    door = SudoDFUDoor(tool: dfuTool)
}

switch verb {
case "status":
    let engine = Engine(config: config, bench: bench, door: door)
    let message = await WireServer.handle(#"{"id":"status","op":"state"}"#, engine: engine)
    output.send(message)
    exit(0)
case "serve":
    break
default:
    fail("usage: restore-engine serve|status [--sim] [--dfu-tool PATH] [--ports 0,1,2]")
}

let engine = Engine(config: config, bench: bench, door: door) { event in output.send(.event(event)) }

let lines = AsyncStream<String> { continuation in
    Thread.detachNewThread {
        while let line = readLine(strippingNewline: true) { continuation.yield(line) }
        continuation.finish()
    }
}

let poller = Task {
    while !Task.isCancelled {
        await engine.refresh()
        try? await Task.sleep(nanoseconds: UInt64(config.poll * 1_000_000_000))
    }
}

await withTaskGroup(of: Void.self) { group in
    for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        group.addTask { output.send(await WireServer.handle(line, engine: engine)) }
    }
    // Let commands already in flight (a DFU run) answer.
    await group.waitForAll()
}

// stdin closed: no new work; wait for running restores, still reporting their events.
while !(await engine.close()) {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
poller.cancel()
exit(0)
