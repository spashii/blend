#include "CallCapture.hpp"

#include "Apps.hpp"
#include "HAL.hpp"
#include "MicCapture.hpp"
#include "ProcessTap.hpp"
#include "RepeatingTimer.hpp"

#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <sstream>
#include <thread>

namespace blend {

namespace {

constexpr uint32_t kDefaultRate = 48000;
// Tags a capture's delivery queue with the capture, so Stop can tell its own callback from
// another capture's.
char deliveryKey;

double Now()
{
    return CallPipeline::HostSeconds();
}

uint64_t Nanoseconds(double seconds)
{
    return uint64_t(std::max(0.001, seconds) * 1e9);
}

// The Core Audio side

class CoreAudioBackend : public CaptureBackend
{
public:
    explicit CoreAudioBackend(MicCapture::Options options)
        : capture_(std::move(options))
    {
    }
    ~CoreAudioBackend() override { capture_.Stop(); }

    bool Start(FrameSink& sink) override { return capture_.Start(sink); }
    void Stop() override { capture_.Stop(); }
    bool NeedsRestart() const override { return capture_.NeedsRestart(); }
    void RefreshProcesses() override { capture_.RefreshProcesses(); }
    bool EchoCancelFailed() const override { return capture_.EchoCancelFailed(); }
    std::string Describe() const override
    {
        std::ostringstream out;
        out << " io-rate=" << capture_.Rate() << " mic-channels=" << capture_.MicChannels();
        if (capture_.ChannelMismatches()) {
            out << " channel-mismatches=" << capture_.ChannelMismatches();
        }
        out << capture_.Describe();
        return out.str();
    }

private:
    MicCapture capture_;
};

// A tap of the call app on its own aggregate, the way Probes meters an app.
class CoreAudioProbe : public CallProbe, FrameSink
{
public:
    CoreAudioProbe(TapTarget target, const std::string& label)
        : system_(target.system)
        , tap_(std::move(target), label + " probe")
    {
    }
    ~CoreAudioProbe() override { tap_.Stop(); }

    bool Start()
    {
        hal::Get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, output_);
        if (system_) {
            tap_.SetExcludedOwners(SystemAudioExcludedOwners());
        }
        return tap_.Start(*this);
    }
    bool TakeHeard() override { return heard_.exchange(false, std::memory_order_relaxed); }
    void RefreshProcesses() override
    {
        if (system_) {
            tap_.SetExcludedOwners(SystemAudioExcludedOwners());
        }
        tap_.RefreshProcesses();
    }
    // The tap's aggregate is clocked by the output device it started on.
    bool Stale() override
    {
        AudioObjectID output = kAudioObjectUnknown;
        hal::Get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, output);
        return output != output_;
    }

    // IO thread.
    void Raw(const AudioBufferList* input, routing::ChannelSpan span) override
    {
        if (heard_.load(std::memory_order_relaxed)) {
            return;
        }
        for (uint32_t index = span.first; span.count == 0 || index < span.first + span.count;
             index++) {
            const routing::Channel channel = routing::ChannelAt(input, index);
            if (!channel) {
                break;
            }
            for (uint32_t i = 0, n = routing::Frames(input); i < n; i++) {
                if (channel[i] != 0.0f) {
                    heard_.store(true, std::memory_order_relaxed);
                    return;
                }
            }
        }
    }

private:
    const bool system_;
    ProcessTap tap_;
    AudioObjectID output_ = kAudioObjectUnknown;
    std::atomic<bool> heard_{false};
};

// Removes its listeners when destroyed. The blocks run on the queue they were added with.
struct Listeners
{
    using Entry = SystemListener;
    dispatch_queue_t queue;
    std::vector<Entry> entries;

    ~Listeners()
    {
        for (auto& entry : entries) {
            auto address = hal::Address(entry.selector);
            AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, queue,
                entry.block);
        }
    }
};

class CoreAudioEnvironment : public CallEnvironment
{
public:
    explicit CoreAudioEnvironment(CallCaptureOptions options)
        : options_(std::move(options))
    {
    }

