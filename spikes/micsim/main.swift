import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MicSim stands in for a call app that holds the microphone, and measures what a microphone
// delivers. It runs as an app (`open -n`) so macOS attributes the microphone permission to it.
//
//   MicSim hold <profile> [--seconds N] [--rate R] [--cycle on=3,off=2,count=10] [--play far.wav] [--log path]
//              [--near near.wav [--near-loop] [--near-delay S] [--near-gain G]] [--delay S] [--tail S]
//     --near plays a file through a plain output in this process, for a level test across the
//     hold: a voice processing unit ducks every other process's output by 15 dB or more but
//     not its own process's, so only a player in the holder keeps its level when the hold
//     starts. Once, or looped with --near-loop; --near-delay starts it later.
//     --delay waits before taking the microphone and --tail keeps playing after letting go.
//   MicSim play <file.wav> [--seconds N] [--gain G] [--log path]
//   MicSim watch [--seconds N] [--log path]
//   MicSim record <out.wav> [--seconds N] [--log path]     every channel the built-in microphone delivers
//   MicSim analyze <file.wav> [--channel N|avg] [--from S] [--to S]
//                                                          level, active level, zeros and third-octave levels as JSON
//   MicSim gen <pink|tone1k> <out.wav> [--seconds N]
//   MicSim gen shaped <out.wav> --like speech.wav [--seconds N]   noise with speech's long-term spectrum
//   MicSim profiles
//
// Every command writes JSON lines to --log (and stderr), so a runner can read results back.

// MARK: log

var logHandle: FileHandle?
let t0 = Date()
func emit(_ fields: [String: Any]) {
    var f = fields
    f["t"] = (Date().timeIntervalSince(t0) * 1000).rounded() / 1000
    guard let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
    let line = data + Data("\n".utf8)
    FileHandle.standardError.write(line)
    logHandle?.write(line)
}

func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-9)) }

// MARK: args

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func number(_ name: String, _ fallback: Double) -> Double { option(name).flatMap(Double.init) ?? fallback }
let command = args.first ?? "profiles"
if let path = option("--log") {
    FileManager.default.createFile(atPath: path, contents: nil)
    logHandle = FileHandle(forWritingAtPath: path)
}

// MARK: HAL

let system = AudioObjectID(kAudioObjectSystemObject)
func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getU32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = address(sel, scope); var v: UInt32 = 0; var size = UInt32(4)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func getF64(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Double? {
    var a = address(sel); var v: Float64 = 0; var size = UInt32(8)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = address(sel); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return "" }
    return s.takeRetainedValue() as String
}
func getIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = address(sel); var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func defaultInput() -> AudioDeviceID {
    var a = address(kAudioHardwarePropertyDefaultInputDevice); var d = AudioDeviceID(0); var size = UInt32(4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &d)
    return d
}
func inputChannels(_ dev: AudioDeviceID) -> Int {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func layoutTag(_ dev: AudioDeviceID) -> UInt32 {
    var a = address(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeInput)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= 12 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
    return raw.load(as: UInt32.self)
}
func holders() -> [String] {
    var out: [String] = []
    for p in getIDs(system, kAudioHardwarePropertyProcessObjectList) where (getU32(p, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 {
        if Int32(getU32(p, kAudioProcessPropertyPID) ?? 0) != getpid() { out.append(getString(p, kAudioProcessPropertyBundleID)) }
    }
    return out
}
func defaultOutput() -> AudioDeviceID {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice); var d = AudioDeviceID(0); var size = UInt32(4)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &d)
    return d
}
/// The input volume scalar of a device's main element, or of channel 1 when the main has none; -1 when it has neither.
func inputVolume(_ dev: AudioDeviceID) -> Double {
    for element in [kAudioObjectPropertyElementMain, 1] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        var v: Float32 = 0; var size = UInt32(4)
        if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr { return (Double(v) * 1000).rounded() / 1000 }
    }
    return -1
}
func state() -> [String: Any] {
    let d = defaultInput()
    return ["ev": "state", "channels": inputChannels(d), "layoutTag": layoutTag(d), "rate": getF64(d, kAudioDevicePropertyNominalSampleRate) ?? 0,
            "holders": holders(), "outTransport": getU32(defaultOutput(), kAudioDevicePropertyTransportType) ?? 0, "transport": getU32(d, kAudioDevicePropertyTransportType) ?? 0,
            "hog": (getU32(d, kAudioDevicePropertyHogMode).map { Int32(bitPattern: $0) }) ?? -2, "inputVolume": inputVolume(d)]
}

