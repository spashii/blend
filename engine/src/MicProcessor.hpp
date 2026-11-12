#pragma once

// Echo cancellation and voice isolation for one microphone, run on its capture thread.
//
// Echo cancellation is WebRTC's AEC3, given everything the Mac plays as the echo reference.
// The reference is a global process tap captured in the same aggregate device as the
// microphone, so both arrive in the same IO cycle, already aligned to within a few
// milliseconds. Isolation is Apple's AUSoundIsolation. Both run on 10 ms blocks: the
// processor gathers whatever the device delivers into blocks and passes each finished
// block to its sink, together with the far end it was cancelled against, so a host can
// use the two as one sample-aligned pair.

#include <AudioToolbox/AudioToolbox.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace blend {

class MicProcessor
{
public:
    enum class Isolation
    {
        Off,
        Standard,
        HighQuality,
    };

    // "off", "standard" or "high", as the app stores it.
    static Isolation ParseIsolation(const std::string& value);

    // Receives each processed block, mono, on the capture thread, with the far end for the
    // same instants: the reference exactly as it went into echo cancellation (the left and
    // right channels averaged). `farEnd` is null when the blocks had no reference.
    using Sink = void (*)(void* context, const float* me, const float* farEnd, uint32_t frames);

    // Control thread. Returns null when neither stage could be set up, and the caller
    // then captures the microphone unprocessed. With `passThrough`, a processor with both
    // stages off is still returned: it only gathers 10 ms blocks, for a caller that wants
    // the far end beside the microphone.
    static std::unique_ptr<MicProcessor> Create(double rate, bool echoCancel, Isolation isolation,
        Sink sink, void* context, bool passThrough = false);
    ~MicProcessor();

    MicProcessor(const MicProcessor&) = delete;
    MicProcessor& operator=(const MicProcessor&) = delete;

    uint32_t BlockFrames() const { return block_; }
    bool EchoCancelling() const;
    bool Isolating() const { return isolation_ != nullptr; }

    // Capture thread. Each channel is a strided pointer into the device's buffers. The
    // reference may be null (no echo cancellation), and refRight may equal refLeft.
    void Process(const float* mic, uint32_t micStride, const float* refLeft,
        uint32_t refLeftStride, const float* refRight, uint32_t refRightStride, uint32_t frames);

    // Any thread: what the stages are doing, for diagnostics.
    std::string Describe() const;

private:
    struct Apm;

    MicProcessor(double rate, Sink sink, void* context);
    bool StartIsolation(Isolation isolation);
    void ProcessBlock();
    static OSStatus FeedIsolation(void* context, AudioUnitRenderActionFlags* flags,
        const AudioTimeStamp* time, UInt32 bus, UInt32 frames, AudioBufferList* data);

    const double rate_;
    const uint32_t block_;
    const Sink sink_;
    void* const context_;
    std::unique_ptr<Apm> apm_;
    AudioUnit isolation_ = nullptr;
    double isolationLatency_ = 0;

    // Capture thread only.
    std::vector<float> mic_;
    std::vector<float> reference_;
    std::vector<float> farEnd_;
    std::vector<float> cleaned_;
    std::vector<float> isolated_;
    uint32_t filled_ = 0;
    bool hasReference_ = false;
    Float64 isolationTime_ = 0;
    const float* isolationInput_ = nullptr;

    // Set on the capture thread when a stage fails, so it is skipped from then on rather
    // than turning the microphone silent.
    std::atomic<bool> apmFailed_{false};
    std::atomic<bool> isolationFailed_{false};
};

} // namespace blend