    std::string DefaultMicrophone() override
    {
        AudioObjectID device = kAudioObjectUnknown;
        hal::Get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultInputDevice, device);
        return device == kAudioObjectUnknown
            ? std::string()
            : hal::GetString(device, kAudioDevicePropertyDeviceUID);
    }

    bool IsPhysical(const std::string& uid) override
    {
        return hal::IsPhysicalInput(hal::DeviceForUID(uid));
    }

    std::unique_ptr<CaptureBackend> MakeBackend(const BackendRequest& request) override
    {
        MicCapture::Options options;
        options.uid = request.microphoneUID;
        options.reference =
            request.callTap ? MicCapture::Reference::Processes : MicCapture::Reference::None;
        options.echoCancel = request.echoCancel;
        options.isolation = request.isolation;
        // The far end only travels in 10 ms blocks, and Me should keep one shape whether or
        // not the tap is there.
        options.passThrough = true;
        options.queue = request.queue;
        options.onRateChange = request.rateChanged;
        options.target = Target();
        if (options_.callSystemAudio) {
            options.excludedApps = SystemAudioExclusions();
        }
        options.tapPrefix = options_.label;
        return std::make_unique<CoreAudioBackend>(std::move(options));
    }

    bool CanTapCall(std::string& reason) override
    {
        const auto processes = ProcessTap::Matching(Target(), Excluded());
        NSMutableArray* numbers = [NSMutableArray array];
        for (AudioObjectID process : processes) {
            [numbers addObject:@(process)];
        }
        CATapDescription* description = options_.callSystemAudio
            ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:numbers]
            : [[CATapDescription alloc] initStereoMixdownOfProcesses:numbers];
        description.name = [NSString stringWithFormat:@"%s: probe", options_.label.c_str()];
        description.privateTap = YES;
        AudioObjectID tap = kAudioObjectUnknown;
        const OSStatus status = AudioHardwareCreateProcessTap(description, &tap);
        if (status != noErr) {
            reason = "Core Audio refused a tap of the call app's audio (status " +
                     std::to_string(status) + ")";
            return false;
        }
        AudioHardwareDestroyProcessTap(tap);
        return true;
    }

    bool CallIsPlaying() override
    {
        std::vector<AudioObjectID> processes = ProcessTap::Matching(Target(), Excluded());
        if (options_.callSystemAudio) {
            // Matching gives the processes left out; everything else counts.
            const auto excluded = std::move(processes);
            processes.clear();
            for (AudioObjectID process : hal::GetArray<AudioObjectID>(kAudioObjectSystemObject,
                     kAudioHardwarePropertyProcessObjectList)) {
                if (std::find(excluded.begin(), excluded.end(), process) == excluded.end()) {
                    processes.push_back(process);
                }
            }
        }
        for (AudioObjectID process : processes) {
            UInt32 running = 0;
            if (hal::Get(process, kAudioProcessPropertyIsRunningOutput, running) && running) {
                return true;
            }
        }
        return false;
    }

    std::unique_ptr<CallProbe> MakeProbe() override
    {
        auto probe = std::make_unique<CoreAudioProbe>(Target(), options_.label);
        return probe->Start() ? std::move(probe) : nullptr;
    }

    std::shared_ptr<void> Observe(dispatch_queue_t queue,
        std::function<void(SystemChange)> changed) override
    {
        auto listeners = std::make_shared<Listeners>();
        listeners->queue = queue;
        for (auto& entry : SystemListenerBlocks(std::move(changed))) {
            auto address = hal::Address(entry.selector);
            AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, queue,
                entry.block);
            listeners->entries.push_back(std::move(entry));
        }
        return listeners;
    }

private:
    std::vector<int> Excluded() const
    {
        return options_.callSystemAudio ? SystemAudioExcludedOwners() : std::vector<int>{};
    }

    TapTarget Target() const
    {
        return TapTarget{options_.callBundleID, options_.callInstance, options_.callSystemAudio};
    }

    const CallCaptureOptions options_;
};

} // namespace

std::vector<SystemListener> SystemListenerBlocks(std::function<void(SystemChange)> changed)
{
    std::vector<SystemListener> blocks;
    auto add = [&](AudioObjectPropertySelector selector, SystemChange change) {
        // Each block owns a copy: this function's argument is gone when it returns, and the
        // blocks run for as long as they are registered.
        std::function<void(SystemChange)> handler = changed;
        AudioObjectPropertyListenerBlock block =
            ^(UInt32, const AudioObjectPropertyAddress*) { handler(change); };
        blocks.push_back({selector, block});
    };
    add(kAudioHardwarePropertyDevices, SystemChange::Devices);
    add(kAudioHardwarePropertyDefaultInputDevice, SystemChange::Devices);
    add(kAudioHardwarePropertyProcessObjectList, SystemChange::Processes);
    add(kAudioHardwarePropertyServiceRestarted, SystemChange::ServiceRestarted);
    return blocks;
}

