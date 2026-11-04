import Foundation

/// `restore-engine serve`: one JSON object per line on stdin (commands) and stdout
/// (replies and events). Commands carry an `id`; the reply echoes it.
///
///     → {"id":"1","op":"dfu","port":0,"expect":"0x1A2B"}
///     ← {"type":"reply","id":"1","ok":true,"dfu":{"port":0,"outcome":"inDFU","ecid":"0x1A2B"}}
///     → {"id":"2","op":"restore","ecid":"0x1A2B","ipsw":"/path/UniversalMac_27.2_26B123_Restore.ipsw"}
///     ← {"type":"reply","id":"2","ok":false,"refused":{"code":"notInDFU","message":"…"}}
///     ← {"type":"job","job":{"ecid":"0x1A2B","phase":"restoring","progress":0.5,…}}
///
/// Ops: `state`, `dfu` (port, expect?), `restore` (ecid, ipsw), `cancel` (ecid), `clear`.
public struct WireCommand: Codable, Equatable, Sendable {
    public var id: String
    public var op: String
    public var port: Int?
    public var expect: ECID?
    public var ecid: ECID?
    public var ipsw: String?

    public init(id: String, op: String, port: Int? = nil, expect: ECID? = nil, ecid: ECID? = nil, ipsw: String? = nil) {
        self.id = id
        self.op = op
        self.port = port
        self.expect = expect
        self.ecid = ecid
        self.ipsw = ipsw
    }
}

public struct WireMessage: Codable, Equatable, Sendable {
    public var type: String
    public var id: String?
    public var ok: Bool?
    public var refused: Refusal?
    public var dfu: DFUResult?
    public var job: Job?
    public var macs: [USBMac]?
    public var state: EngineState?
    public var port: Int?

    init(type: String) { self.type = type }

    public static func reply(_ id: String, ok: Bool) -> WireMessage {
        var message = WireMessage(type: "reply")
        message.id = id
        message.ok = ok
        return message
    }

    public static func event(_ event: EngineEvent) -> WireMessage {
        switch event {
        case .macs(let macs): var m = WireMessage(type: "macs"); m.macs = macs; return m
        case .job(let job): var m = WireMessage(type: "job"); m.job = job; return m
        case .dfuStarted(let port): var m = WireMessage(type: "dfuStarted"); m.port = port; return m
        case .dfuFinished(let result): var m = WireMessage(type: "dfuFinished"); m.dfu = result; return m
        }
    }

    public func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// Runs one command against the engine. Long ones (`dfu`) are awaited here, so the
/// server runs each command in its own task.
public enum WireServer {
    public static func handle(_ line: String, engine: Engine) async -> WireMessage {
        guard let command = try? JSONDecoder().decode(WireCommand.self, from: Data(line.utf8)) else {
            var message = WireMessage.reply("", ok: false)
            message.refused = Refusal(.badCommand, "Not a command: \(line.prefix(200))")
            return message
        }
        func refused(_ refusal: Refusal) -> WireMessage {
            var message = WireMessage.reply(command.id, ok: false)
            message.refused = refusal
            return message
        }
        func missing(_ field: String) -> WireMessage {
            refused(Refusal(.badCommand, "\(command.op) needs \(field)."))
        }
        switch command.op {
        case "state":
            await engine.refresh()
            var message = WireMessage.reply(command.id, ok: true)
            message.state = await engine.state()
            return message
        case "dfu":
            guard let port = command.port else { return missing("port") }
            do {
                var message = WireMessage.reply(command.id, ok: true)
                message.dfu = try await engine.dfu(port: port, expect: command.expect)
                return message
            } catch {
                return refused(error)
            }
        case "restore":
            guard let ecid = command.ecid else { return missing("ecid") }
            guard let path = command.ipsw else { return missing("ipsw") }
            guard let image = IPSWImage(path: path) else {
                return refused(Refusal(.noIPSW, "Not a UniversalMac restore image name: \(path)"))
            }
            do {
                var message = WireMessage.reply(command.id, ok: true)
                message.job = try await engine.restore(ecid, ipsw: image)
                return message
            } catch {
                return refused(error)
            }
        case "cancel":
            guard let ecid = command.ecid else { return missing("ecid") }
            do {
                try await engine.cancel(ecid)
                return .reply(command.id, ok: true)
            } catch {
                return refused(error)
            }
        case "clear":
            await engine.clearFinished()
            return .reply(command.id, ok: true)
        default:
            return refused(Refusal(.badCommand, "No such op: \(command.op)"))
        }
    }
}
