import Foundation
import QuartzCore

/// How long the main thread has been busy without a break. Something that arrives through the
/// main run loop (an App Remote event) and is timestamped there was really sent up to that long
/// before: after a freeze its time is late, and a clock set from it falls behind the sound.
enum MainThreadPulse {
    /// When the main run loop last woke up (or finished a pass), in `CACurrentMediaTime()` seconds.
    nonisolated(unsafe) private static var passStart: CFTimeInterval = 0
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?

    /// Starts watching the main run loop (main thread, once).
    static func start() {
        guard observer == nil else { return }
        passStart = CACurrentMediaTime()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, _ in
            MainThreadPulse.passStart = CACurrentMediaTime()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    /// Seconds the main thread has been working since it last waited; 0 off the main thread or
    /// before `start()`.
    static var busyFor: Double {
        guard observer != nil, Thread.isMainThread else { return 0 }
        return max(0, CACurrentMediaTime() - passStart)
    }
}