func ensureMic() {
    let st = AVCaptureDevice.authorizationStatus(for: .audio)
    emit(["ev": "mic-permission", "status": st.rawValue])
    if st == .authorized { return }
    guard st == .notDetermined else { emit(["ev": "fatal", "msg": "microphone denied"]); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    AVCaptureDevice.requestAccess(for: .audio) { ok = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 600)
    emit(["ev": "mic-permission-asked", "granted": ok])
    if !ok { exit(2) }
}

// MARK: audio files

/// A file as mono floats at `rate`.
func loadMono(_ path: String, rate: Double) -> [Float] {
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try? file.read(into: buffer)
    let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: mono) else { return [] }
    converter.downmix = true
    let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * rate / file.processingFormat.sampleRate) + 4096)!
    var given = false
    converter.convert(to: out, error: nil) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true; status.pointee = .haveData; return buffer
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func writeWAV(_ path: String, channels: [[Float]], rate: Double) {
    // A standard format of more than two channels is nil; the raw array is three.
    let format = channels.count <= 2
        ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
        : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false,
                        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels.count))!)
    guard let file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)) else { return }
    buffer.frameLength = AVAudioFrameCount(channels[0].count)
    for (c, samples) in channels.enumerated() { samples.withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: samples.count) } }
    try? file.write(from: buffer)
}

// MARK: analysis

/// Average power spectrum in 8192-point Hann windows, then band and third-octave levels. The
/// scale is arbitrary but identical for every file, so only differences mean anything.
func analyze(samples: [Float], rate: Double) -> [String: Any] {
    let n = 8192, log2n = vDSP_Length(13)
    guard samples.count >= n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [:] }
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var power = [Double](repeating: 0, count: n / 2)
    var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
    var windows = 0
    var at = 0
    let binHzEarly = rate / Double(n)
    var frameBands: [Double] = []
    while at + n <= samples.count {
        var frame = [Float](repeating: 0, count: n)
        vDSP_vmul(Array(samples[at..<at + n]), 1, window, 1, &frame, 1, vDSP_Length(n))
        frame.withUnsafeBufferPointer { p in
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                var inBand = 0.0
                for k in 1..<n / 2 {
                    let p = Double(r[k] * r[k] + i[k] * i[k])
                    power[k] += p
                    if Double(k) * binHzEarly >= 300 && Double(k) * binHzEarly < 7000 { inBand += p }
                }
                frameBands.append(inBand)
            } }
        }
        windows += 1
        at += n / 2
    }
    let binHz = rate / Double(n)
    func band(_ lo: Double, _ hi: Double) -> Double {
        var sum = 0.0
        for k in 1..<n / 2 where Double(k) * binHz >= lo && Double(k) * binHz < hi { sum += power[k] }
        return sum / Double(windows)
    }
    let scale = 1.0 / (Double(n) * Double(n))
    var thirds: [String: Double] = [:]
    for centre in [315.0, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300] {
        let f = pow(2, 1.0 / 6)
        thirds[String(Int(centre))] = (10 * log10(max(band(centre / f, centre * f) * scale, 1e-20)) * 100).rounded() / 100
    }
    // Active level, as a speech level meter takes it: the band power of frames within 20 dB of
    // the loudest 5 percent, so pauses and the room between words do not count.
    let sorted = frameBands.sorted()
    let reference = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    let active = frameBands.filter { $0 > reference / 100 }
    let activePower = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
    return ["bandDb": (10 * log10(max(band(300, 7000) * scale, 1e-20)) * 100).rounded() / 100, "thirdOctave": thirds,
            "activeBandDb": (10 * log10(max(activePower * scale, 1e-20)) * 100).rounded() / 100]
}

