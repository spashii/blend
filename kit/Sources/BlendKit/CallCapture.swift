import BlendKitCore
import Foundation

public enum EchoCancellation: Sendable {
    case off
    case on
    /// On for a physical microphone (built in, USB, Bluetooth), off for a virtual one, which
    /// often carries what the Mac plays on purpose.
    case automatic
}

public enum Isolation: Sendable {
    case off
    case standard
    case highQuality
}

public struct CallCaptureOptions: Sendable {
    /// Names the capture's queues and the tap, which other apps' audio lists show as
    /// "<label>: <bundle id>".
    public var label: String
    /// The input device by UID; nil follows the default input device, also when it changes.
    public var microphoneUID: String?
    public var echoCancellation: EchoCancellation
    public var isolation: Isolation
    /// The call app.
    public var call: TapTarget
    /// Frames per second of what the capture delivers, fixed for its life.
    public var outputRate: Int

    public init(
        label: String, microphoneUID: String? = nil,
        echoCancellation: EchoCancellation = .automatic, isolation: Isolation = .off,
        call: TapTarget, outputRate: Int = 48000
    ) {
        self.label = label
        self.microphoneUID = microphoneUID
        self.echoCancellation = echoCancellation
        self.isolation = isolation
        self.call = call
        self.outputRate = outputRate
    }
}

public enum CallCaptureError: Error, Sendable {
    /// There is no usable input device.
    case microphoneUnavailable
    /// The microphone works and the call app's audio could not be tapped. Nothing is left
    /// running, so the caller can record the microphone alone.
    case callUnavailable
}

/// Records both sides of a call: the microphone as Me and the call app as Call, mono, at the
/// same instants and one rate. With echo cancellation on, the call is the far end the
/// microphone is cleaned against, and the copy that went into the canceller is what arrives
/// as Call, so the two stay sample-aligned.
///
/// Frames and events arrive on one private serial queue, never on the audio thread. Whatever
/// the devices do (a headset connecting, a rate change, the call app's tap failing), the
/// capture keeps its clock: positions never skip, and time with no audio arrives as silence.
public final class CallCapture: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case microphoneRestarted
        /// The microphone has been missing for 10 seconds. The capture keeps trying.
        case microphoneLost
        /// The call app's audio stopped arriving and could not be rebuilt. Call is silence,
        /// Me continues from the microphone alone, and the capture retries every 2 seconds.
        case callTapLost(reason: String)
        case callTapRestored
        /// The call app has played for 3 seconds and every Call sample is zero, which is
        /// what a revoked System Audio Recording permission looks like.
        case callSilent
        case callHeard
        /// Echo cancellation stopped working; Me continues unprocessed.
        case echoCancellationFailed
        /// The frames closure fell about 4 seconds behind and frames were dropped.
        case overflow
        case audioServiceRestarted
    }

    /// `position` counts output frames since `start()`. The buffers are valid only during
    /// the call and hold the same number of frames each.
    public typealias Frames =
        @Sendable (_ me: UnsafeBufferPointer<Float>, _ call: UnsafeBufferPointer<Float>, _ position: UInt64) -> Void
    public typealias Events = @Sendable (Event) -> Void

    private let handle: OpaquePointer
    private let context: Unmanaged<Context>

    final class Context: @unchecked Sendable {
        let frames: Frames
        let events: Events
        init(frames: @escaping Frames, events: @escaping Events) {
            self.frames = frames
            self.events = events
        }
    }

    public init(
        options: CallCaptureOptions, frames: @escaping Frames, events: @escaping Events
    ) {
        let context = Context(frames: frames, events: events)
        let retained = Unmanaged.passRetained(context)
        self.context = retained
        let echo: BKEchoCancellation
        switch options.echoCancellation {
        case .off: echo = BKEchoCancellationOff
        case .on: echo = BKEchoCancellationOn
        case .automatic: echo = BKEchoCancellationAutomatic
        }
        let isolation: BKIsolation
        switch options.isolation {
        case .off: isolation = BKIsolationOff
        case .standard: isolation = BKIsolationStandard
        case .highQuality: isolation = BKIsolationHighQuality
        }
        // The strings are copied during the call.
        let created: OpaquePointer? = options.label.withCString { label in
            withOptionalCString(options.microphoneUID) { microphone in
                options.call.bundleID.withCString { bundleID in
                    withOptionalCString(options.call.instance) { instance in
                        var c = BKCallCaptureOptions(
                            label: label, microphoneUID: microphone, echo: echo,
                            isolation: isolation, callBundleID: bundleID, callInstance: instance,
                            outputRate: UInt32(max(0, options.outputRate)))
                        return BKCallCaptureCreate(
                            &c, Self.deliverFrames, Self.deliverEvent, retained.toOpaque())
                    }
                }
            }
        }
        // Create fails only for missing arguments, which this initializer always supplies.
        self.handle = created!
    }

    deinit {
        BKCallCaptureDestroy(handle)
        context.release()
    }

    /// Blocks until the capture runs or has failed, which can take a moment: not on the main
    /// thread. On a failure nothing is left running.
    public func start() throws {
        switch BKCallCaptureStart(handle) {
        case BKStartStarted: return
        case BKStartCallUnavailable: throw CallCaptureError.callUnavailable
        default: throw CallCaptureError.microphoneUnavailable
        }
    }

    /// Blocks until the devices have stopped and every frame produced so far has reached the
    /// frames closure. Safe to call from that closure.
    public func stop() {
        BKCallCaptureStop(handle)
    }

    /// A human-readable summary of the capture's state, for support.
    public var diagnostics: String {
        guard let text = BKCallCaptureDiagnostics(handle) else { return "" }
        defer { free(text) }
        return String(cString: text)
    }

    static let deliverFrames: BKFramesCallback = { context, me, call, count, position in
        guard let context, let me, let call else { return }
        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        box.frames(
            UnsafeBufferPointer(start: me, count: Int(count)),
            UnsafeBufferPointer(start: call, count: Int(count)), position)
    }

    static let deliverEvent: BKEventCallback = { context, kind, detail in
        guard let context, let event = Event(kind: kind, detail: detail.map { String(cString: $0) })
        else { return }
        Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().events(event)
    }
}

extension CallCapture.Event {
    init?(kind: BKEventKind, detail: String?) {
        switch kind {
        case BKEventMicrophoneRestarted: self = .microphoneRestarted
        case BKEventMicrophoneLost: self = .microphoneLost
        case BKEventCallTapLost: self = .callTapLost(reason: detail ?? "")
        case BKEventCallTapRestored: self = .callTapRestored
        case BKEventCallSilent: self = .callSilent
        case BKEventCallHeard: self = .callHeard
        case BKEventEchoCancellationFailed: self = .echoCancellationFailed
        case BKEventOverflow: self = .overflow
        case BKEventAudioServiceRestarted: self = .audioServiceRestarted
        default: return nil
        }
    }
}

private func withOptionalCString<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    if let string {
        return string.withCString { body($0) }
    }
    return body(nil)
}
