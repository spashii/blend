#pragma once

// Records both sides of a call: the microphone as Me and what a call app plays as Call, at
// the same instants and one rate, for a host that has no mixer or driver.
//
// The microphone and a tap of the call app's processes run in one private aggregate device,
// so both arrive in one IO cycle on one clock, and echo cancellation can use the call as its
// far end. The far-end copy that went into cancellation is delivered as Call, which keeps
// the two sides sample-aligned.
//
// Three threads, none of which waits on another:
//  - The device's IO thread runs a C callback that reads one atomic pipeline pointer and
//    writes a queue. It takes no lock and calls no Objective-C or Swift.
//  - The control queue (app.blend.kit.<label>) makes every device call: starting, stopping,
//    rebuilding after a device, rate or process change, and retrying. Stop is called there
//    and holds nothing the IO thread takes, so it cannot deadlock against a cycle in flight.
//  - A delivery queue drains the queue every 10 ms into the host's callbacks, so a host's
//    work (writing a file, running Swift) never delays the IO thread. About four seconds
//    fit; beyond that frames are dropped, counted and reported as an overflow.

#include "CallPipeline.hpp"
#include "Capture.hpp"
#include "MicProcessor.hpp"

#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace blend {

enum class CallEvent
{
    MicrophoneRestarted,
    MicrophoneLost,
    CallTapLost,
    CallTapRestored,
    CallSilent,
    CallHeard,
    EchoCancellationFailed,
    Overflow,
    AudioServiceRestarted,
};

enum class CallStart
{
    Started,
    MicrophoneUnavailable,
    CallUnavailable,
};

enum class EchoMode
{
    Off,
    On,
    // On for a physical microphone, off for a virtual or aggregate one, which often carries
    // what the Mac plays on purpose.
    Automatic,
};

struct CallCaptureOptions
{
    // Names the control queue and the call app's tap.
    std::string label = "Blend";
    // Empty follows the default input device.
    std::string microphoneUID;
    EchoMode echo = EchoMode::Automatic;
    MicProcessor::Isolation isolation = MicProcessor::Isolation::Off;
    std::string callBundleID;
    std::optional<std::string> callInstance;
    // Zero is 48000. Fixed for the life of the capture, whatever the devices do.
    uint32_t outputRate = 0;
};

struct CallCaptureTiming
{
    // Seconds. The defaults are the ones that ship; a test shortens them.
    double tick = 1;
    double retry = 2;
    // Retrying the call tap beside a working microphone backs off up to this.
    double retryCeiling = 60;
    double microphoneLostAfter = 10;
    double silentAfter = 3;
    // No frames for this long while running restarts the capture; 0 turns it off.
    double stallAfter = 3;
    double ringSeconds = 4;
    // Device changes arrive in bursts; the capture waits this long for them to settle.
    double settle = 0.15;
};

// One running capture of a microphone, with or without the call tap.
class CaptureBackend
{
public:
    virtual ~CaptureBackend() = default;
    // Control queue. Calls sink.Prepare, then the IO calls sink.Block.
    virtual bool Start(FrameSink& sink) = 0;
    virtual void Stop() = 0;
    virtual bool NeedsRestart() const = 0;
    virtual void RefreshProcesses() {}
    virtual bool EchoCancelFailed() const { return false; }
    virtual std::string Describe() const { return {}; }
};

struct BackendRequest
{
    std::string microphoneUID;
    bool callTap = true;
    bool echoCancel = false;
    MicProcessor::Isolation isolation = MicProcessor::Isolation::Off;
};

// What a change reported by the system was about.
enum class SystemChange
{
    Devices,
    Processes,
    ServiceRestarted,
};

// Everything CallCapture asks of Core Audio, so the real one can be replaced in a test.
class CallEnvironment
{
public:
    virtual ~CallEnvironment() = default;
    // The default input's UID, or empty when there is none.
    virtual std::string DefaultMicrophone() = 0;
    virtual bool IsPhysical(const std::string& microphoneUID) = 0;
    virtual std::unique_ptr<CaptureBackend> MakeBackend(const BackendRequest& request) = 0;
    // Whether the call app's audio can be tapped now, without touching the microphone.
    virtual bool CanTapCall(std::string& reason) = 0;
    // Whether a process of the call app is producing sound right now.
    virtual bool CallIsPlaying() = 0;
    // Calls changed on `queue` for each change until the returned token is destroyed.
    virtual std::shared_ptr<void> Observe(dispatch_queue_t queue,
        std::function<void(SystemChange)> changed) = 0;
};

// A Core Audio property listener that reports one kind of SystemChange.
struct SystemListener
{
    AudioObjectPropertySelector selector;
    AudioObjectPropertyListenerBlock block;
};

// The listeners the Core Audio environment registers on the system object, each owning its
// own copy of `changed`. Separate so a test can run them after the caller's copy is gone.
std::vector<SystemListener> SystemListenerBlocks(std::function<void(SystemChange)> changed);

std::unique_ptr<CallEnvironment> MakeCoreAudioEnvironment(const CallCaptureOptions& options);

class CallCapture
{
public:
    // Both run on the delivery queue. `frames` is Me and Call at the same instants, mono, at
    // the output rate; `position` counts output frames since Start, so it follows the clock
    // across restarts. The pointers are valid only during the call.
    using Frames = std::function<void(const float* me, const float* call, uint32_t frames,
        uint64_t position)>;
    using Events = std::function<void(CallEvent event, const std::string& detail)>;

    CallCapture(CallCaptureOptions options, Frames frames, Events events,
        std::unique_ptr<CallEnvironment> environment = nullptr, CallCaptureTiming timing = {});
    ~CallCapture();

    CallCapture(const CallCapture&) = delete;
    CallCapture& operator=(const CallCapture&) = delete;

    // Any thread but the capture's own queues. Blocks until the capture runs or has failed.
    // On a failure nothing is left running.
    CallStart Start();
    // Blocks until the device has stopped and every queued frame has gone to the callback.
    // Safe to call from a callback, which then returns to a drain that finishes the queue.
    void Stop();
    // A human-readable summary, for support.
    std::string Diagnostics();

private:
    struct Sink;
    struct State;

    void Reconcile(bool microphoneCause);
    void Tick();
    bool StartBackend(bool callTap);
    void StopBackend();
    void ReleasePipeline();
    void Emit(CallEvent event, std::string detail = {});
    void DrainDelivery();

    const CallCaptureOptions options_;
    const CallCaptureTiming timing_;
    const Frames frames_;
    const Events events_;
    std::unique_ptr<CallEnvironment> environment_;
    dispatch_queue_t control_;
    dispatch_queue_t delivery_;
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
    std::unique_ptr<Sink> sink_;
    std::unique_ptr<State> state_;
};

} // namespace blend