func levelStats(_ samples: [Float], rate: Double) -> [String: Any] {
    let step = Int(rate)
    var perSecond: [[String: Double]] = []
    var i = 0
    while i + step <= samples.count {
        let slice = Array(samples[i..<i + step])
        var rms: Float = 0; vDSP_rmsqv(slice, 1, &rms, vDSP_Length(step))
        var peak: Float = 0; vDSP_maxmgv(slice, 1, &peak, vDSP_Length(step))
        let zeros = slice.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        perSecond.append(["rmsDb": (db(Double(rms)) * 10).rounded() / 10, "peakDb": (db(Double(peak)) * 10).rounded() / 10, "zeroShare": Double(zeros) / Double(step)])
        i += step
    }
    return ["seconds": perSecond]
}

// MARK: shaped noise

/// Stationary noise with the long-term magnitude spectrum of `like`, at its active RMS: a level
/// stimulus that weighs frequencies the way speech does but does not vary from second to
/// second, so a level before and after a flip can be compared over a few seconds.
func shapedNoise(like source: [Float], count: Int) -> [Float] {
    let n = 4096, half = n / 2, log2n = vDSP_Length(12)
    guard source.count >= n, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
    defer { vDSP_destroy_fftsetup(setup) }
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var power = [Float](repeating: 0, count: half)
    var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
    func forward(_ frame: [Float]) {
        frame.withUnsafeBufferPointer { p in
            re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            } }
        }
    }
    // Long-term spectrum over frames that carry speech: within 30 dB of the loudest.
    var energies: [Float] = []
    var at = 0
    while at + n <= source.count {
        var e: Float = 0; vDSP_svesq(Array(source[at..<at + n]), 1, &e, vDSP_Length(n)); energies.append(e)
        at += half
    }
    let loudest = energies.max() ?? 0
    var activeSum: Float = 0, activeCount = 0
    at = 0
    for e in energies {
        defer { at += half }
        guard e > loudest / 1000 else { continue }
        var frame = [Float](repeating: 0, count: n)
        vDSP_vmul(Array(source[at..<at + n]), 1, window, 1, &frame, 1, vDSP_Length(n))
        forward(frame)
        for k in 1..<half { power[k] += re[k] * re[k] + im[k] * im[k] }
        activeSum += e; activeCount += n
    }
    let magnitude = power.map { $0.squareRoot() }
    // Overlap-add of random-phase frames under a Hann window at half overlap, which sums flat.
    var out = [Float](repeating: 0, count: count + n)
    var gen = SystemRandomNumberGenerator()
    at = 0
    while at < count {
        for k in 0..<half {
            let phase = Float.random(in: 0..<(2 * Float.pi), using: &gen)
            re[k] = k == 0 ? 0 : magnitude[k] * cos(phase)
            im[k] = k == 0 ? 0 : magnitude[k] * sin(phase)
        }
        var frame = [Float](repeating: 0, count: n)
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            frame.withUnsafeMutableBufferPointer { f in
                f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
            }
        } }
        for i in 0..<n { out[at + i] += frame[i] * window[i] }
        at += half
    }
    out.removeLast(n)
    let target = activeCount > 0 ? (activeSum / Float(activeCount)).squareRoot() : 0.05
    var rms: Float = 0; vDSP_rmsqv(out, 1, &rms, vDSP_Length(out.count))
    var scale = rms > 0 ? target / rms : 0
    vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(out.count))
    return out
}

// MARK: playback

/// Plays a mono file through the default output until it ends (or `seconds`), as a plain output unit does.
func playFile(_ path: String, seconds: Double?, gain: Float) {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { emit(["ev": "fatal", "msg": "can't read \(path)"]); exit(1) }
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    engine.mainMixerNode.outputVolume = gain
    try? engine.start()
    player.scheduleFile(file, at: nil)
    player.play()
    emit(["ev": "playing", "path": path, "seconds": Double(file.length) / file.processingFormat.sampleRate])
    let end = Date().addingTimeInterval(seconds ?? Double(file.length) / file.processingFormat.sampleRate + 0.3)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    player.stop(); engine.stop()
    emit(["ev": "played"])
}

var playerKeep: [Any] = []
func startBackgroundPlayer(_ path: String, loop: Bool, gain: Float = 1) {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
    try? file.read(into: buffer)
    engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
    engine.mainMixerNode.outputVolume = gain
    try? engine.start()
    player.scheduleBuffer(buffer, at: nil, options: loop ? .loops : [])
    player.play()
    playerKeep += [engine, player]
    emit(["ev": "background-playing", "path": path, "via": "output-unit", "loop": loop, "gain": gain])
}

