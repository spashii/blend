#pragma once

// Audio sources the engine mixes: input devices and app audio taps. Each one runs its own
// IO thread at its own clock and rate, and the bus thread pulls from it through a
// SourceReader that brings it onto the bus clock.

#include "FrameRing.hpp"
#include "MicCapture.hpp"
#include "MicProcessor.hpp"
#include "ProcessTap.hpp"
#include "SourceReader.hpp"

#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace blend {

// Runs a deleter once the bus thread can no longer hold the object it frees.
using Retire = std::function<void(std::function<void()>)>;

class Source
{
public:
    Source(std::string key, Retire retire);
    virtual ~Source();

    const std::string& Key() const { return key_; }
    bool Live() const { return stream_.load(std::memory_order_acquire) != nullptr; }

    // Control queue.
    virtual bool Start(double busRate, uint32_t busFrames) = 0;
    virtual void Stop() = 0;
    // True when the capture must be rebuilt: its device was replaced or changed rate.
    virtual bool NeedsRestart() const { return false; }
    // Extra state for diagnostics, starting with a space, or empty.
    virtual std::string Detail() const { return {}; }

    // Bus thread: writes `frames` stereo frames at the bus rate, silence when not live.
    void Pull(float* stereo, uint32_t frames);
    float TakePeak() { return peak_.exchange(0, std::memory_order_relaxed); }
    // Peak of what the source captured, whether or not the bus pulls it; for meters in
    // the source picker.
    float TakeProducedPeak() { return producedPeak_.exchange(0, std::memory_order_relaxed); }

    struct Stats
    {
        uint64_t underruns = 0;
        uint64_t skips = 0;
        uint64_t overflows = 0;
        double correction = 1;
        double sourceRate = 0;
    };
    Stats GetStats() const;

protected:
    struct Stream
    {
        Stream(double sourceRate, double busRate, uint32_t sourceFrames, uint32_t busFrames);
        double rate;
        FrameRing ring;
        SourceReader reader;
    };

    // Called by Start once the source's rate and buffer size are known.
    void Publish(double sourceRate, double busRate, uint32_t sourceFrames, uint32_t busFrames);
    // Called by Stop after the source's IO has stopped.
    void Unpublish();
    // Source IO thread: converts any channel layout to stereo and queues it.
    void Produce(const AudioBufferList* input);

    const std::string key_;
    const Retire retire_;

private:
    std::atomic<Stream*> stream_{nullptr};
    std::vector<float> stereo_;
    std::atomic<float> peak_{0};
    std::atomic<float> producedPeak_{0};
};

// An input device, optionally with echo cancellation and voice isolation (MicCapture).
// With echo cancellation it records the device and a tap of everything the Mac plays
// through one private aggregate device, so the echo reference arrives with the microphone.
class DeviceSource : public Source
{
public:
    DeviceSource(std::string key, std::string uid, bool echoCancel,
        MicProcessor::Isolation isolation, Retire retire);
    ~DeviceSource() override;

    bool Start(double busRate, uint32_t busFrames) override;
    void Stop() override;
    bool NeedsRestart() const override;
    std::string Detail() const override;

private:
    // Queues the microphone in this source's ring: its own buffers when unprocessed,
    // else the processed mono. The far end is not mixed.
    class Sink : public FrameSink
    {
    public:
        explicit Sink(DeviceSource& owner) : owner_(owner) {}
        void Prepare(double rate, uint32_t bufferFrames) override
        {
            owner_.Publish(rate, owner_.busRate_, bufferFrames, owner_.busFrames_);
        }
        void Stopped() override { owner_.Unpublish(); }
        void Raw(const AudioBufferList* input) override { owner_.Produce(input); }
        void Block(const float* me, const float*, uint32_t frames) override;

    private:
        DeviceSource& owner_;
    };

    double busRate_ = 0;
    uint32_t busFrames_ = 0;
    Sink sink_{*this};
    MicCapture mic_;
};

// Captures every audio process an app owns (see ProcessTap.hpp), following processes that
// start after capture began. With an instance, only the copy launched with that identity.
//
// System() captures everything the Mac plays instead, except this process and the app
// copies given to SetExcludedOwners: a mix's "System audio", which leaves out the apps
// reading that mix so a call through it never hears itself.
class AppSource : public Source
{
public:
    AppSource(std::string bundleID, std::optional<std::string> instance, Retire retire);
    static std::shared_ptr<AppSource> System(std::string key, Retire retire);
    ~AppSource() override;

    bool Start(double busRate, uint32_t busFrames) override;
    void Stop() override;

    // Control queue: re-reads the process list and updates the live tap if it changed.
    void RefreshProcesses() { tap_.RefreshProcesses(); }

    // Control queue: silences the app's own output while true, so a person can hear which
    // copy is which.
    void SetMuted(bool muted) { tap_.SetMuted(muted); }

    // Control queue, system audio only: the app copies, by owner pid, to leave out. Takes
    // effect at the next Start or RefreshProcesses.
    void SetExcludedOwners(std::vector<int> owners) { tap_.SetExcludedOwners(std::move(owners)); }

private:
    // Queues the tap's frames in this source's ring.
    class Sink : public FrameSink
    {
    public:
        explicit Sink(AppSource& owner) : owner_(owner) {}
        void Prepare(double rate, uint32_t bufferFrames) override
        {
            owner_.Publish(rate, owner_.busRate_, bufferFrames, owner_.busFrames_);
        }
        void Stopped() override { owner_.Unpublish(); }
        void Raw(const AudioBufferList* input) override { owner_.Produce(input); }

    private:
        AppSource& owner_;
    };

    AppSource(std::string key, TapTarget target, Retire retire);

    double busRate_ = 0;
    uint32_t busFrames_ = 0;
    Sink sink_{*this};
    ProcessTap tap_;
};

// Plays one mix to the default output in real time, for checking it on headphones. The
// bus thread feeds it and the output device's IO thread pulls it, through the same ring
// and drift control a source uses, with the roles reversed.
class MonitorOutput : public Source
{
public:
    explicit MonitorOutput(Retire retire);
    ~MonitorOutput() override;

    bool Start(double busRate, uint32_t busFrames) override;
    void Stop() override;

    // Bus thread.
    void Feed(const float* stereo, uint32_t frames);

private:
    static OSStatus IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
        const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*, void* context);

    AudioObjectID device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID proc_ = nullptr;
    std::vector<float> scratch_;
};

} // namespace blend
