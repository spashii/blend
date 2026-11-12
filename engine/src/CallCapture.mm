#include "CallCapture.hpp"

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
        options.target = TapTarget{options_.callBundleID, options_.callInstance, false};
        options.tapPrefix = options_.label;
        return std::make_unique<CoreAudioBackend>(std::move(options));
    }

    bool CanTapCall(std::string& reason) override
    {
        const auto processes =
            ProcessTap::Matching(TapTarget{options_.callBundleID, options_.callInstance, false}, {});
        NSMutableArray* numbers = [NSMutableArray array];
        for (AudioObjectID process : processes) {
            [numbers addObject:@(process)];
        }
        CATapDescription* description =
            [[CATapDescription alloc] initStereoMixdownOfProcesses:numbers];
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
        for (AudioObjectID process :
            ProcessTap::Matching(TapTarget{options_.callBundleID, options_.callInstance, false}, {})) {
            UInt32 running = 0;
            if (hal::Get(process, kAudioProcessPropertyIsRunningOutput, running) && running) {
                return true;
            }
        }
        return false;
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
    std::string microphoneUID;
    double missingSince = -1;
    double lastAttempt = 0;
    double lastTapTry = 0;
    double lastTick = 0;
    double stalledFor = 0;
    uint64_t lastPushes = 0;
    uint64_t restarts = 0;
    std::unique_ptr<RepeatingTimer> ticker;

    // Delivery queue.
    std::unique_ptr<RepeatingTimer> delivering;
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
    dispatch_queue_set_specific(delivery_, &deliveryKey, &deliveryKey, nullptr);
    state_ = std::make_unique<State>(timing_.silentAfter);
    state_->ticker = std::make_unique<RepeatingTimer>(control_, Nanoseconds(timing_.tick),
        Nanoseconds(timing_.tick / 10), ^{ Tick(); });
    state_->delivering = std::make_unique<RepeatingTimer>(delivery_, 10'000'000, 2'000'000,
        ^{ DrainDelivery(); });
}

CallCapture::~CallCapture()
{
    Stop();
    dispatch_sync(delivery_, ^{});
    dispatch_sync(control_, ^{
        alive_->store(false);
        state_->observation.reset();
        ReleasePipeline();
    });
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
        s.microphoneUID = options_.microphoneUID.empty() ? environment_->DefaultMicrophone()
                                                         : options_.microphoneUID;
        s.withTap = false;
        s.tapLost = s.microphoneLost = s.echoFailed = false;
        s.missingSince = -1;
        s.restarts = 0;
        s.silence.Reset();
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
            if (!alive->load()) {
                return;
            }
            State& now = *state_;
            if (!now.running) {
                return;
            }
            if (change == SystemChange::Processes && now.backend) {
                now.backend->RefreshProcesses();
            }
            if (change == SystemChange::ServiceRestarted) {
                Emit(CallEvent::AudioServiceRestarted);
            }
            if (now.settling) {
                return;
            }
            now.settling = true;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(timing_.settle * 1e9)),
                control_, ^{
                    if (!alive->load()) {
                        return;
                    }
                    state_->settling = false;
                    Reconcile(change == SystemChange::ServiceRestarted);
                });
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

void CallCapture::Stop()
{
    __block bool had = false;
    dispatch_sync(control_, ^{
        State& s = *state_;
        had = s.pipeline != nullptr;
        s.running = false;
        s.ticker->Stop();
        s.observation.reset();
        StopBackend();
    });
    if (!had) {
        return;
    }
    if (dispatch_get_specific(&deliveryKey)) {
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
        out << (s.running ? "running" : "stopped");
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
    if (sink_->Detach()) {
        s.pipeline.reset();
    } else {
        // A reader never left; leaking one pipeline beats freeing it under that reader.
        (void)s.pipeline.release();
    }
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
// rate, and the call tap. `force` rebuilds even when nothing looks different.
void CallCapture::Reconcile(bool force)
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
            if (now - s.lastTapTry < timing_.retry) {
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
        if (s.tapLost) {
            s.tapLost = false;
            s.silence.Reset();
            Emit(CallEvent::CallTapRestored);
        }
    } else if (StartBackend(false)) {
        s.lastTapTry = now;
        s.silence.Reset();
        if (!s.tapLost) {
            s.tapLost = true;
            std::string reason;
            if (environment_->CanTapCall(reason)) {
                reason = "the microphone and the call app's audio could not be started together";
            }
            Emit(CallEvent::CallTapLost, reason);
        }
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
    if (s.missingSince >= 0 || s.microphoneLost || microphoneCause) {
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
        switch (s.silence.Tick(heard, environment_->CallIsPlaying(), dt)) {
        case SilenceDetector::Change::Silent: Emit(CallEvent::CallSilent); break;
        case SilenceDetector::Change::Heard: Emit(CallEvent::CallHeard); break;
        case SilenceDetector::Change::None: break;
        }
    }
    if (!s.echoFailed && s.backend->EchoCancelFailed()) {
        s.echoFailed = true;
        Emit(CallEvent::EchoCancellationFailed);
    }
}

// Delivery queue.
void CallCapture::DrainDelivery()
{
    State& s = *state_;
    CallPipeline* pipeline = s.pipeline.get();
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
