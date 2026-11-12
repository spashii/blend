import BlendKitCore
import Foundation
import Observation

/// Owns the C++ engine. Every preset change sends the whole configuration. Status is read
/// every 100 ms while an app reads a mix or a mix is checked, and otherwise only when a view
/// opens or the engine reports a change (StatusPolling). None of these calls wait on the
/// engine's work.
@MainActor
@Observable
final class EngineBridge {
    private(set) var statuses: [String: MixStatus] = [:]
    private(set) var lastError: String?

    @ObservationIgnored nonisolated(unsafe) private let engine: OpaquePointer
    @ObservationIgnored private var polling: StatusPolling?
    @ObservationIgnored private let encoder = JSONEncoder()
    /// When each live source last carried anything but exact zeros, by mix and position.
    @ObservationIgnored private var lastSound: [String: Date] = [:]
    static let silenceWarning: TimeInterval = 3

    init() {
        engine = BlendEngineCreate()
        polling = StatusPolling(
            read: { [weak self] in self?.poll() ?? false },
            quiet: { [weak self] in self?.dropLevels() })
        // The engine calls this on the main queue.
        BlendEngineSetObserver(engine) { [weak self] in
            MainActor.assumeIsolated { self?.polling?.changed() }
        }
    }

    deinit {
        BlendEngineDestroy(engine)
    }

    /// The panel or the settings window opened.
    func viewOpened() {
        polling?.viewOpened()
    }

    func apply(_ mixes: [Mix]) {
        struct Config: Encodable {
            let mixes: [Mix]
        }
        guard let data = try? encoder.encode(Config(mixes: mixes.map(\.forEngine))),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        var error = [CChar](repeating: 0, count: 512)
        lastError = BlendEngineApply(engine, json, &error, error.count) ? nil : Self.string(error)
    }

    /// Runs one mix for a check; live also plays it to the current output.
    func startCheck(_ mixID: String, live: Bool) {
        BlendEngineStartCheck(engine, mixID, live)
        polling?.setChecking(true)
    }

    func stopCheck() {
        BlendEngineStopCheck(engine)
        polling?.setChecking(false)
    }

    /// What a mix carried since its check started, as interleaved stereo at 48 kHz.
    func checkRecording(_ mixID: String, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * 48000) * 2)
        let frames = BlendEngineCopyCheck(engine, mixID, &samples, samples.count / 2)
        return Array(samples.prefix(frames * 2))
    }

    /// App copies being metered for the source picker, in the order levels come back.
    @ObservationIgnored private var probed: [String] = []

    func probe(_ apps: [RunningApp]) {
        let ids = apps.map(\.id)
        guard ids != probed else { return }
        probed = ids
        struct Probe: Encodable {
            let bundleID: String
            let instance: String?
        }
        let list = apps.map { Probe(bundleID: $0.bundleID, instance: $0.instance) }
        guard let data = try? encoder.encode(list), let json = String(data: data, encoding: .utf8) else {
            return
        }
        var error = [CChar](repeating: 0, count: 256)
        _ = BlendEngineSetProbes(engine, json, &error, error.count)
    }

    func probeLevels() -> [String: Float] {
        var levels = [Float](repeating: 0, count: probed.count)
        let count = BlendEngineProbeLevels(engine, &levels, levels.count)
        return Dictionary(uniqueKeysWithValues: zip(probed, levels.prefix(count)))
    }

    /// Silences a probed copy's own output while on, so you hear which one it is.
    func silence(_ app: RunningApp, _ on: Bool) {
        if let index = probed.firstIndex(of: app.id) {
            BlendEngineMuteProbe(engine, index, on)
        }
    }

    func diagnostics() -> String {
        guard let text = BlendEngineDiagnostics(engine) else {
            return ""
        }
        defer { free(text) }
        return String(cString: text)
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func string(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Reads the engine's status and says whether any app is reading a mix.
    private func poll() -> Bool {
        var raw = [BlendMixStatus](repeating: BlendMixStatus(), count: 16)
        let count = BlendEngineStatus(engine, &raw, raw.count)
        var next: [String: MixStatus] = [:]
        let now = Date()
        var heard: [String: Date] = [:]
        for status in raw.prefix(count) {
            let id = Self.cString(status.id)
            let sources = withUnsafeBytes(of: status.sourcePeaks) { bytes in
                Array(bytes.bindMemory(to: Float.self).prefix(Int(status.sourceCount)))
            }
            let live = withUnsafeBytes(of: status.sourceLive) { bytes in
                Array(bytes.bindMemory(to: Bool.self).prefix(Int(status.sourceCount)))
            }
            let users = withUnsafeBytes(of: status.users) { bytes in
                (0..<Int(status.userCount)).map { index in
                    let row = bytes[(index * 64)..<(index * 64 + 64)]
                    return String(decoding: row.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            var silent: [Bool] = []
            for (index, value) in sources.enumerated() {
                let key = "\(id)#\(index)"
                guard live.indices.contains(index), live[index] else {
                    silent.append(false)
                    continue
                }
                let last = value > 0 ? now : lastSound[key] ?? now
                heard[key] = last
                silent.append(now.timeIntervalSince(last) >= Self.silenceWarning)
            }
            // Meters fall back slowly so short peaks stay visible.
            let previous = statuses[id]
            let decayed = sources.enumerated().map { index, value in
                let before = previous.map { $0.sourcePeaks.indices.contains(index) ? $0.sourcePeaks[index] : 0 } ?? 0
                return max(value, before * 0.8)
            }
            next[id] = MixStatus(deviceReady: status.deviceReady, running: status.running,
                users: users, peak: max(status.peak, (previous?.peak ?? 0) * 0.8),
                sourcePeaks: decayed, sourceLive: live, sourceSilent: silent)
        }
        lastSound = heard
        if next != statuses {
            statuses = next
        }
        return next.values.contains { $0.running }
    }

    private func dropLevels() {
        let quiet = statuses.mapValues(\.withoutLevels)
        if quiet != statuses {
            statuses = quiet
        }
    }
}