// MARK: per-second statistics of what a holder reads

final class Meter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumsq = 0.0, peak: Float = 0, count = 0, channels = 0, lastChannels = 0, formatChanges = 0
    func add(_ p: UnsafePointer<Float>, frames: Int, stride: Int, channels: Int) {
        var s = 0.0; var pk: Float = 0
        for i in 0..<frames { let v = p[i * stride]; s += Double(v * v); pk = max(pk, abs(v)) }
        lock.lock(); sumsq += s; peak = max(peak, pk); count += frames; self.channels = channels
        let changed = lastChannels != 0 && lastChannels != channels
        if changed { formatChanges += 1 }
        let from = lastChannels
        lastChannels = channels
        lock.unlock()
        if changed { emit(["ev": "format-change", "from": from, "to": channels]) }
    }
    func take() -> [String: Any] {
        lock.lock(); defer { sumsq = 0; peak = 0; count = 0; lock.unlock() }
        let rms = count > 0 ? (sumsq / Double(count)).squareRoot() : 0
        return ["ev": "sec", "ch": channels, "rmsDb": (db(rms) * 10).rounded() / 10, "peakDb": (db(Double(peak)) * 10).rounded() / 10, "formatChanges": formatChanges]
    }
}
let meter = Meter()

// MARK: capture primitives

var vpioUnit: AudioUnit?
var farEnd: [Float] = []
var farPos = 0
let vpioScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384)

func startVPIO(rate: Double, agc: Bool, bypass: Bool, duck: String) throws {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "vpio", code: 1) }
    var u: AudioUnit?
    var st = AudioComponentInstanceNew(comp, &u)
    guard st == noErr, let unit = u else { throw NSError(domain: "vpio", code: Int(st)) }
    vpioUnit = unit
    var one: UInt32 = 1
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4)
    var fmt = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                          mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                          mBitsPerChannel: 32, mReserved: 0)
    let fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, fsize)
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, fsize)
    var agcValue: UInt32 = agc ? 1 : 0
    AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &agcValue, 4)
    var bypassValue: UInt32 = bypass ? 1 : 0
    AudioUnitSetProperty(unit, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &bypassValue, 4)
    // The far end goes out through the unit's own output, which is what lets it cancel it.
    var render = AURenderCallbackStruct(inputProc: { _, flags, _, _, frames, abl in
        guard let abl else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        for b in buffers {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if farEnd.isEmpty { memset(d, 0, Int(b.mDataByteSize)); continue }
            for i in 0..<Int(frames) { d[i] = farEnd[(farPos + i) % farEnd.count] }
        }
        farPos = (farPos + Int(frames)) % max(farEnd.count, 1)
        if farEnd.isEmpty { flags.pointee.insert(.unitRenderAction_OutputIsSilence) }
        return noErr
    }, inputProcRefCon: nil)
    let csize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, csize)
    var input = AURenderCallbackStruct(inputProc: { _, flags, ts, _, frames, _ in
        guard let unit = vpioUnit, frames <= 16384 else { return noErr }
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: vpioScratch))
        if AudioUnitRender(unit, flags, ts, 1, frames, &abl) == noErr { meter.add(vpioScratch, frames: Int(frames), stride: 1, channels: 1) }
        return noErr
    }, inputProcRefCon: nil)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, csize)
    if duck != "default" {
        let level: AUVoiceIOOtherAudioDuckingLevel = duck == "min" ? .min : duck == "mid" ? .mid : duck == "max" ? .max : .default
        var cfg = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: DarwinBoolean(false), mDuckingLevel: level)
        AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &cfg,
                             UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
    }
    st = AudioUnitInitialize(unit)
    if st == noErr { st = AudioOutputUnitStart(unit) }
    emit(["ev": "vpio-start", "status": Int(st), "rate": rate, "agc": agc])
    if st != noErr { throw NSError(domain: "vpio", code: Int(st)) }
}

func stopVPIO() {
    guard let unit = vpioUnit else { return }
    AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
    vpioUnit = nil
    emit(["ev": "vpio-stop"])
}

var auhalUnit: AudioUnit?
let auhalScratch = UnsafeMutablePointer<Float>.allocate(capacity: 65536)
var auhalChannels = 1