std::unique_ptr<CallEnvironment> MakeCoreAudioEnvironment(const CallCaptureOptions& options)
{
    return std::make_unique<CoreAudioEnvironment>(options);
}

// The IO thread's entry. It reads one pointer; the control queue clears it and waits for the
// readers that already hold it before it frees the pipeline, so nothing here needs a lock.
struct CallCapture::Sink : FrameSink
{
    std::atomic<CallPipeline*> pipeline{nullptr};
    std::atomic<int> inside{0};

    void Prepare(double rate, uint32_t) override
    {
        if (auto* p = pipeline.load()) {
            p->Configure(rate);
        }
    }

    void Block(const float* me, const float* farEnd, uint32_t frames) override
    {
        inside.fetch_add(1);
        if (auto* p = pipeline.load()) {
            p->Push(me, farEnd, frames);
        }
        inside.fetch_sub(1);
    }

    // False when a reader never left, in which case the pipeline must not be freed.
    bool Detach()
    {
        pipeline.store(nullptr);
        for (int spins = 0; inside.load() != 0; spins++) {
            if (spins > 2000) {
                return false;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return true;
    }
};

struct CallCapture::State
{
    explicit State(double silentAfter)
        : silence(silentAfter)
    {
    }

    // Control queue.
    std::unique_ptr<CallPipeline> pipeline;
    std::unique_ptr<CaptureBackend> backend;
    std::shared_ptr<void> observation;
    SilenceDetector silence;
    bool running = false;
    bool withTap = false;
    bool tapLost = false;
    bool microphoneLost = false;
    bool echoFailed = false;
    bool settling = false;
    // Tells a dead tap from a quiet call app while Call is silent (see CallProbe).
    std::unique_ptr<CallProbe> probe;
    // The probe has heard the app, so it works.
    bool probeProven = false;
    double probeQuietFor = 0;
    double probeRenewAfter = 0;
    int probeFailures = 0;
    double lastNeeded = 0;
    double nextProbeTry = 0;
    // How long, and over how many ticks in a row, the probe heard sound that Call did not.
    double deadFor = 0;
    int deadTicks = 0;
    double lastDeadRebuild = 0;
    // How long Call has been zeros while the app's output runs.
    double zerosFor = 0;
    // A rebuild for a dead tap did not bring it back; reported as CallTapLost.
    bool tapDead = false;
    bool rebuiltForDeath = false;
    double nextDeadRebuild = 0;
    double deadDelay = 0;
    uint64_t deadRebuilds = 0;
    std::string microphoneUID;
    double missingSince = -1;
    double lastAttempt = 0;
    double lastTapTry = 0;
    // How long to leave the call tap alone after a try that could not start it beside the
    // microphone; each such try bounces the microphone's capture, so it grows.
    double tapDelay = 0;
    double lastTick = 0;
    double stalledFor = 0;
    uint64_t lastPushes = 0;
    uint64_t restarts = 0;
    std::unique_ptr<RepeatingTimer> ticker;

    // Delivery queue. `draining` is the control queue's pipeline as the delivery queue
    // knows it: set and cleared by blocks the control queue enqueues, so the pipeline is
    // freed only after the drain that might be reading it.
    std::unique_ptr<RepeatingTimer> delivering;
    CallPipeline* draining = nullptr;
    uint64_t reportedOverflows = 0;
};

CallCapture::CallCapture(CallCaptureOptions options, Frames frames, Events events,
    std::unique_ptr<CallEnvironment> environment, CallCaptureTiming timing)
    : options_([&] {
        CallCaptureOptions o = std::move(options);
        o.outputRate = o.outputRate ? o.outputRate : kDefaultRate;
        return o;
    }())
    , timing_(timing)
    , frames_(std::move(frames))
    , events_(std::move(events))
    , environment_(environment ? std::move(environment) : MakeCoreAudioEnvironment(options_))
    , sink_(new Sink)
{
    const std::string label = "app.blend.kit." + options_.label;
    control_ = dispatch_queue_create(label.c_str(),
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    delivery_ = dispatch_queue_create((label + ".delivery").c_str(),
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE,
            0));
    dispatch_queue_set_specific(delivery_, &deliveryKey, this, nullptr);
    state_ = std::make_unique<State>(timing_.silentAfter);
    state_->ticker = std::make_unique<RepeatingTimer>(control_, Nanoseconds(timing_.tick),
        Nanoseconds(timing_.tick / 10), ^{ Tick(); });
    state_->delivering = std::make_unique<RepeatingTimer>(delivery_, 10'000'000, 2'000'000,
        ^{ DrainDelivery(); });
}

CallCapture::~CallCapture()
{
    Stop();
    dispatch_sync(control_, ^{
        alive_->store(false);
        state_->observation.reset();
        ReleasePipeline();
    });
    // Waits for the release, and for any drain or event still queued.
    dispatch_sync(delivery_, ^{});
}

CallStart CallCapture::Start()
{
    __block CallStart result = CallStart::MicrophoneUnavailable;
    dispatch_sync(control_, ^{
        State& s = *state_;
        if (s.running) {
            result = CallStart::Started;
            return;
        }
        ReleasePipeline();
        s.pipeline = std::make_unique<CallPipeline>(options_.outputRate, timing_.ringSeconds);
        sink_->pipeline.store(s.pipeline.get());
        CallPipeline* started = s.pipeline.get();
        dispatch_async(delivery_, ^{ state_->draining = started; });
        s.microphoneUID = options_.microphoneUID.empty() ? environment_->DefaultMicrophone()
                                                         : options_.microphoneUID;
        s.withTap = false;
        s.tapLost = s.microphoneLost = s.echoFailed = false;
        s.missingSince = -1;
        s.restarts = 0;
        s.silence.Reset();
        s.probe.reset();
        s.probeRenewAfter = timing_.probeRenew;
        s.probeFailures = 0;
        s.nextProbeTry = 0;
        s.deadFor = s.zerosFor = s.lastDeadRebuild = 0;
        s.deadTicks = 0;
        s.tapDead = s.rebuiltForDeath = false;
        s.nextDeadRebuild = 0;
        s.deadDelay = timing_.deadRetry;
        s.deadRebuilds = 0;
        s.tapDelay = timing_.retry;
        if (!s.microphoneUID.empty() && StartBackend(true)) {
            result = CallStart::Started;
        } else if (!s.microphoneUID.empty() && StartBackend(false)) {
            // The microphone works, so the call app's audio is what could not start.
            StopBackend();
            result = CallStart::CallUnavailable;
        }
        if (result != CallStart::Started) {
            ReleasePipeline();
            return;
        }
        s.running = true;
        s.lastTick = s.lastAttempt = s.lastTapTry = Now();
        s.ticker->Start();
        auto alive = alive_;
        s.observation = environment_->Observe(control_, [this, alive](SystemChange change) {
            if (alive->load()) {
                OnSystemChange(change);
            }
        });
    });
    if (result == CallStart::Started) {
        dispatch_sync(delivery_, ^{
            state_->reportedOverflows = 0;
            state_->delivering->Start();
        });
    }
    return result;
}

// Control queue.
void CallCapture::OnSystemChange(SystemChange change)
{
    State& now = *state_;
    if (!now.running) {
        return;
    }
    // Something changed that the tap might have been waiting for.
    now.tapDelay = timing_.retry;
    now.lastTapTry = 0;
    if (change == SystemChange::Processes && now.backend) {
        now.backend->RefreshProcesses();
    }
    if (change == SystemChange::Processes && now.probe) {
        now.probe->RefreshProcesses();
    }
    // Making a probe changes this process's device list, so only a probe whose clock is gone
    // is replaced, never one that a device change merely followed.
    if (now.probe && (change == SystemChange::ServiceRestarted || now.probe->Stale())) {
        now.probe.reset();
    }
    if (change == SystemChange::ServiceRestarted) {
        Emit(CallEvent::AudioServiceRestarted);
    }
    if (now.settling) {
        return;
    }
    now.settling = true;
    auto alive = alive_;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(timing_.settle * 1e9)), control_, ^{
        if (!alive->load()) {
            return;
        }
        state_->settling = false;
        Reconcile(change == SystemChange::ServiceRestarted);
    });
}

