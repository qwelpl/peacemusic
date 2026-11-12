import Foundation
import IOKit.pwr_mgt
import Observation

// Holds off display sleep while music plays, when the user asks for it.
@MainActor
final class ScreenAwake {
    static let key = "keepScreenAwake"

    private let store: PlayerStore
    private var assertion: IOPMAssertionID?
    private var defaultsObserver: NSObjectProtocol?

    init(store: PlayerStore) {
        self.store = store
    }

    func start() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        observePlayback()
    }

    private func observePlayback() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayback() }
        }
    }

    private func update() {
        let wanted = UserDefaults.standard.bool(forKey: Self.key) && store.isPlaying
        if wanted, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Peace is playing music" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertion = id }
        } else if !wanted, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
