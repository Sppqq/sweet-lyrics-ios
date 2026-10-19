import Foundation
import Observation

/// Tells the UI to go easy on the GPU: when Low Power Mode is on or the phone is getting hot,
/// lyrics drop to 30 fps, line blur turns off and the background stops moving. Already when it
/// is just warm, the lyrics drop to 30 fps so it does not get any hotter.
@Observable
final class PerformanceMonitor {
    private(set) var constrained = false
    /// Warmer than normal (`.fair` or worse) or constrained: 30 fps is enough.
    private(set) var warm = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let hot = info.thermalState == .serious || info.thermalState == .critical
        let value = info.isLowPowerModeEnabled || hot
        if value != constrained { constrained = value }
        let warmer = value || info.thermalState != .nominal
        if warmer != warm { warm = warmer }
    }
}