/// What Chrome's input does: AUHAL at the device's nominal rate, stereo when the device has more than two channels.
func startAUHAL() throws {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "auhal", code: 1) }
    var u: AudioUnit?
    guard AudioComponentInstanceNew(comp, &u) == noErr, let unit = u else { throw NSError(domain: "auhal", code: 2) }
    auhalUnit = unit
    var on: UInt32 = 1, off: UInt32 = 0
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
    var dev = defaultInput()
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
    let have = inputChannels(dev)
    auhalChannels = have > 2 ? 2 : max(have, 1)
    var fmt = AudioStreamBasicDescription(mSampleRate: getF64(dev, kAudioDevicePropertyNominalSampleRate) ?? 48000, mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                          mBytesPerPacket: UInt32(4 * auhalChannels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * auhalChannels),
                                          mChannelsPerFrame: UInt32(auhalChannels), mBitsPerChannel: 32, mReserved: 0)
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    var input = AURenderCallbackStruct(inputProc: { _, flags, ts, _, frames, _ in
        guard let unit = auhalUnit, frames <= 8192 else { return noErr }
        let ch = auhalChannels
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: frames * 4 * UInt32(ch), mData: auhalScratch))
        if AudioUnitRender(unit, flags, ts, 1, frames, &abl) == noErr {
            meter.add(auhalScratch, frames: Int(frames), stride: ch, channels: ch)
        }
        return noErr
    }, inputProcRefCon: nil)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &input, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    var st = AudioUnitInitialize(unit)
    if st == noErr { st = AudioOutputUnitStart(unit) }
    emit(["ev": "auhal-start", "status": Int(st), "channels": auhalChannels])
    if st != noErr { throw NSError(domain: "auhal", code: Int(st)) }
}

func stopAUHAL() {
    guard let unit = auhalUnit else { return }
    AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit)
    auhalUnit = nil
}

var ioprocDevice = AudioDeviceID(0)
var ioprocID: AudioDeviceIOProcID?
var ioprocChannels = 0

/// A native WebRTC app's capture: a HAL IOProc that fixes the channel count when it opens and refuses a change.
func startIOProc() throws {
    ioprocDevice = defaultInput()
    ioprocChannels = inputChannels(ioprocDevice)
    var proc: AudioDeviceIOProcID?
    let st = AudioDeviceCreateIOProcIDWithBlock(&proc, ioprocDevice, nil) { _, inData, _, _, _ in
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let b = abl.first, let d = b.mData else { return }
        let ch = Int(b.mNumberChannels)
        if ch != ioprocChannels {
            emit(["ev": "error", "msg": "Changing channels not supported", "from": ioprocChannels, "to": ch])
            ioprocChannels = ch
        }
        meter.add(d.assumingMemoryBound(to: Float.self), frames: Int(b.mDataByteSize) / 4 / max(ch, 1), stride: max(ch, 1), channels: ch)
    }
    ioprocID = proc
    let st2 = AudioDeviceStart(ioprocDevice, proc)
    emit(["ev": "ioproc-start", "create": Int(st), "start": Int(st2), "channels": ioprocChannels])
    if st != noErr || st2 != noErr { throw NSError(domain: "ioproc", code: Int(st2)) }
}

func stopIOProc() {
    guard let proc = ioprocID else { return }
    AudioDeviceStop(ioprocDevice, proc); AudioDeviceDestroyIOProcID(ioprocDevice, proc)
    ioprocID = nil
}

func takeHog() {
    let dev = defaultInput()
    var a = address(kAudioDevicePropertyHogMode)
    var pid = getpid()
    let st = AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &pid)
    emit(["ev": "hog", "status": Int(st)])
}

func releaseHog() {
    let dev = defaultInput()
    var a = address(kAudioDevicePropertyHogMode)
    var none: pid_t = -1
    AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &none)
}

// MARK: profiles

struct Profile {
    enum Primitive { case vpio, auhal, ioproc, hog }
    var primitive: Primitive
    var agc = true
    /// Whether the far end goes through the unit (a voice processing unit) or a separate output.
    var farThroughUnit = false
    var stands: String
}

