import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle: it reads the appcast through apps.firstversion.in, checks each
/// update against the signing key in Info.plist, and asks before installing unless automatic
/// updates are on. On the second launch it asks whether to check automatically; nothing else
/// in Blend goes online.
@MainActor
@Observable
final class Updates {
    /// Sparkle keeps its delegate weakly, so it lives here.
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way.
    private(set) var canCheck = false
    var automatic: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automatic }
    }

    /// `idle` says whether Blend can quit for an update right now, reading only observable
    /// state, so a change to its answer can be observed.
    init(idle: @escaping @MainActor () -> Bool) {
        delegate = UpdaterDelegate(idle: idle)
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        automatic = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        // Sparkle changes both on the main thread.
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            // Sparkle's own first-run question changes this behind the toggle's back.
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    if self?.automatic != value { self?.automatic = value }
                }
            },
        ]
    }

    func check() {
        controller.checkForUpdates(nil)
    }
}

/// Sparkle's delegate. Sparkle calls it on the main thread, where Blend's state lives.
@MainActor
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let whenIdle: WhenIdle

    init(idle: @escaping @MainActor () -> Bool) {
        whenIdle = WhenIdle(idle)
    }

    /// Marks update checks from the owner's own Macs (`defaults write app.blend.Blend OwnerMac
    /// -bool YES`) with `self=1` on the appcast URL, so the counts on apps.firstversion.in can leave
    /// them out. Everyone else's checks carry no parameters; system profiling stays off.
    nonisolated func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        UserDefaults.standard.bool(forKey: "OwnerMac") ? [["key": "self", "value": "1"]] : []
    }

    /// With automatic updates on, Sparkle downloads an update and installs it when Blend
    /// quits, but Blend runs until logout, so an update could wait for days. Blend takes the
    /// install over and runs it once no app is using a mix: Sparkle then quits Blend, installs
    /// the update and opens it again, and no one loses sound in the middle of a call. If that
    /// quit is cancelled, the handler works again at the next return to idle.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        whenIdle.run(immediateInstallHandler)
        return true
    }
}
