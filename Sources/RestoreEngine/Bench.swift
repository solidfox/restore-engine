import Foundation

/// Everything the engine reads from and does to hardware, as the user. `MacBench` is the
/// real thing; `SimulatedHost.bench` runs with no Macs attached.
public protocol Bench: Sendable {
    /// Macs on USB now, or nil when the scan failed: an unreadable bus is not an empty one.
    func usbMacs() async -> [USBMac]?
    /// The host is on its charger (only then can it be the power source), or nil if unknown.
    func chargerConnected() async -> Bool?
    /// Something is plugged into that USB-C port, or nil if that couldn't be read.
    func portActive(_ port: Int) async -> Bool?
    /// Restores one Mac in DFU from a local IPSW. Always ends with `.succeeded` or `.failed`,
    /// and only once its cfgutil process is gone.
    func restore(ecid: ECID, ipsw: IPSWImage) -> AsyncStream<RestoreEvent>
}

/// The way into root for one DFU run. Each machine has exactly one: an app's XPC helper,
/// or `restore-engine-dfu` through sudo (`SudoDFUDoor`). Both run `DFUSequence`.
public protocol DFUDoor: Sendable {
    func enterDFU(port: Int) async -> DFUOutcome
}