let profiles: [String: Profile] = [
    "facetime": Profile(primitive: .vpio, farThroughUnit: true, stands: "FaceTime"),
    "whatsapp": Profile(primitive: .vpio, farThroughUnit: true, stands: "WhatsApp, WeChat"),
    "safari": Profile(primitive: .vpio, farThroughUnit: true, stands: "Meet in Safari, Firefox; use --cycle for mute and unmute releasing the mic"),
    "chrome": Profile(primitive: .auhal, stands: "Meet in Chrome, Slack huddle (AUHAL, no voice processing)"),
    "chrome-system-aec": Profile(primitive: .vpio, agc: false, farThroughUnit: true, stands: "Chrome with EnforceSystemEchoCancellation"),
    "teams": Profile(primitive: .ioproc, stands: "Teams and native WebRTC apps (HAL IOProc, fixed channels)"),
    "zoom-a": Profile(primitive: .ioproc, stands: "Zoom if it is a plain client"),
    "zoom-b": Profile(primitive: .vpio, farThroughUnit: true, stands: "Zoom if it uses voice processing"),
    "hog": Profile(primitive: .hog, stands: "robustness: takes exclusive access to the microphone"),
]

func runHold(_ name: String) {
    guard let profile = profiles[name] else { emit(["ev": "fatal", "msg": "unknown profile \(name)"]); exit(1) }
    ensureMic()
    let rate = number("--rate", 48000)
    let agc = profile.agc && !args.contains("--no-agc")
    let seconds = number("--seconds", 20)
    var on = 3.0, off = 2.0, count = 10
    var cycle = false
    if let spec = option("--cycle") {
        cycle = true
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=")
            guard kv.count == 2, let v = Double(kv[1]) else { continue }
            if kv[0] == "on" { on = v } else if kv[0] == "off" { off = v } else if kv[0] == "count" { count = Int(v) }
        }
    }
    if let near = option("--near") {
        let loop = args.contains("--near-loop"), gain = Float(number("--near-gain", 1))
        let at = number("--near-delay", 0)
        if at > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { startBackgroundPlayer(near, loop: loop, gain: gain) }
        } else {
            startBackgroundPlayer(near, loop: loop, gain: gain)
        }
    }
    if let far = option("--play") {
        if profile.farThroughUnit { farEnd = loadMono(far, rate: rate) } else { startBackgroundPlayer(far, loop: true) }
    }
    emit(["ev": "hold", "profile": name, "stands": profile.stands, "state": state()])
    let delay = number("--delay", 0)
    if delay > 0 { RunLoop.main.run(until: Date().addingTimeInterval(delay)) }
    func start() {
        do {
            switch profile.primitive {
            case .vpio: try startVPIO(rate: rate, agc: agc, bypass: args.contains("--bypass"), duck: option("--duck") ?? "default")
            case .auhal: try startAUHAL()
            case .ioproc: try startIOProc()
            case .hog: takeHog()
            }
        } catch { emit(["ev": "fatal", "msg": "start failed: \(error)"]); exit(1) }
    }
    func stop() {
        switch profile.primitive {
        case .vpio: stopVPIO()
        case .auhal: stopAUHAL()
        case .ioproc: stopIOProc()
        case .hog: releaseHog()
        }
    }
    if cycle {
        var n = 0
        let end = Date().addingTimeInterval(max(seconds, (on + off) * Double(count)))
        while n < count && Date() < end {
            start(); emit(["ev": "cycle-on", "n": n])
            let stopAt = Date().addingTimeInterval(on)
            while Date() < stopAt { RunLoop.main.run(until: Date().addingTimeInterval(1)); emit(meter.take()) }
            stop(); emit(["ev": "cycle-off", "n": n])
            RunLoop.main.run(until: Date().addingTimeInterval(off))
            n += 1
        }
    } else {
        start()
        let end = Date().addingTimeInterval(seconds)
        var tick = 0
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            tick += 1
            emit(meter.take())
            if tick % 2 == 1 { emit(state()) }
        }
        stop()
    }
    let tail = number("--tail", 0)
    if tail > 0 { emit(["ev": "tail", "state": state()]); RunLoop.main.run(until: Date().addingTimeInterval(tail)) }
    emit(["ev": "done"])
}

// MARK: record

