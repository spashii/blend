#pragma once

// A tap on the audio of one app, or of everything the Mac plays, read through a private
// aggregate device that supplies the clock. Hands the tap's buffers to a FrameSink on the
// aggregate's IO thread.

#include "Capture.hpp"

#include <CoreAudio/CoreAudio.h>

#include <atomic>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace blend {

// What to capture. An app means every audio process its app copy owns (see Apps.hpp),
// following processes that start after capture began; with an instance, only the copy
// launched with that identity. System means everything the Mac plays except this process
// and the app copies given to SetExcludedOwners.
struct TapTarget
{
    std::string bundleID;
    std::optional<std::string> instance;
    bool system = false;
};

class ProcessTap
{
public:
    // The tap and its aggregate are named "<prefix>: <bundle id>" or "<prefix>: system
    // audio", which is what other apps' audio lists show for them.
    ProcessTap(TapTarget target, std::string namePrefix);
    ~ProcessTap();

    ProcessTap(const ProcessTap&) = delete;
    ProcessTap& operator=(const ProcessTap&) = delete;

    // Control queue. Calls sink.Prepare, starts the IO, and from then on calls sink.Raw.
    // The sink must outlive the tap's Stop.
    bool Start(FrameSink& sink);
    // Calls sink.Stopped once the IO has stopped.
    void Stop();
    bool Running() const { return proc_ != nullptr; }

    // Any thread. The clock device's input channels and the tap's channels, as they sit
    // in the aggregate's buffers, and how many buffers did not match that layout.
    uint32_t DeviceChannels() const { return deviceChannels_; }
    uint32_t TapChannels() const { return tapChannels_; }
    uint64_t ChannelMismatches() const { return mismatches_.load(std::memory_order_relaxed); }

    // Control queue: re-reads the process list and updates the live tap if it changed.
    void RefreshProcesses();

    // Control queue: silences the app's own output while true, so a person can hear which
    // copy is which.
    void SetMuted(bool muted);

    // Control queue, system audio only: the app copies, by owner pid, to leave out. Takes
    // effect at the next Start or RefreshProcesses.
    void SetExcludedOwners(std::vector<int> owners) { excludedOwners_ = std::move(owners); }

    // The audio processes a target covers now, sorted; for system audio, the ones to leave
    // out. Shared with the echo reference of a MicCapture that taps a call app.
    static std::vector<AudioObjectID> Matching(const TapTarget& target,
        const std::vector<int>& excludedOwners);

private:
    static OSStatus IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
        const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context);
    std::vector<AudioObjectID> MatchingProcesses() const { return Matching(target_, excludedOwners_); }

    const TapTarget target_;
    const std::string namePrefix_;
    std::vector<int> excludedOwners_;
    bool muted_ = false;
    FrameSink* sink_ = nullptr;
    // Set before the IO starts, read by the IO thread.
    uint32_t deviceChannels_ = 0;
    uint32_t tapChannels_ = 0;
    std::atomic<uint64_t> mismatches_{0};
    void* description_ = nullptr; // CATapDescription, retained
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID aggregate_ = kAudioObjectUnknown;
    AudioDeviceIOProcID proc_ = nullptr;
    std::vector<AudioObjectID> processes_;
};

} // namespace blend
