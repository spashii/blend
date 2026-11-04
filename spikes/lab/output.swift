// Prints the default output device, or sets it by UID: output [UID]
import CoreAudio
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
if CommandLine.arguments.count > 1 {
    var uid = CommandLine.arguments[1] as CFString
    var dev = AudioObjectID(0)
    var t = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &t,
        UInt32(MemoryLayout<CFString>.size), &uid, &size, &dev)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
        UInt32(MemoryLayout<AudioObjectID>.size), &dev)
}
var dev = AudioObjectID(0)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
var name: CFString = "" as CFString
var n = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
size = UInt32(MemoryLayout<CFString>.size)
AudioObjectGetPropertyData(dev, &n, 0, nil, &size, &name)
print("default output:", name)