void CallCapture::Stop()
{
    __block bool had = false;
    dispatch_sync(control_, ^{
        State& s = *state_;
        had = s.pipeline != nullptr;
        s.running = false;
        s.ticker->Stop();
        s.observation.reset();
        s.probe.reset();
        StopBackend();
    });
    if (!had) {
        return;
    }
    if (dispatch_get_specific(&deliveryKey) == this) {
        // Called from a callback, which is in the middle of draining the queue and goes on
        // delivering what the device had already produced. The pipeline it reads stays
        // until the next Start or the destructor.
        state_->delivering->Stop();
        dispatch_sync(control_, ^{ sink_->Detach(); });
        return;
    }
    // Everything the device produced before it stopped goes to the callback first.
    dispatch_sync(delivery_, ^{
        DrainDelivery();
        state_->delivering->Stop();
    });
    dispatch_sync(control_, ^{ ReleasePipeline(); });
}

std::string CallCapture::Diagnostics()
{
    __block std::string text;
    dispatch_sync(control_, ^{
        const State& s = *state_;
        std::ostringstream out;
        out << (s.running ? "running" : "stopped") << " call="
            << (options_.callSystemAudio ? "system-audio" : options_.callBundleID);
        if (s.running) {
            out << " microphone=" << s.microphoneUID << " call-tap="
                << (s.withTap ? "on" : (s.tapLost ? "lost" : "off"));
            if (s.microphoneLost) {
                out << " microphone-lost";
            }
            if (s.pipeline) {
                out << " input-rate=" << s.pipeline->InputRate()
                    << " output-rate=" << s.pipeline->OutputRate()
                    << " frames=" << s.pipeline->Position()
                    << " dropped=" << s.pipeline->DroppedFrames();
            }
            out << " restarts=" << s.restarts;
            if (s.deadRebuilds) {
                out << " dead-tap-rebuilds=" << s.deadRebuilds;
            }
            if (s.probe) {
                out << " probe=on";
            }
            if (s.probeFailures) {
                out << " probe-failures=" << s.probeFailures;
            }
            if (s.backend) {
                out << s.backend->Describe();
            }
        }
        text = out.str();
    });
    return text;
}

