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

// A run of channels, counted across all buffers. A count of 0 means every channel from
// `first` on.
struct ChannelSpan
{
    uint32_t first = 0;
    uint32_t count = 0;
};

inline uint32_t TotalChannels(const AudioBufferList* input)
{
    uint32_t total = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        total += input->mBuffers[b].mNumberChannels;
    }
    return total;
}

struct TapSpan
{
    ChannelSpan span;
    bool mismatch = false;
};

// Where a tap's channels are in the aggregate that carries it: after the clock device's own
// input channels, which a headset has and speakers do not. When the buffers hold a
// different number of channels than the two add up to, the layout is not what was
// assumed, and the tap is taken to be the last `tapChannels` (the aggregate lists
// subdevices before taps). A tapChannels of 0 means the tap's format was not known; the
// span is then the first channels, as for a device.
inline TapSpan Tap(uint32_t totalChannels, uint32_t deviceChannels, uint32_t tapChannels)
{
    if (tapChannels == 0) {
        return {};
    }
    if (deviceChannels + tapChannels == totalChannels) {
        return {{deviceChannels, tapChannels}, false};
    }
    return {{totalChannels >= tapChannels ? totalChannels - tapChannels : 0, tapChannels}, true};
}

struct Stereo
{
    Channel left;
    Channel right;
};

// A source's left and right: the first two channels of its span, a mono source on both
// sides. Both are empty when there is no channel at all.
inline Stereo FirstTwo(const AudioBufferList* input, ChannelSpan span = {})
{
    Stereo pair{ChannelAt(input, span.first), {}};
    if (span.count != 1) {
        pair.right = ChannelAt(input, span.first + 1);
    }
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
    // The buffers held a different number of channels than the microphone's and the tap's
    // add up to.
    bool mismatch = false;
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

// The same aggregate when the tap's channel count is known: it sits after the microphone's
// channels, or after the buffers' first channels when their total is not what the two add
// up to, as for any tap (see Tap). The microphone is still the first channel.
inline Microphone MicTap(const AudioBufferList* input, uint32_t micChannels, uint32_t tapChannels)
{
    Microphone route{ChannelAt(input, 0), {}, {}};
    if (!route.mic) {
        return route;
    }
    const TapSpan tap = Tap(TotalChannels(input), micChannels, tapChannels);
    route.mismatch = tap.mismatch;
    route.left = ChannelAt(input, tap.span.first);
    route.right = tap.span.count == 1 ? route.left : ChannelAt(input, tap.span.first + 1);
    if (!route.right) {
        route.right = route.left;
    }
    return route;
}

} // namespace blend::routing
