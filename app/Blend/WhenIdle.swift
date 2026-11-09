import Observation

/// Runs an action once a condition holds: right away if it already does, otherwise at the
/// next change that makes it hold. The condition must read only observable state; it is read
/// again when that state changes, never on a timer. The action runs again at each later return
/// to idle, in case what it started was called off.
@MainActor
final class WhenIdle {
    private let idle: @MainActor () -> Bool
    private var action: (() -> Void)?
    private var wasIdle = false

    init(_ idle: @escaping @MainActor () -> Bool) {
        self.idle = idle
    }

    func run(_ action: @escaping () -> Void) {
        self.action = action
        wasIdle = false
        evaluate()
    }

    private func evaluate() {
        guard let action else { return }
        let idleNow = withObservationTracking { idle() } onChange: { [weak self] in
            // Called just before the change lands, so look once it has.
            Task { @MainActor in self?.evaluate() }
        }
        if idleNow && !wasIdle {
            action()
        }
        wasIdle = idleNow
    }
}
