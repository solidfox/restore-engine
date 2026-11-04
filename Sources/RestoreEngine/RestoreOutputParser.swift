import Foundation

/// What one cfgutil restore reports.
public enum RestoreEvent: Equatable, Sendable {
    case step(String)
    /// The current step's progress, 0…1.
    case progress(Double)
    case succeeded
    case failed(String)
}

/// Turns `cfgutil -e <ECID> --progress restore -I <ipsw>` output into events, a line at a
/// time. Success needs exit 0 and cfgutil's "Restored System on" line, and no
/// `"restore" failed on` line: an exit 0 alone isn't trusted.
public final class RestoreOutputParser: @unchecked Sendable {
    private var lastStep: String?
    private var error: String?
    private var sawSuccess = false
    private var sawFailure = false

    public init() {}

    public func feed(_ rawLine: String) -> [RestoreEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if let step = value(of: "Step", in: line) {
            guard step != lastStep else { return [] }
            lastStep = step
            return [.step(step)]
        }
        if let text = value(of: "Progress", in: line), let progress = Double(text) {
            // cfgutil sends -1 when a step completes.
            return progress >= 0 ? [.progress(min(progress, 1))] : []
        }
        if line.hasPrefix("cfgutil: error: ") {
            error = String(line.dropFirst("cfgutil: error: ".count))
        } else if line.hasPrefix("(Domain: "), let current = error {
            error = current + " " + line
        } else if line.contains("Restored System on") {
            sawSuccess = true
        } else if line.contains("\"restore\" failed on") {
            sawFailure = true
        }
        return []
    }

    public func finish(exitStatus: Int32) -> RestoreEvent {
        if exitStatus == 0, sawSuccess, !sawFailure { return .succeeded }
        return .failed(error ?? "cfgutil exited with status \(exitStatus).")
    }

    /// `Step = "Waiting for the device";` / `Progress = "0.5";` / `Progress = 0;`
    private func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key) = "), line.hasSuffix(";") else { return nil }
        var value = line.dropFirst(key.count + 3).dropLast()
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
        return String(value)
    }
}
