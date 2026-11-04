// Spike S6: runs a WAV file through Apple's AUSoundIsolation offline and reports how long
// it took, so CPU cost and latency can be measured without playing anything aloud.
//
// usage: isolate IN.wav OUT.wav voice|hq WETDRY_PERCENT

import AVFoundation
import AudioToolbox

let args = CommandLine.arguments
guard args.count == 5, let wetDry = Float(args[4]) else {
    print("usage: isolate IN.wav OUT.wav voice|hq WETDRY_PERCENT")
    exit(2)
}
let model: Float = args[3] == "hq"
    ? Float(kAUSoundIsolationSoundType_HighQualityVoice)
    : Float(kAUSoundIsolationSoundType_Voice)

let input = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let format = input.processingFormat

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let isolation = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: kAudioUnitSubType_AUSoundIsolation,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0))
engine.attach(player)
engine.attach(isolation)
engine.connect(player, to: isolation, format: format)
engine.connect(isolation, to: engine.mainMixerNode, format: format)

let unit = isolation.audioUnit
AudioUnitSetParameter(unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
    kAudioUnitScope_Global, 0, wetDry, 0)
AudioUnitSetParameter(unit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
    kAudioUnitScope_Global, 0, model, 0)

let maxFrames: AVAudioFrameCount = 4096
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
try engine.start()
player.scheduleFile(input, at: nil)
player.play()

var latency: Float64 = 0
var size = UInt32(MemoryLayout<Float64>.size)
AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency,
    &size)
var tail: Float64 = 0
AudioUnitGetProperty(unit, kAudioUnitProperty_TailTime, kAudioUnitScope_Global, 0, &tail, &size)

let output = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]),
    settings: format.settings, commonFormat: format.commonFormat,
    interleaved: format.isInterleaved)
let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!

// Render the file plus enough extra to flush the unit's latency and tail.
let extra = AVAudioFramePosition((latency + tail + 0.1) * format.sampleRate)
let total = input.length + extra
let start = Date()
while engine.manualRenderingSampleTime < total {
    let remaining = total - engine.manualRenderingSampleTime
    let frames = min(AVAudioFrameCount(remaining), maxFrames)
    let status = try engine.renderOffline(frames, to: buffer)
    if status == .success {
        try output.write(from: buffer)
    } else if status == .error {
        print("render error")
        exit(1)
    }
}
let elapsed = Date().timeIntervalSince(start)
let audioSeconds = Double(input.length) / format.sampleRate
print(String(format:
    "model=%@ wetdry=%.0f rate=%.0f channels=%u latency_ms=%.1f tail_ms=%.1f audio_s=%.2f render_s=%.3f realtime_factor=%.4f",
    args[3], wetDry, format.sampleRate, format.channelCount, latency * 1000, tail * 1000,
    audioSeconds, elapsed, elapsed / audioSeconds))
