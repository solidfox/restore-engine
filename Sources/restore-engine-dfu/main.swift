import Foundation
import RestoreEngine

// The only thing that runs as root on a machine without an app helper. Installed
// root-owned next to the patched macvdmtool, allowed to one user by one sudoers line
// for exactly `check` and `dfu --port N`. Takes no paths, environment or other
// arguments from the caller. Prints one JSON line (`RootReply`).
//
//   restore-engine-dfu check        is macvdmtool there and root-owned all the way up?
//   restore-engine-dfu dfu --port N run `DFUSequence` on USB-C port controller N

setvbuf(stdout, nil, _IOLBF, 0)

func reply(_ outcome: DFUOutcome, _ message: String? = nil) -> Never {
    let result = RootReply(outcome: outcome, message: message)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(result)) ?? Data(), as: UTF8.self))
    exit(result.exitStatus)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: restore-engine-dfu check | dfu --port N"

guard geteuid() == 0 else { reply(.unavailable, "Not running as root.") }
guard let me = RootTool.ownExecutable() else { reply(.unavailable, "Can't find myself.") }
if let problem = RootTool.untrusted(me) { reply(.unavailable, problem) }
let tool = ((me as NSString).deletingLastPathComponent as NSString).appendingPathComponent(RootTool.toolName)
if let problem = RootTool.untrusted(tool) { reply(.unavailable, problem) }

switch arguments.first {
case "check" where arguments.count == 1:
    reply(.sentNotSeen, "ok")
case "dfu" where arguments.count == 3 && arguments[1] == "--port":
    guard let port = Int(arguments[2]), RootTool.ports.contains(port) else { reply(.unavailable, "No such port: \(arguments[2]).") }
    // One run per machine. The lock dies with the process, so a run the caller gave up
    // on (sudo killed, the root child still going) still holds it until it ends.
    let lockPath = "/var/run/restore-engine-dfu.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { reply(.unavailable, "Can't open \(lockPath).") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { reply(.busy, "Another DFU run is going.") }

    let box = OutcomeBox()
    let done = DispatchSemaphore(value: 0)
    // Detached: top-level code is on the main actor, and a plain Task would wait for the
    // main thread, which the wait below blocks. It never ran (3MK8, 2026-11-08).
    Task.detached {
        let outcome = await DFUSequence().run(port: port, tool: ProcessVDMTool(path: tool), clock: SystemClock(),
                                              dfuOnPort: { port in
            await MacBench().usbMacs()?.contains { $0.port == port && $0.mode == .dfu } ?? false
        }, log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        box.set(outcome)
        done.signal()
    }
    // The sequence stops itself after 30 s; each macvdmtool call is killed after 15 s.
    if done.wait(timeout: .now() + 90) == .timedOut { reply(.timedOut, "The DFU run hung.") }
    reply(box.get() ?? .unavailable)
default:
    reply(.unavailable, usage)
}

final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DFUOutcome?
    func set(_ outcome: DFUOutcome) { lock.lock(); value = outcome; lock.unlock() }
    func get() -> DFUOutcome? { lock.lock(); defer { lock.unlock() }; return value }
}
