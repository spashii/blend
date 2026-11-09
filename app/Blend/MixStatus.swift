import Foundation

struct MixStatus: Equatable, Sendable {
    var deviceReady = false
    var running = false
    /// Names of the apps reading the mix.
    var users: [String] = []
    var peak: Float = 0
    /// Per source, in the mix's source order.
    var sourcePeaks: [Float] = []
    var sourceLive: [Bool] = []
    /// Captured, but nothing but digital silence for a while: a muted or refused device.
    var sourceSilent: [Bool] = []

    func live(_ index: Int) -> Bool {
        sourceLive.indices.contains(index) && sourceLive[index]
    }

    func silent(_ index: Int) -> Bool {
        sourceSilent.indices.contains(index) && sourceSilent[index]
    }

    func level(_ index: Int) -> Float {
        sourcePeaks.indices.contains(index) ? sourcePeaks[index] : 0
    }
}

extension MixStatus {
    /// Whether Blend can quit and reopen for an update without cutting anyone's sound: no
    /// app is reading any mix, and no check is playing one. "In use" is `running`, the same
    /// test as the "Used by" status and the quit warning.
    static func idle(_ statuses: some Sequence<MixStatus>, checking: Bool) -> Bool {
        !checking && !statuses.contains { $0.running }
    }
}
