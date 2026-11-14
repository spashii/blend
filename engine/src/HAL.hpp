#pragma once

// Thin helpers over the Core Audio HAL property API.

#include <CoreAudio/CoreAudio.h>

#include <sys/sysctl.h>
#include <unistd.h>

#include <string>
#include <vector>

namespace blend::hal {

inline AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    return {selector, scope, kAudioObjectPropertyElementMain};
}

template <typename T>
bool Get(AudioObjectID object, AudioObjectPropertySelector selector, T& out,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    auto address = Address(selector, scope);
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &out) == noErr;
}

template <typename T>
bool Set(AudioObjectID object, AudioObjectPropertySelector selector, const T& value,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    auto address = Address(selector, scope);
    return AudioObjectSetPropertyData(object, &address, 0, nullptr, sizeof(T), &value) == noErr;
}

inline std::string ToString(CFStringRef value)
{
    if (!value) {
        return {};
    }
    char buffer[1024];
    return CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8) ? buffer
                                                                                     : "";
}

inline std::string GetString(AudioObjectID object, AudioObjectPropertySelector selector)
{
    CFStringRef value = nullptr;
    if (!Get(object, selector, value) || !value) {
        return {};
    }
    std::string result = ToString(value);
    CFRelease(value);
    return result;
}

template <typename T>
std::vector<T> GetArray(AudioObjectID object, AudioObjectPropertySelector selector)
{
    auto address = Address(selector);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(object, &address, 0, nullptr, &size) != noErr) {
        return {};
    }
    std::vector<T> values(size / sizeof(T));
    if (AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, values.data()) != noErr) {
        return {};
    }
    values.resize(size / sizeof(T));
    return values;
}

inline AudioObjectID Translate(AudioObjectPropertySelector selector, const std::string& key)
{
    CFStringRef string = CFStringCreateWithCString(nullptr, key.c_str(), kCFStringEncodingUTF8);
    AudioObjectID result = kAudioObjectUnknown;
    auto address = Address(selector);
    UInt32 size = sizeof(result);
    AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, sizeof(CFStringRef), &string, &size, &result);
    CFRelease(string);
    return result;
}

inline AudioObjectID DeviceForUID(const std::string& uid)
{
    return Translate(kAudioHardwarePropertyTranslateUIDToDevice, uid);
}

inline UInt32 ChannelCount(AudioObjectID device, AudioObjectPropertyScope scope)
{
    auto address = Address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr || !size) {
        return 0;
    }
    std::vector<uint8_t> storage(size);
    auto list = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, list) != noErr) {
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        channels += list->mBuffers[i].mNumberChannels;
    }
    return channels;
}

inline double NominalRate(AudioObjectID device)
{
    Float64 rate = 0;
    Get(device, kAudioDevicePropertyNominalSampleRate, rate);
    return rate;
}

inline UInt32 BufferFrames(AudioObjectID device)
{
    UInt32 frames = 0;
    Get(device, kAudioDevicePropertyBufferFrameSize, frames);
    return frames;
}

// Whether a device is a physical microphone: built-in, USB, Bluetooth and the like, as
// against a virtual or aggregate device, or one that does not say. The same rule as
// InputDevices.isHardware in the app.
inline bool IsPhysicalInput(AudioObjectID device)
{
    UInt32 transport = 0;
    if (!Get(device, kAudioDevicePropertyTransportType, transport)) {
        return false;
    }
    switch (transport) {
    case kAudioDeviceTransportTypeBuiltIn:
    case kAudioDeviceTransportTypeUSB:
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE:
    case kAudioDeviceTransportTypeFireWire:
    case kAudioDeviceTransportTypePCI:
    case kAudioDeviceTransportTypeThunderbolt:
    case kAudioDeviceTransportTypeHDMI:
    case kAudioDeviceTransportTypeDisplayPort:
    case kAudioDeviceTransportTypeAVB:
    case kAudioDeviceTransportTypeContinuityCaptureWired:
    case kAudioDeviceTransportTypeContinuityCaptureWireless:
        return true;
    default:
        return false;
    }
}

inline bool IsBuiltIn(AudioObjectID device)
{
    UInt32 transport = 0;
    return Get(device, kAudioDevicePropertyTransportType, transport) &&
           transport == kAudioDeviceTransportTypeBuiltIn;
}

inline bool AppleSilicon()
{
    int value = 0;
    size_t size = sizeof(value);
    return sysctlbyname("hw.optional.arm64", &value, &size, nullptr, 0) == 0 && value == 1;
}

// The layout tag of an input's preferred channel layout, 0 when it has none.
inline uint32_t PreferredLayoutTag(AudioObjectID device)
{
    auto address = Address(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeInput);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr ||
        size < sizeof(AudioChannelLayout)) {
        return 0;
    }
    std::vector<uint8_t> storage(size);
    auto layout = reinterpret_cast<AudioChannelLayout*>(storage.data());
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, layout) != noErr) {
        return 0;
    }
    return layout->mChannelLayoutTag;
}

// A built-in array of more than one channel with a discrete or missing layout, on Apple
// silicon: what macOS delivers while another app holds the array with voice processing.
inline bool RawArray(bool builtIn, uint32_t channels, uint32_t layoutTag)
{
    const uint32_t discrete = kAudioChannelLayoutTag_DiscreteInOrder & 0xFFFF0000;
    return AppleSilicon() && builtIn && channels > 1 &&
           (layoutTag == 0 || (layoutTag & 0xFFFF0000) == discrete);
}

// Bundle IDs of the other processes that are running input, for the log and the notice.
inline std::vector<std::string> InputHolders()
{
    std::vector<std::string> holders;
    const pid_t self = getpid();
    for (AudioObjectID process : GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyProcessObjectList)) {
        UInt32 input = 0;
        Get(process, kAudioProcessPropertyIsRunningInput, input);
        pid_t pid = 0;
        Get(process, kAudioProcessPropertyPID, pid);
        if (input && pid != self) {
            std::string id = GetString(process, kAudioProcessPropertyBundleID);
            if (!id.empty()) {
                holders.push_back(id);
            }
        }
    }
    return holders;
}

} // namespace blend::hal