bool CallCapture::StartBackend(bool callTap)
{
    State& s = *state_;
    BackendRequest request;
    request.microphoneUID = s.microphoneUID;
    request.callTap = callTap;
    request.isolation = options_.isolation;
    request.echoCancel = callTap &&
        (options_.echo == EchoMode::On ||
            (options_.echo == EchoMode::Automatic && environment_->IsPhysical(s.microphoneUID)));
    // A rate change reaches Reconcile at once instead of at the next tick.
    auto alive = alive_;
    request.queue = control_;
    request.rateChanged = [this, alive] {
        if (alive->load()) {
            OnSystemChange(SystemChange::Devices);
        }
    };
    auto backend = environment_->MakeBackend(request);
    if (!backend) {
        return false;
    }
    if (!backend->Start(*sink_)) {
        backend->Stop();
        return false;
    }
    s.backend = std::move(backend);
    s.withTap = callTap;
    s.echoFailed = false;
    s.stalledFor = 0;
    s.lastPushes = s.pipeline->Pushes();
    return true;
}

void CallCapture::ReleasePipeline()
{
    State& s = *state_;
    if (!s.pipeline) {
        return;
    }
    const bool detached = sink_->Detach();
    CallPipeline* released = s.pipeline.release();
    // A drain may be reading it on the delivery queue, so it is freed there, after that
    // drain. When an IO reader never left, leaking one pipeline beats freeing it under that
    // reader.
    dispatch_async(delivery_, ^{
        state_->draining = nullptr;
        if (detached) {
            delete released;
        }
    });
}

void CallCapture::StopBackend()
{
    State& s = *state_;
    if (s.backend) {
        s.backend->Stop();
        s.backend.reset();
    }
    s.withTap = false;
}

void CallCapture::Emit(CallEvent event, std::string detail)
{
    dispatch_async(delivery_, ^{ events_(event, detail); });
}

