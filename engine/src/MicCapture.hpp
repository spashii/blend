#pragma once

// Captures one input device, optionally with an echo reference and the MicProcessor
// stages, and hands the result to a FrameSink on the device's IO thread.
//
// With a reference, the device and a tap of everything the Mac plays (this process left
// out, since its output carries the mixes, which contain this microphone) run in one
// private aggregate device, so the reference arrives in the microphone's IO cycle already
// aligned to it.

#include "Capture.hpp"
#include "MicProcessor.hpp"

#include <CoreAudio/CoreAudio.h>

#include <memory>
#include <string>

namespace blend {

class MicCapture
{
public:
    enum class Reference
    {
        None,
        EverythingButSelf,
    };

    struct Options
    {
        std::string uid;
        Reference reference = Reference::None;
        // Takes effect only when the reference could be set up.
        bool echoCancel = false;
        MicProcessor::Isolation isolation = MicProcessor::Isolation::Off;
        // Gather 10 ms blocks even with every stage off. Implied once a reference is
        // running, because the far end only travels in blocks.
        bool passThrough = false;
    };

    explicit MicCapture(Options options);
    ~MicCapture();

    MicCapture(const MicCapture&) = delete;
    MicCapture& operator=(const MicCapture&) = delete;

    // Control queue. Calls sink.Prepare, starts the IO, and from then on calls sink.Block
    // when the MicProcessor runs, and sink.Raw with the device's own buffers when it does
    // not. The sink must outlive Stop.
    bool Start(FrameSink& sink);
    // Calls sink.Stopped once the IO has stopped.
    void Stop();
    bool Running() const { return proc_ != nullptr; }

    // True when the capture must be rebuilt: its device was replaced or changed rate.
    bool NeedsRestart() const;
    // What the processing stages are doing, starting with a space, or empty.
    std::string Describe() const;

private:
    static OSStatus IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
        const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context);
    static void Emit(void* context, const float* me, const float* farEnd, uint32_t frames);
    bool AddReference();

    const Options options_;
    FrameSink* sink_ = nullptr;
    AudioObjectID device_ = kAudioObjectUnknown;
    // The device itself, or the aggregate that adds the echo reference to it.
    AudioObjectID ioDevice_ = kAudioObjectUnknown;
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID aggregate_ = kAudioObjectUnknown;
    UInt32 micChannels_ = 0;
    AudioDeviceIOProcID proc_ = nullptr;
    double rate_ = 0;
    std::unique_ptr<MicProcessor> processor_;
};

} // namespace blend
