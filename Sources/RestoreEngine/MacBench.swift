import Foundation

/// Runs a program with a fixed environment, a line at a time, and a hard time limit:
/// TERM, then KILL. The result comes only once the process is gone.
public enum ProcessRunner {
    public static func run(_ path: String, _ arguments: [String], environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                           timeout: Double, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> (status: Int32, output: String, timedOut: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "Could not run \(path): \(error.localizedDescription)", false))
                    return
                }
                let killed = Flag()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    killed.set()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        if process.isRunning { kill(pid, SIGKILL) }
                    }
                }
                var output = ""
                var buffer = Data()
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...index)
                        output += line + "\n"
                        onLine(line)
                    }
                }
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    output += line
                    onLine(line)
                }
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, output, killed.isSet))
            }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}

/// The real bench, as the user: `ioreg`, `pmset` and Apple Configurator's `cfgutil`.
public struct MacBench: Bench {
    public var cfgutil: String
    public var restoreTimeout: Double = 45 * 60

    public init(cfgutil: String = MacBench.findCfgutil()) { self.cfgutil = cfgutil }

    public static func findCfgutil() -> String {
        let candidates = [
            "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil",
            "/usr/local/bin/cfgutil",
            "/opt/homebrew/bin/cfgutil",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    public func usbMacs() async -> [USBMac]? {
        let (status, output, _) = await ProcessRunner.run("/usr/sbin/ioreg", ["-p", "IOUSB", "-w0", "-l"], timeout: 5)
        return status == 0 ? IORegParser.parse(output) : nil
    }

    public func chargerConnected() async -> Bool? {
        let (status, output, _) = await ProcessRunner.run("/usr/bin/pmset", ["-g", "ps"], timeout: 5)
        return status == 0 ? output.contains("'AC Power'") : nil
    }

    public func portActive(_ port: Int) async -> Bool? {
        let (status, output, _) = await ProcessRunner.run("/usr/sbin/ioreg", ["-r", "-n", "hpm\(port)", "-l", "-w0"], timeout: 5)
        return status == 0 ? Self.portActive(hpm: output) : nil
    }

    /// The first `ConnectionActive` under hpmN is its USB-C port; nil if ioreg had none.
    static func portActive(hpm output: String) -> Bool? {
        output.split(separator: "\n").first { $0.contains("\"ConnectionActive\"") }.map { $0.contains("Yes") }
    }

    public func restore(ecid: ECID, ipsw: IPSWImage) -> AsyncStream<RestoreEvent> {
        let arguments = ["-e", ecid.description, "--progress", "restore", "-I", ipsw.path]
        let (cfgutil, timeout) = (cfgutil, restoreTimeout)
        return AsyncStream { continuation in
            Task.detached {
                let parser = RestoreOutputParser()
                let (status, _, timedOut) = await ProcessRunner.run(cfgutil, arguments, timeout: timeout) { line in
                    for event in parser.feed(line) { continuation.yield(event) }
                }
                continuation.yield(timedOut ? .failed("cfgutil took over \(Int(timeout / 60)) minutes and was stopped.")
                                            : parser.finish(exitStatus: status))
                continuation.finish()
            }
        }
    }
}

/// macvdmtool, as root, on one port controller (`MACVDMTOOL_RID`, patched macvdmtool).
public struct ProcessVDMTool: VDMTool {
    public let path: String
    /// One call; a hung macvdmtool is killed.
    public var timeout: Double = 15

    public init(path: String) { self.path = path }

    public func run(_ verb: VDMVerb, port: Int) async -> (status: Int32, output: String) {
        let (status, output, timedOut) = await ProcessRunner.run(
            path, [verb.rawValue],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "MACVDMTOOL_RID": String(port)],
            timeout: timeout)
        return (timedOut ? -2 : status, output)
    }
}

/// The root door through sudo: `sudo -n <tool> dfu --port N`, one JSON line back.
/// The sudoers line allows exactly that tool, and the tool takes nothing else from us.
public struct SudoDFUDoor: DFUDoor {
    public let tool: String

    public init(tool: String) { self.tool = tool }

    public func enterDFU(port: Int) async -> DFUOutcome {
        let (_, output, timedOut) = await ProcessRunner.run("/usr/bin/sudo", ["-n", tool, "dfu", "--port", String(port)], timeout: 120)
        if timedOut { return .timedOut }
        return RootReply.parse(output)?.outcome ?? .unavailable
    }
}

/// What `restore-engine-dfu` prints: one JSON line.
public struct RootReply: Codable, Equatable, Sendable {
    public var outcome: DFUOutcome
    public var message: String?

    public init(outcome: DFUOutcome, message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }

    /// The last line that decodes.
    public static func parse(_ output: String) -> RootReply? {
        for line in output.split(separator: "\n").reversed() {
            if let reply = try? JSONDecoder().decode(RootReply.self, from: Data(line.utf8)) { return reply }
        }
        return nil
    }

    /// Exit statuses, for shells and sudo logs.
    public var exitStatus: Int32 {
        switch outcome {
        case .inDFU, .sentNotSeen: 0
        case .sink: 3
        case .noReply: 4
        case .wrongTargetPort: 5
        case .busy: 6
        case .unavailable: 7
        case .timedOut: 8
        }
    }
}