// Brings the running capture in line with the system: the microphone it should follow, its
// rate, and the call tap. `force` rebuilds even when nothing looks different, and `quiet`
// does not report that as a restarted microphone.
void CallCapture::Reconcile(bool force, bool quiet)
{
    State& s = *state_;
    if (!s.running) {
        return;
    }
    const double now = Now();
    const std::string wanted = options_.microphoneUID.empty() ? environment_->DefaultMicrophone()
                                                              : options_.microphoneUID;
    bool microphoneCause = false;
    if (s.backend) {
        if (wanted != s.microphoneUID || s.backend->NeedsRestart() || force) {
            microphoneCause = true;
        } else if (!s.withTap) {
            // The tap alone can be tried without touching the microphone's capture.
            if (now - s.lastTapTry < s.tapDelay) {
                return;
            }
            s.lastTapTry = now;
            std::string reason;
            if (!environment_->CanTapCall(reason)) {
                return;
            }
        } else {
            return;
        }
        StopBackend();
    }
    s.lastAttempt = now;
    s.microphoneUID = wanted;
    s.restarts++;
    if (wanted.empty()) {
        // No input device now: wait for one.
    } else if (StartBackend(true)) {
        s.tapDelay = timing_.retry;
        if (s.tapLost) {
            s.tapLost = false;
            s.silence.Reset();
            Emit(CallEvent::CallTapRestored);
        }
    } else if (StartBackend(false)) {
        s.lastTapTry = now;
        // Each try reopens the microphone, so the wait grows; while the app plays, it stays
        // short enough that the call comes back within seconds.
        const double ceiling =
            environment_->CallIsPlaying() ? timing_.deadRetryCeiling : timing_.retryCeiling;
        s.tapDelay = s.tapLost ? std::min(s.tapDelay * 2, ceiling) : timing_.retry;
        s.silence.Reset();
        s.rebuiltForDeath = false;
        if (!s.tapLost && !s.tapDead) {
            std::string reason;
            if (environment_->CanTapCall(reason)) {
                reason = "the microphone and the call app's audio could not be started together";
            }
            Emit(CallEvent::CallTapLost, reason);
        }
        s.tapLost = true;
        s.tapDead = false;
    }
    if (!s.backend) {
        if (s.missingSince < 0) {
            s.missingSince = now;
        }
        if (!s.microphoneLost && now - s.missingSince >= timing_.microphoneLostAfter) {
            s.microphoneLost = true;
            Emit(CallEvent::MicrophoneLost);
        }
        return;
    }
    if (s.missingSince >= 0 || s.microphoneLost || (microphoneCause && !quiet)) {
        s.missingSince = -1;
        s.microphoneLost = false;
        Emit(CallEvent::MicrophoneRestarted);
    }
}

void CallCapture::Tick()
{
    State& s = *state_;
    if (!s.running) {
        return;
    }
    const double now = Now();
    const double dt = now - s.lastTick;
    s.lastTick = now;
    if (!s.backend) {
        if (now - s.lastAttempt >= timing_.retry) {
            Reconcile(false);
        } else if (s.missingSince >= 0 && !s.microphoneLost &&
                   now - s.missingSince >= timing_.microphoneLostAfter) {
            s.microphoneLost = true;
            Emit(CallEvent::MicrophoneLost);
        }
        return;
    }
    const uint64_t pushes = s.pipeline->Pushes();
    if (pushes != s.lastPushes) {
        s.lastPushes = pushes;
        s.stalledFor = 0;
    } else {
        s.stalledFor += dt;
    }
    if (timing_.stallAfter > 0 && s.stalledFor >= timing_.stallAfter) {
        Reconcile(true);
        return;
    }
    Reconcile(false);
    if (!s.backend) {
        return;
    }
    const bool heard = s.pipeline->TakeHeard();
    if (s.withTap) {
        const bool playing = environment_->CallIsPlaying();
        switch (s.silence.Tick(heard, playing, dt)) {
        case SilenceDetector::Change::Silent: Emit(CallEvent::CallSilent); break;
        case SilenceDetector::Change::Heard: Emit(CallEvent::CallHeard); break;
        case SilenceDetector::Change::None: break;
        }
        WatchTap(heard, playing, now, dt);
        if (!s.backend) {
            return;
        }
    } else {
        s.probe.reset();
    }
    if (!s.echoFailed && s.backend->EchoCancelFailed()) {
        s.echoFailed = true;
        Emit(CallEvent::EchoCancellationFailed);
    }
}

