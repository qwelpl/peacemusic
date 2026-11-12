import Foundation
import IOKit.ps
import Observation

// Whether the Mac is running on battery or in Low Power Mode, so animations can slow down.
@MainActor
@Observable
final class PowerState {
    static let shared = PowerState()

    private(set) var isSaving = PowerState.check()

    private init() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let saving = PowerState.check()
                if self?.isSaving != saving { self?.isSaving = saving }
            }
        }
    }

    private static func check() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return source as String == kIOPMBatteryPowerKey
    }
}

// How often the audio visualizers (Halftone, Orbit, Constellation) redraw.
enum FrameRate {
    static let key = "frameRate"
    static let savesBatteryKey = "frameRateSavesBattery"
    static let choices = [15, 30, 60, 120]
    static let standard = 30

    // On battery the rate halves, but never below the lowest choice.
    @MainActor
    static func interval(_ rate: Int, savesBattery: Bool) -> Double {
        let lowest = choices[0]
        let pace = savesBattery && PowerState.shared.isSaving ? max(rate / 2, lowest) : rate
        return 1 / Double(max(pace, lowest))
    }
}
