import Foundation
import Testing
@testable import RestoreEngine

/// Instant time for one task at a time: sleeping moves the clock on.
actor VirtualClock: EngineClock {
    private(set) var time: Double = 0
    func now() -> Double { time }
    func sleep(_ seconds: Double) { time += max(seconds, 0) }
}

/// Real time, sped up: one clock second is `scale` real seconds. For tests where
/// several tasks sleep at once (restores running side by side).
struct FastClock: EngineClock {
    var scale = 0.005
    func now() async -> Double { Date().timeIntervalSince1970 / scale }
    func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * scale * 1_000_000_000))
    }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [EngineEvent] = []
    func add(_ event: EngineEvent) { lock.lock(); all.append(event); lock.unlock() }
    var list: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return all }
}

/// A restore image file the engine accepts. Synthetic: an empty file.
func makeIPSW() throws -> IPSWImage {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("restore-engine-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = folder.appendingPathComponent("UniversalMac_27.2_26B123_Restore.ipsw").path
    FileManager.default.createFile(atPath: path, contents: Data())
    return IPSWImage(path: path)!
}

/// Refreshes until `condition` holds (clock-independent real timeout).
func eventually(_ engine: Engine, timeout: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: @Sendable (EngineState) -> Bool) async {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        await engine.refresh()
        if condition(await engine.state()) { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Timed out; state: \(await engine.state())", sourceLocation: sourceLocation)
}

extension EngineState {
    func phase(_ ecid: ECID) -> JobPhase? { jobs.first { $0.ecid == ecid }?.phase }
    func job(_ ecid: ECID) -> Job? { jobs.first { $0.ecid == ecid } }
}

// Synthetic identities only.
let macA = ECID(0xA000_0000_0001)
let macB = ECID(0xB000_0000_0002)
let macC = ECID(0xC000_0000_0003)
