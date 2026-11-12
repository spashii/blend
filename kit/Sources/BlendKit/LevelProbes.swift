import BlendKitCore
import Foundation

/// Meters app copies without capturing them for anything else, for a picker that shows which
/// app is playing. Each probe is a tap of one app's audio, so the System Audio Recording
/// permission applies and the system shows its audio indicator while probes run.
public final class LevelProbes: @unchecked Sendable {
    private let handle: OpaquePointer

    /// The taps are named "<label>: <bundle id>".
    public init(label: String) {
        handle = label.withCString { BKProbesCreate($0)! }
    }

    deinit {
        BKProbesDestroy(handle)
    }

    /// Replaces the probed apps; an empty list stops metering. Blocks until the taps run, so
    /// not on the main thread. An app whose tap cannot start reads as silence and is tried
    /// again when the process list changes.
    public func set(_ targets: [TapTarget]) {
        let rows = targets.map { target -> [String: String] in
            var row = ["bundleID": target.bundleID]
            if let instance = target.instance { row["instance"] = instance }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows),
            let json = String(data: data, encoding: .utf8)
        else { return }
        var error = [CChar](repeating: 0, count: 256)
        _ = BKProbesSet(handle, json, &error, error.count)
    }

    /// Peak level since the previous call for each probed app, in the order given, 0 to 1.
    public func levels() -> [Float] {
        var values = [Float](repeating: 0, count: 64)
        let count = BKProbesLevels(handle, &values, values.count)
        return Array(values.prefix(count))
    }

    /// Silences one probed app's own output while `muted`, so a person can hear which copy is
    /// which.
    public func mute(index: Int, _ muted: Bool) {
        guard index >= 0 else { return }
        BKProbesMute(handle, index, muted)
    }
}
