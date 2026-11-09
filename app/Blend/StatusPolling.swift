import Foundation

/// When Blend reads the engine's status. A Blend view's meters need fresh levels, and while
/// an app reads a mix so do the menu bar icon and the warning for a silent microphone, so
/// then it reads every 100 ms. Otherwise nothing Blend shows can change without the engine
/// saying so (BlendEngineSetObserver), so it stops and reads only on `changed()`: an unused
/// Blend has no timer waking the Mac.
@MainActor
final class StatusPolling {
    private let interval: TimeInterval
    /// Reads the status once and says whether any app is reading a mix.
    private let read: () -> Bool
    /// Clears the levels when polling stops, so a view that opens later never starts from
    /// levels left over from the last read.
    private let quiet: () -> Void
    private var timer: Timer?
    private var viewsOpen = false

    init(interval: TimeInterval = 0.1, read: @escaping () -> Bool, quiet: @escaping () -> Void) {
        self.interval = interval
        self.read = read
        self.quiet = quiet
    }

    var running: Bool {
        timer != nil
    }

    /// Opening reads at once, so the first frame shows current levels.
    func setViewsOpen(_ open: Bool) {
        viewsOpen = open
        update()
    }

    /// The engine changed: a mix started or stopped being read, a device came or went.
    func changed() {
        update()
    }

    private func update() {
        let inUse = read()
        guard viewsOpen || inUse else {
            timer?.invalidate()
            timer = nil
            quiet()
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        // Lets macOS fire it together with other timers, for fewer wakeups while it runs.
        timer?.tolerance = interval / 5
    }
}