// Rebuilds the capture only when its tap is dead: Call stays zeros while the probe hears the
// app. A rebuild that comes up dead too is retried with a growing wait, for as long as the
// call lasts; a tap can die on an output device change or come up dead on a busy Mac, and
// nothing else reports either.
void CallCapture::WatchTap(bool heard, bool playing, double now, double dt)
{
    State& s = *state_;
    const bool probeHeard = s.probe && s.probe->TakeHeard();
    if (probeHeard) {
        s.probeQuietFor = 0;
        s.probeProven = true;
        s.probeRenewAfter = timing_.probeRenew;
    }
    if (heard) {
        s.deadFor = 0;
        s.deadTicks = 0;
        if (s.tapDead) {
            s.tapDead = false;
            Emit(CallEvent::CallTapRestored);
        }
        // A tap that delivers for a moment and dies again keeps its backoff.
        if (s.rebuiltForDeath && now - s.lastDeadRebuild >= timing_.recoveredAfter) {
            s.rebuiltForDeath = false;
            s.nextDeadRebuild = 0;
            s.deadDelay = timing_.deadRetry;
        }
    }
    s.zerosFor = !heard && playing ? s.zerosFor + dt : 0;
    const bool needed = s.zerosFor >= timing_.probeAfter;
    if (!needed) {
        s.deadFor = 0;
        s.deadTicks = 0;
        s.probeQuietFor = 0;
        if (s.probe && now - s.lastNeeded >= timing_.probeLinger) {
            s.probe.reset();
        }
        return;
    }
    s.lastNeeded = now;
    // A probe whose output device is gone is made again at once. One that has never heard
    // the app may be dead itself, so it is made again, sooner at first; one that has heard
    // it is made again only after the longest wait, in case it died since.
    if (s.probe && s.probe->Stale()) {
        s.probe.reset();
    } else if (s.probe &&
               s.probeQuietFor >= (s.probeProven ? timing_.probeRenewCeiling : s.probeRenewAfter)) {
        s.probe.reset();
        if (!s.probeProven) {
            s.probeRenewAfter = std::min(s.probeRenewAfter * 2, timing_.probeRenewCeiling);
        }
    }
    if (!s.probe) {
        if (now < s.nextProbeTry) {
            return;
        }
        s.probe = environment_->MakeProbe();
        s.probeQuietFor = 0;
        s.probeProven = false;
        s.deadFor = 0;
        s.deadTicks = 0;
        if (s.probe) {
            s.probeFailures = 0;
            s.nextProbeTry = 0;
            // A blind rebuild's long wait does not hold back one the probe can confirm.
            s.nextDeadRebuild = std::min(s.nextDeadRebuild, now + timing_.deadRetryCeiling);
            return;
        }
        s.probeFailures++;
        s.nextProbeTry = now + timing_.retry;
        // Without a probe a dead tap cannot be told from a pause. Rather than leave Call dead
        // for the rest of the call, rebuild blind, as rarely as the backoff allows, and
        // without calling it a lost tap, since it may be a pause.
        if (s.probeFailures >= 3 && now >= s.nextDeadRebuild) {
            RebuildDeadTap(now, timing_.retryCeiling, false);
        }
        return;
    }
    if (!probeHeard) {
        s.probeQuietFor += dt;
        s.deadFor = 0;
        s.deadTicks = 0;
        return;
    }
    // Sound has to reach the probe and not the capture for a while, over more than one
    // tick, so sound that reaches the probe a moment before the capture is not a dead tap.
    s.deadFor += dt;
    if (++s.deadTicks < 2 || s.deadFor < timing_.deadAfter || now < s.nextDeadRebuild) {
        return;
    }
    RebuildDeadTap(now, timing_.deadRetryCeiling, true);
}

void CallCapture::RebuildDeadTap(double now, double ceiling, bool known)
{
    State& s = *state_;
    s.deadFor = 0;
    s.deadTicks = 0;
    s.deadRebuilds++;
    s.lastDeadRebuild = now;
    s.deadDelay = std::min(s.deadDelay, ceiling);
    if (known && s.rebuiltForDeath && !s.tapDead) {
        s.tapDead = true;
        Emit(CallEvent::CallTapLost, "the call app's audio stopped arriving");
    }
    s.rebuiltForDeath = true;
    s.nextDeadRebuild = now + s.deadDelay;
    s.deadDelay = std::min(s.deadDelay * 2, ceiling);
    Reconcile(true, true);
}

// Delivery queue.
void CallCapture::DrainDelivery()
{
    State& s = *state_;
    CallPipeline* pipeline = s.draining;
    if (!pipeline) {
        return;
    }
    pipeline->Drain([&](const float* me, const float* call, uint32_t frames, uint64_t position) {
        frames_(me, call, frames, position);
    });
    const uint64_t overflows = pipeline->Overflows();
    if (overflows != s.reportedOverflows) {
        s.reportedOverflows = overflows;
        events_(CallEvent::Overflow, std::to_string(pipeline->DroppedFrames()) + " frames dropped");
    }
}

} // namespace blend
