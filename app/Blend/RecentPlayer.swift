import AVFoundation
import Observation

/// Plays back a recording of a mix through the default output, for the speaker version of
/// a check.
@MainActor
@Observable
final class RecentPlayer {
    private(set) var playingMixID: String?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let format = AVAudioFormat(standardFormatWithSampleRate: 48000,
        channels: 2)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Plays interleaved stereo frames at 48 kHz, then calls done unless stopped first.
    func play(_ stereo: [Float], mixID: String, done: @escaping @MainActor () -> Void = {}) {
        stop()
        let frames = stereo.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            channels[0][i] = stereo[2 * i]
            channels[1][i] = stereo[2 * i + 1]
        }
        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            return
        }
        playingMixID = mixID
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                if self?.playingMixID == mixID {
                    self?.playingMixID = nil
                    done()
                }
            }
        }
        player.play()
    }

    func stop() {
        player.stop()
        playingMixID = nil
    }
}
