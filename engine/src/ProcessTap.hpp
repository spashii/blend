#pragma once

// A tap on the audio of one app, or of everything the Mac plays, read through a private
// aggregate device that supplies the clock. Hands the tap's buffers to a FrameSink on the
// aggregate's IO thread.

#include "Capture.hpp"

#include <CoreAudio/CoreAudio.h>

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

    // Control queue: re-reads the process list and updates the live tap if it changed.
    void RefreshProcesses();

    // Control queue: silences the app's own output while true, so a person can hear which
    // copy is which.
    void SetMuted(bool muted);

    // Control queue, system audio only: the app copies, by owner pid, to leave out. Takes
    // effect at the next Start or RefreshProcesses.
    void SetExcludedOwners(std::vector<int> owners) { excludedOwners_ = std::move(owners); }

private:
    static OSStatus IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
        const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context);
    // The processes to capture, or for system audio the ones to leave out.
    std::vector<AudioObjectID> MatchingProcesses() const;

    const TapTarget target_;
    const std::string namePrefix_;
    std::vector<int> excludedOwners_;
    bool muted_ = false;
    FrameSink* sink_ = nullptr;
    void* description_ = nullptr; // CATapDescription, retained
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID aggregate_ = kAudioObjectUnknown;
    AudioDeviceIOProcID proc_ = nullptr;
    std::vector<AudioObjectID> processes_;
};

} // namespace blend
