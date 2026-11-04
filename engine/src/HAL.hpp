#pragma once

// Thin helpers over the Core Audio HAL property API.

#include <CoreAudio/CoreAudio.h>

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

} // namespace blend::hal
