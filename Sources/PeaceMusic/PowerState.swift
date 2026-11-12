import Foundation
import IOKit.ps
import Observation

// Whether the Mac is running on battery or in Low Power Mode, so animations can slow down.
@MainActor
@Observable
final class PowerState {
    private(set) var isSaving = PowerState.check()

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let saving = PowerState.check()
                if self?.isSaving != saving { self?.isSaving = saving }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func check() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return source as String == kIOPMBatteryPowerKey
    }
}
