import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle: it reads the appcast through apps.idea2prod.in, checks each
/// update against the signing key in Info.plist, and asks before installing. On the second
/// launch it asks whether to check automatically; nothing else in Blend goes online.
@MainActor
@Observable
final class Updates {
    /// Sparkle keeps its delegate weakly, so it lives here.
    @ObservationIgnored private let feed: OwnerMarker
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already under way.
    private(set) var canCheck = false
    var automatic: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automatic }
    }

    init() {
        feed = OwnerMarker()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil)
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

/// Marks update checks from the owner's own Macs (`defaults write app.blend.Blend OwnerMac
/// -bool YES`) with `self=1` on the appcast URL, so the counts on apps.idea2prod.in can leave
/// them out. Everyone else's checks carry no parameters; system profiling stays off.
final class OwnerMarker: NSObject, SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        UserDefaults.standard.bool(forKey: "OwnerMac") ? [["key": "self", "value": "1"]] : []
    }
}
