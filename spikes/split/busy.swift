// Prints the Blend mixes some app is reading right now, one per line; nothing when none is.
import CoreAudio

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
}

var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
for device in devices {
    var uid: Unmanaged<CFString>?
    guard property(device, kAudioDevicePropertyDeviceUID, &uid), let uid else { continue }
    let text = uid.takeRetainedValue() as String
    var running: UInt32 = 0
    if text.hasPrefix("app.blend.mix."), property(device, kAudioDevicePropertyDeviceIsRunningSomewhere, &running),
       running != 0 {
        print(text)
    }
}
