import Foundation

/// When Blend reads the engine's status. Levels move only while an app reads a mix or a mix
/// is being checked, and the warning for a silent microphone needs them, so then it reads
/// every 100 ms. Otherwise every level is zero and everything else Blend shows changes only
/// when the engine says so (BlendEngineSetObserver), so it reads only then and when a view
/// opens: an unused Blend has no timer waking the Mac, even with its windows open.
@MainActor
final class StatusPolling {
    private let interval: TimeInterval
    /// Reads the status once and says whether any app is reading a mix.
    private let read: () -> Bool
    /// Clears the levels when polling stops, so a view that opens later never starts from
    /// levels left over from the last read.
    private let quiet: () -> Void
    private var timer: Timer?
    private var checking = false

    init(interval: TimeInterval = 0.1, read: @escaping () -> Bool, quiet: @escaping () -> Void) {
        self.interval = interval
        self.read = read
        self.quiet = quiet
    }

    var running: Bool {
        timer != nil
    }

    /// Reads at once, so the view's first frame is current.
    func viewOpened() {
        update()
    }

    /// A check runs a mix that no app reads, so its levels move.
    func setChecking(_ on: Bool) {
        checking = on
        update()
    }

    /// The engine changed: a mix started or stopped being read, a device came or went.
    func changed() {
        update()
    }

    private func update() {
        let inUse = read()
        guard inUse || checking else {
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
