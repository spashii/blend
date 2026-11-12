#pragma once

// Captures one input device, optionally with an echo reference and the MicProcessor
// stages, and hands the result to a FrameSink on the device's IO thread.
//
// With a reference, the device and a tap of everything the Mac plays (this process left
// out, since its output carries the mixes, which contain this microphone) run in one
// private aggregate device, so the reference arrives in the microphone's IO cycle already
// aligned to it. A call app's processes can be the reference instead, for a host that
// records both sides of a call: the far end then comes out beside the microphone.

#include "Capture.hpp"
#include "MicProcessor.hpp"
#include "ProcessTap.hpp"

#include <CoreAudio/CoreAudio.h>

#include <dispatch/dispatch.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace blend {

class MicCapture
{
public:
    enum class Reference
    {
        None,
        EverythingButSelf,
        // The processes of Options::target. Start fails when the tap cannot be built,
        // since a host asking for this has no use for the microphone alone.
        Processes,
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
        // Reference::Processes only. The tap is named "<tapPrefix>: <bundle id>".
        TapTarget target;
        std::string tapPrefix;
        // Called on `queue` as soon as the device's or the aggregate's sample rate changes,
        // so a host need not wait for its next NeedsRestart poll. Not set: not watched.
        dispatch_queue_t queue = nullptr;
        std::function<void()> onRateChange;
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
    // Control queue, Reference::Processes only: points the tap at the target's processes as
    // they are now.
    void RefreshProcesses();
    // Any thread. True when echo cancellation was asked for, ran, and then failed.
    bool EchoCancelFailed() const;
    // Any thread: buffers whose channel count was not the microphone's plus the tap's.
    uint64_t ChannelMismatches() const { return mismatches_.load(std::memory_order_relaxed); }
    uint32_t MicChannels() const { return micChannels_; }
    // The rate the IO device ran at when this capture started.
    double Rate() const { return ioRate_; }
    // What the processing stages are doing, starting with a space, or empty.
    std::string Describe() const;

private:
    static OSStatus IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
        const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context);
    static void Emit(void* context, const float* me, const float* farEnd, uint32_t frames);
    bool AddReference();
    void WatchRates();
    void UnwatchRates();

    const Options options_;
    FrameSink* sink_ = nullptr;
    AudioObjectID device_ = kAudioObjectUnknown;
    // The device itself, or the aggregate that adds the echo reference to it.
    AudioObjectID ioDevice_ = kAudioObjectUnknown;
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID aggregate_ = kAudioObjectUnknown;
    UInt32 micChannels_ = 0;
    // Zero when unknown, which routes the way Blend's own echo reference always has.
    UInt32 tapChannels_ = 0;
    std::atomic<uint64_t> mismatches_{0};
    std::vector<AudioObjectID> processes_;
    void* description_ = nullptr; // CATapDescription, retained
    AudioDeviceIOProcID proc_ = nullptr;
    double rate_ = 0;
    double ioRate_ = 0;
    std::unique_ptr<MicProcessor> processor_;
    // Nominal-rate listeners: each device with its retained AudioObjectPropertyListenerBlock.
    std::vector<std::pair<AudioObjectID, void*>> rateListeners_;
};

} // namespace blend