func runRecord() {
    ensureMic()
    guard args.count > 1 else { return }
    let out = args[1]
    let seconds = number("--seconds", 5)
    let dev = defaultInput()
    let rate = getF64(dev, kAudioDevicePropertyNominalSampleRate) ?? 48000
    let lock = NSLock()
    var channels: [[Float]] = []
    var counts: [Int: Int] = [:]
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { _, inData, _, _, _ in
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let b = abl.first, let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
        let ch = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / 4 / max(ch, 1)
        lock.lock()
        if channels.isEmpty { channels = Array(repeating: [], count: ch) }
        counts[ch, default: 0] += frames
        for c in 0..<min(ch, channels.count) { for i in 0..<frames { channels[c].append(d[i * ch + c]) } }
        lock.unlock()
    }
    AudioDeviceStart(dev, proc)
    emit(["ev": "record-start", "state": state(), "rate": rate])
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
    AudioDeviceStop(dev, proc); AudioDeviceDestroyIOProcID(dev, proc!)
    lock.lock()
    if !channels.isEmpty { writeWAV(out, channels: channels, rate: rate) }
    emit(["ev": "record-done", "path": out, "channels": channels.count, "frames": channels.first?.count ?? 0, "rate": rate,
          "framesByChannelCount": Dictionary(uniqueKeysWithValues: counts.map { ("\($0.key)", $0.value) })])
    lock.unlock()
}

// MARK: main

switch command {
case "profiles":
    for (k, v) in profiles.sorted(by: { $0.key < $1.key }) { print("\(k): \(v.stands)") }
case "hold": runHold(args.count > 1 ? args[1] : "")
case "play":
    guard args.count > 1 else { exit(1) }
    playFile(args[1], seconds: option("--seconds").flatMap(Double.init), gain: Float(number("--gain", 1)))
case "watch":
    let end = Date().addingTimeInterval(number("--seconds", 10))
    while Date() < end { emit(state()); RunLoop.main.run(until: Date().addingTimeInterval(1)) }
case "record": runRecord()
case "analyze":
    guard args.count > 1, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: args[1])),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { exit(1) }
    try? file.read(into: buffer)
    let available = Int(buffer.format.channelCount)
    let pick = option("--channel") ?? "avg"
    var samples = [Float](repeating: 0, count: Int(buffer.frameLength))
    for c in 0..<available where pick == "avg" || Int(pick) == c {
        for i in 0..<samples.count { samples[i] += buffer.floatChannelData![c][i] }
    }
    if pick == "avg" { let k = Float(available); for i in 0..<samples.count { samples[i] /= k } }
    let fileRate = file.processingFormat.sampleRate
    let from = min(samples.count, max(0, Int(number("--from", 0) * fileRate)))
    let to = min(samples.count, max(from, Int(number("--to", Double(samples.count) / fileRate) * fileRate)))
    samples = Array(samples[from..<to])
    var longest = 0, run = 0
    for v in samples { run = v == 0 ? run + 1 : 0; longest = max(longest, run) }
    var result = analyze(samples: samples, rate: file.processingFormat.sampleRate)
    result["longestZeroRunMs"] = (Double(longest) / fileRate * 1000).rounded()
    result["windowSeconds"] = Double(samples.count) / fileRate
    result.merge(levelStats(samples, rate: file.processingFormat.sampleRate)) { a, _ in a }
    result["channels"] = available
    result["rate"] = file.processingFormat.sampleRate
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
case "gen":
    guard args.count > 2 else { exit(1) }
    let rate = 48000.0, n = Int(number("--seconds", 10) * rate)
    var x = [Float](repeating: 0, count: n)
    if args[1] == "shaped" {
        guard let like = option("--like") else { exit(1) }
        x = shapedNoise(like: loadMono(like, rate: rate), count: n)
    } else if args[1] == "tone1k" {
        for i in 0..<n { x[i] = 0.5 * Float(sin(2 * Double.pi * 1000 * Double(i) / rate)) }
    } else {
        // Pink noise by Paul Kellet's filter.
        var b = [Float](repeating: 0, count: 7)
        var gen = SystemRandomNumberGenerator()
        for i in 0..<n {
            let w = Float.random(in: -1...1, using: &gen)
            b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
            x[i] = (b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362) * 0.11
            b[6] = w * 0.115926
        }
    }
    writeWAV(args[2], channels: [x], rate: rate)
default:
    emit(["ev": "fatal", "msg": "unknown command \(command)"]); exit(1)
}
