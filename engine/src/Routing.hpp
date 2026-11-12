#pragma once

// Which channels of a device's buffers a capture reads. Pure functions over an
// AudioBufferList, so the rules can be tested on synthetic buffers without a device and
// shared by every capture path.

#include <CoreAudio/CoreAudioTypes.h>

#include <algorithm>
#include <cstdint>

namespace blend::routing {

// One channel of a buffer list: a strided pointer into a buffer's samples.
struct Channel
{
    const float* data = nullptr;
    uint32_t stride = 1;

    explicit operator bool() const { return data != nullptr; }
    float operator[](size_t frame) const { return data[frame * stride]; }
};

// Frames in the first buffer, which every buffer of a cycle is as long as.
inline uint32_t Frames(const AudioBufferList* input)
{
    const AudioBuffer& first = input->mBuffers[0];
    return first.mDataByteSize / (sizeof(float) * std::max<uint32_t>(1, first.mNumberChannels));
}

// The channel at `index`, counting across all buffers in order: a device lists its own
// input channels first, then a tap's.
inline Channel ChannelAt(const AudioBufferList* input, uint32_t index)
{
    uint32_t at = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer& buffer = input->mBuffers[b];
        if (index < at + buffer.mNumberChannels) {
            return {static_cast<const float*>(buffer.mData) + (index - at), buffer.mNumberChannels};
        }
        at += buffer.mNumberChannels;
    }
    return {};
}

struct Stereo
{
    Channel left;
    Channel right;
};

// A source's left and right: its first two channels, a mono source on both sides. Both
// are empty when there is no channel at all.
inline Stereo FirstTwo(const AudioBufferList* input)
{
    Stereo pair{ChannelAt(input, 0), ChannelAt(input, 1)};
    if (pair.left && !pair.right) {
        pair.right = pair.left;
    }
    return pair;
}

struct Microphone
{
    Channel mic;
    Channel left;
    Channel right;
};

// An echo-cancelled microphone's aggregate: the microphone's `micChannels` channels come
// first, then the tap's left and right. The first microphone channel is processed. A mono
// tap leaves `right` empty and `left` stands for both. Without a reference, both are
// empty. `mic` is empty when the buffers hold no channel.
inline Microphone Mic(const AudioBufferList* input, uint32_t micChannels, bool reference)
{
    Microphone route{ChannelAt(input, 0), {}, {}};
    if (!route.mic || !reference) {
        return route;
    }
    route.left = ChannelAt(input, micChannels);
    route.right = ChannelAt(input, micChannels + 1);
    if (!route.right) {
        route.right = route.left;
    }
    return route;
}

} // namespace blend::routing
