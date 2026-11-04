// Prints the Blend mixes some app is reading right now, one per line; nothing when none is.
import CoreAudio

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

var devicesAddress = address(kAudioHardwarePropertyDevices)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size)
var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &devices)
for device in devices {
    var uidAddress = address(kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard withUnsafeMutablePointer(to: &uid, { pointer in
        AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, pointer)
    }) == noErr, let text = uid?.takeRetainedValue() as String?, text.hasPrefix("app.blend.mix.") else {
        continue
    }
    var runningAddress = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var running: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr,
       running != 0 {
        print(text)
    }
}
