#pragma once

// Where a capture delivers what it hears. Blend's own sink queues frames for the mixer;
// other hosts can take them elsewhere without the capture code knowing.

#include <CoreAudio/CoreAudioTypes.h>

#include <cstdint>

namespace blend {

class FrameSink
{
public:
    virtual ~FrameSink() = default;

    // Control thread, once the capture's rate and buffer size are known and before any IO
    // runs.
    virtual void Prepare(double rate, uint32_t bufferFrames) {}
    // Control thread, after the capture's IO has stopped and no more frames will arrive.
    virtual void Stopped() {}

    // IO thread, which must never block, allocate or take a lock. A device's buffers as
    // delivered, any channel layout.
    virtual void Raw(const AudioBufferList* input) {}
    // IO thread. Mono blocks of the same length for the microphone and its echo reference,
    // sample-aligned. The reference is null when there is none.
    virtual void Block(const float* me, const float* reference, uint32_t frames) {}
};

} // namespace blend
