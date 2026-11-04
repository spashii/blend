import CoreAudio
import Foundation
import Observation

/// Checks what a mix sounds like, the way Discord's "Let's Check" and Zoom's mic test do.
/// On headphones you hear the mix live until you stop. On speakers, live listening would
/// feed back into the mic, so it records five seconds with a countdown and plays them back.
@MainActor
@Observable
final class MixCheck {
    enum Phase: Equatable {
        case idle
        case listening
        case recording(secondsLeft: Int)
        case playing
    }

    private(set) var mixID: String?
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let engine: EngineBridge
    @ObservationIgnored private let player: RecentPlayer
    @ObservationIgnored private var timer: Timer?
    static let recordSeconds = 5

    init(engine: EngineBridge, player: RecentPlayer) {
        self.engine = engine
        self.player = player
    }

    func phase(for mix: Mix) -> Phase {
        mixID == mix.id ? phase : .idle
    }

    func toggle(_ mix: Mix) {
        if mixID == mix.id && phase != .idle {
            stop()
        } else {
            start(mix)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        engine.stopCheck()
        player.stop()
        mixID = nil
        phase = .idle
    }

    private func start(_ mix: Mix) {
        stop()
        mixID = mix.id
        if Output.isHeadphones() {
            engine.startCheck(mix.id, live: true)
            phase = .listening
            return
        }
        engine.startCheck(mix.id, live: false)
        phase = .recording(secondsLeft: Self.recordSeconds)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case let .recording(secondsLeft) = self.phase else { return }
                let left = secondsLeft - 1
                if left > 0 {
                    self.phase = .recording(secondsLeft: left)
                    return
                }
                self.timer?.invalidate()
                self.timer = nil
                self.phase = .playing
                let recording = self.engine.checkRecording(mix.id, seconds: Double(Self.recordSeconds))
                // Stop capturing before playing back, so the playback is not recorded too.
                self.engine.stopCheck()
                self.player.play(recording, mixID: mix.id) { [weak self] in
                    if self?.mixID == mix.id {
                        self?.mixID = nil
                        self?.phase = .idle
                    }
                }
            }
        }
    }
}

/// Whether the current output goes to headphones, where live listening cannot feed back.
enum Output {
    static func isHeadphones() -> Bool {
        var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device)
        var transport: UInt32 = 0
        address = HAL.address(kAudioDevicePropertyTransportType)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        guard transport == kAudioDeviceTransportTypeBuiltIn else {
            return false // USB, HDMI and AirPlay outputs may be speakers
        }
        var source: UInt32 = 0
        address = HAL.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source)
        return source == 0x6864706E // 'hdpn', the headphone jack
    }
}
