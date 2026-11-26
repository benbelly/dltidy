import Foundation
import IOKit.ps

/// On battery, or at thermal state serious or worse, long re-encodes wait for AC.
public struct SystemPowerState: PowerState {
    public init() {}

    public func allowLongEncode() -> Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return false }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }
        return source == kIOPMACPowerKey
    }
}
