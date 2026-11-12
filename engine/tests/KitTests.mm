// Checks BlendKit's call capture without a device: the pipeline's conversion and gap
// filling, the silence detector, the channel layout of the microphone-plus-tap aggregate, and
// the capture's threading and recovery against a fake device that runs its own IO thread.
// Nothing here opens a microphone or a tap. BLENDKIT_LIVE=1 adds a run against the real
// default devices, which a person starts on purpose.

#include "../include/BlendKit.h"
#include "../src/CallCapture.hpp"
#include "../src/CallPipeline.hpp"
#include "../src/MicProcessor.hpp"
#include "../src/Routing.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <future>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

using namespace blend;
using namespace std::chrono_literals;

namespace {

int failures = 0;

void Check(bool ok, const char* what, double value = 0)
{
    std::printf("%s %s (%.2f)\n", ok ? "ok  " : "FAIL", what, value);
    failures += ok ? 0 : 1;
}

void Sleep(int ms)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// Runs `body` and gives up on it after `seconds`: a deadlock is a failure, not a hung test.
void WithinTime(const char* what, double seconds, std::function<void()> body)
{
    auto done = std::make_shared<std::promise<void>>();
    auto future = done->get_future();
    std::thread([body = std::move(body), done] {
        body();
        done->set_value();
    }).detach();
    if (future.wait_for(std::chrono::duration<double>(seconds)) != std::future_status::ready) {
        std::printf("FAIL %s did not finish in %.0f s\n", what, seconds);
        std::exit(1);
    }
}

// Energy of one frequency in a signal (Goertzel), as the square of its amplitude.
double Tone(const std::vector<float>& x, size_t from, size_t count, double hz, double rate)
{
    const double w = 2 * M_PI * hz / rate;
    const double c = 2 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < from + count; i++) {
        const double s = x[i] + c * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    const double power = s1 * s1 + s2 * s2 - c * s1 * s2;
    return power * 4 / (double(count) * count);
}

double Db(double power)
{
    return 10 * std::log10(power + 1e-20);
}

double Rms(const std::vector<float>& x, size_t from, size_t count)
{
    double sum = 0;
    for (size_t i = from; i < from + count; i++) {
        sum += double(x[i]) * x[i];
    }
    return std::sqrt(sum / double(count));
}

double TailDb(const std::vector<float>& x, double seconds, double rate)
{
    const size_t n = size_t(seconds * rate);
    double sum = 0;
    for (size_t i = x.size() - n; i < x.size(); i++) {
        sum += double(x[i]) * x[i];
    }
    return 10 * std::log10(sum / double(n) + 1e-20);
}

// What a capture delivered, in order.
struct Stream
{
    std::mutex mutex;
    std::vector<float> me, call;
    std::vector<uint64_t> starts; // position of each chunk
    std::vector<uint32_t> sizes;
    std::vector<std::string> events;

    void Frames(const float* m, const float* c, uint32_t n, uint64_t position)
    {
        std::lock_guard lock(mutex);
        me.insert(me.end(), m, m + n);
        call.insert(call.end(), c, c + n);
        starts.push_back(position);
        sizes.push_back(n);
    }

    void Event(CallEvent event, const std::string&)
    {
        static const char* names[] = {"microphoneRestarted", "microphoneLost", "callTapLost",
            "callTapRestored", "callSilent", "callHeard", "echoCancellationFailed", "overflow",
            "audioServiceRestarted"};
        std::lock_guard lock(mutex);
        events.push_back(names[int(event)]);
    }

    // Every chunk starts where the one before it ended.
    bool Contiguous()
    {
        std::lock_guard lock(mutex);
        uint64_t expected = 0;
        for (size_t i = 0; i < starts.size(); i++) {
            if (starts[i] != expected) {
                return false;
            }
            expected += sizes[i];
        }
        return true;
    }

    int EventIndex(const std::string& name)
    {
        std::lock_guard lock(mutex);
        auto it = std::find(events.begin(), events.end(), name);
        return it == events.end() ? -1 : int(it - events.begin());
    }
};

// Buffers with a given channel layout, for the aggregate's routing.
struct Buffers
{
    explicit Buffers(std::vector<uint32_t> layout, uint32_t frames = 16)
    {
        storage.resize(sizeof(AudioBufferList) + sizeof(AudioBuffer) * layout.size());
        list = reinterpret_cast<AudioBufferList*>(storage.data());
        list->mNumberBuffers = UInt32(layout.size());
        data.resize(layout.size());
        uint32_t channel = 0;
        for (size_t b = 0; b < layout.size(); b++) {
            data[b].resize(size_t(layout[b]) * frames);
            for (uint32_t c = 0; c < layout[b]; c++, channel++) {
                for (uint32_t i = 0; i < frames; i++) {
                    data[b][size_t(i) * layout[b] + c] = float(channel + 1);
                }
            }
            list->mBuffers[b].mNumberChannels = layout[b];
            list->mBuffers[b].mDataByteSize = frames * layout[b] * sizeof(float);
            list->mBuffers[b].mData = data[b].data();
        }
    }
    std::vector<uint8_t> storage;
    AudioBufferList* list;
    std::vector<std::vector<float>> data;
};

// The pipeline

double fakeNow = 0;
double FakeClock()
{
    return fakeNow;
}

void PushTone(CallPipeline& pipeline, double rate, double meHz, double callHz, double seconds,
    size_t& sample, uint32_t block = 160)
{
    std::vector<float> me(block), call(block);
    const size_t total = size_t(seconds * rate);
    for (size_t done = 0; done < total; done += block) {
        for (uint32_t i = 0; i < block; i++) {
            const double t = double(sample + i) / rate;
            me[i] = float(0.2 * std::sin(2 * M_PI * meHz * t));
            call[i] = float(0.5 * std::sin(2 * M_PI * callHz * t));
        }
        pipeline.Push(me.data(), call.data(), block);
        sample += block;
    }
}

struct Drained
{
    std::vector<float> me, call;
    std::vector<uint64_t> starts;
    std::vector<uint32_t> sizes;
};

Drained DrainAll(CallPipeline& pipeline)
{
    Drained out;
    pipeline.Drain([&](const float* m, const float* c, uint32_t n, uint64_t position) {
        out.me.insert(out.me.end(), m, m + n);
        out.call.insert(out.call.end(), c, c + n);
        out.starts.push_back(position);
        out.sizes.push_back(n);
    });
    return out;
}

// The content of what comes out, not its shape: a tone on Call at the input rate has to
// arrive as the same frequency and level at the output rate, and Me must not be Call.
void ConversionTests()
{
    for (double rate : {16000.0, 44100.0, 8000.0}) {
        CallPipeline pipeline(48000, 10);
        pipeline.Configure(rate);
        size_t sample = 0;
        PushTone(pipeline, rate, 300, 1000, 3, sample, uint32_t(rate / 100));
        const auto out = DrainAll(pipeline);
        const size_t from = 48000, count = 96000;
        char name[160];
        if (out.call.size() < from + count) {
            Check(false, "enough output after conversion", double(out.call.size()));
            continue;
        }
        const double at1k = Tone(out.call, from, count, 1000, 48000);
        const double at3k = Tone(out.call, from, count, 3000, 48000);
        std::snprintf(name, sizeof name, "Call keeps its 1 kHz tone from %.0f Hz to 48 kHz", rate);
        Check(Db(at1k) - Db(at3k) > 40, name, Db(at1k) - Db(at3k));
        const double rms = Rms(out.call, from, count);
        std::snprintf(name, sizeof name, "Call keeps its level from %.0f Hz (rms 0.354)", rate);
        Check(std::fabs(rms - 0.5 / std::sqrt(2.0)) < 0.02, name, rms);
        const double me300 = Tone(out.me, from, count, 300, 48000);
        const double me1k = Tone(out.me, from, count, 1000, 48000);
        std::snprintf(name, sizeof name, "Me is its own 300 Hz tone, not Call, from %.0f Hz", rate);
        Check(Db(me300) - Db(me1k) > 40 && Rms(out.me, from, count) > 0.1, name,
            Rms(out.me, from, count));
        std::snprintf(name, sizeof name, "the output length matches the rate from %.0f Hz", rate);
        Check(std::llabs(llround(out.call.size()) - llround(3.0 * 48000)) < 400, name,
            double(out.call.size()));
    }
    {
        // Same rate: nothing is resampled, so nothing changes.
        CallPipeline pipeline(48000, 5);
        pipeline.Configure(48000);
        std::vector<float> me(480), call(480);
        for (uint32_t i = 0; i < 480; i++) {
            me[i] = float(i) / 1000;
            call[i] = -float(i) / 1000;
        }
        pipeline.Push(me.data(), call.data(), 480);
        const auto out = DrainAll(pipeline);
        Check(out.me == me && out.call == call, "the same rate passes samples through exactly");
        pipeline.Push(me.data(), nullptr, 480);
        const auto next = DrainAll(pipeline);
        Check(next.call == std::vector<float>(480, 0.0f) && next.me == me,
            "no call audio is silence beside Me");
    }
}

void GapTests()
{
    {
        CallPipeline pipeline(48000, 5, FakeClock);
        pipeline.Configure(48000);
        std::vector<float> block(480, 0.25f);
        fakeNow = 100;
        for (int i = 0; i < 10; i++, fakeNow += 0.01) {
            pipeline.Push(block.data(), block.data(), 480);
        }
        // A restart half a second long.
        pipeline.Configure(48000);
        fakeNow = 100.09 + 0.5;
        pipeline.Push(block.data(), block.data(), 480);
        const auto out = DrainAll(pipeline);
        uint64_t expected = 0;
        bool contiguous = true;
        for (size_t i = 0; i < out.starts.size(); i++) {
            contiguous = contiguous && out.starts[i] == expected;
            expected += out.sizes[i];
        }
        size_t silent = 0;
        for (size_t i = 4800; i < out.me.size(); i++) {
            if (out.me[i] == 0 && out.call[i] == 0) {
                silent++;
            }
        }
        Check(contiguous, "positions are contiguous across a restart");
        Check(std::fabs(double(silent) - 0.5 * 48000 + 480) < 960,
            "a half-second restart is filled with about half a second of silence",
            double(silent));
        Check(out.me.size() >= 4800 + 23000 + 480 && out.me.back() == 0.25f,
            "sound resumes after the silence", double(out.me.size()));
    }
    {
        // A consumer that falls behind loses audio, never time.
        CallPipeline pipeline(48000, 0.1, FakeClock);
        pipeline.Configure(48000);
        std::vector<float> block(480, 0.25f);
        fakeNow = 0;
        for (int i = 0; i < 20; i++, fakeNow += 0.01) {
            pipeline.Push(block.data(), block.data(), 480);
        }
        Check(pipeline.Overflows() > 0 && pipeline.DroppedFrames() > 0, "a full queue counts drops",
            double(pipeline.DroppedFrames()));
        const uint64_t dropped = pipeline.DroppedFrames();
        DrainAll(pipeline);
        pipeline.Push(block.data(), block.data(), 480);
        const auto out = DrainAll(pipeline);
        size_t total = 0;
        for (auto n : out.sizes) {
            total += n;
        }
        Check(total == dropped + 480 && out.starts.front() == 20 * 480 - dropped,
            "dropped frames come back as silence so later audio keeps its position",
            double(total));
    }
}

void SilenceTests()
{
    SilenceDetector detector(3);
    using Change = SilenceDetector::Change;
    bool early = false;
    for (int i = 0; i < 2; i++) {
        early |= detector.Tick(false, true, 1) != Change::None;
    }
    Check(!early, "two silent seconds are not yet silence");
    Check(detector.Tick(false, true, 1) == Change::Silent, "three silent seconds while playing is silence");
    Check(detector.Tick(false, true, 1) == Change::None, "silence is reported once");
    Check(detector.Tick(true, true, 1) == Change::Heard, "the first sound after silence is heard");
    Check(detector.Tick(true, true, 1) == Change::None, "sound is not reported again");

    SilenceDetector idle(3);
    bool reported = false;
    for (int i = 0; i < 10; i++) {
        reported |= idle.Tick(false, false, 1) != Change::None;
    }
    Check(!reported, "zeros from an app that is not playing are not silence");

    SilenceDetector broken(3);
    broken.Tick(false, true, 2);
    broken.Tick(true, true, 1);
    Check(broken.Tick(false, true, 2) == Change::None, "any sound restarts the window");
}

void LayoutTests()
{
    {
        Buffers input({2, 2});
        const auto route = routing::MicTap(input.list, 2, 2);
        Check(route.mic.data[0] == 1 && route.left.data[0] == 3 && route.right.data[0] == 4 &&
                  !route.mismatch,
            "a two-channel microphone puts the tap at channels 2 and 3");
    }
    {
        Buffers input({3});
        const auto route = routing::MicTap(input.list, 1, 2);
        Check(route.mic.data[0] == 1 && route.left[0] == 2 && route.right[0] == 3 &&
                  !route.mismatch,
            "one microphone channel, an interleaved stereo tap after it");
    }
    {
        Buffers input({1, 1, 1});
        const auto route = routing::MicTap(input.list, 1, 2);
        Check(route.left[0] == 2 && route.right[0] == 3 && !route.mismatch,
            "planar buffers are counted across");
    }
    {
        Buffers input({2});
        const auto route = routing::MicTap(input.list, 1, 1);
        Check(route.left[0] == 2 && route.right[0] == 2 && !route.mismatch,
            "a mono tap stands for both sides");
    }
    {
        // The device reports more input channels than the buffers carry: the tap is what
        // is left after the microphone's channels, never the microphone's own.
        Buffers input({4});
        const auto route = routing::MicTap(input.list, 3, 2);
        Check(route.mismatch && route.mic[0] == 1 && route.left[0] == 4 && route.right[0] == 4,
            "a layout that does not add up takes the channels left after the microphone's");
    }
    {
        Buffers input({3});
        const auto route = routing::MicTap(input.list, 3, 2);
        Check(route.mismatch && route.mic[0] == 1 && !route.left && !route.right,
            "no channel left after the microphone's means no echo reference");
    }
    {
        Buffers input({2});
        const auto route = routing::MicTap(input.list, 3, 2);
        Check(route.mismatch && !route.left && !route.right,
            "fewer channels than the microphone's has no reference either");
    }
}

// The fake device

struct World
{
    std::atomic<bool> tapBlocked{false};
    std::atomic<bool> micBroken{false};
    // Call is zeros from every backend started up to this many starts, as for a tap that
    // an output device change killed.
    std::atomic<int> deadTapStarts{0};
    // The tap can be tapped alone but not beside the microphone.
    std::atomic<bool> jointFails{false};
    std::atomic<bool> playing{true};
    std::atomic<bool> callTone{true};
    std::atomic<double> rate{48000};
    std::atomic<int> backends{0};
    std::atomic<int> starts{0};
    std::atomic<bool> unpaced{false};
    std::atomic<bool> straggle{false};
    std::mutex mutex;
    std::string defaultMic = "mic-a";
    std::vector<std::string> startedMics;
    // A signal to play instead of tones: mic and a mono far end, run through a real
    // MicProcessor the way MicCapture does.
    const std::vector<float>* micSignal = nullptr;
    const std::vector<float>* farSignal = nullptr;
    bool echoCancel = false;
    std::atomic<bool> signalDone{false};
    std::function<void(SystemChange)> notify;
    dispatch_queue_t queue = nullptr;

    void Trigger(SystemChange change)
    {
        std::function<void(SystemChange)> call;
        dispatch_queue_t q;
        {
            std::lock_guard lock(mutex);
            call = notify;
            q = queue;
        }
        if (call) {
            dispatch_async(q, ^{ call(change); });
        }
    }
    void SetMic(const std::string& uid)
    {
        std::lock_guard lock(mutex);
        defaultMic = uid;
    }
};

class FakeBackend : public CaptureBackend
{
public:
    FakeBackend(World& world, BackendRequest request)
        : world_(world)
        , request_(std::move(request))
    {
    }
    ~FakeBackend() override { Stop(); }

    bool Start(FrameSink& sink) override
    {
        if (world_.micBroken || (request_.callTap && (world_.tapBlocked || world_.jointFails))) {
            return false;
        }
        rate_ = world_.rate;
        sink_ = &sink;
        deadTap_ = world_.starts < world_.deadTapStarts;
        sink.Prepare(rate_, 480);
        world_.backends++;
        world_.starts++;
        {
            std::lock_guard lock(world_.mutex);
            world_.startedMics.push_back(request_.microphoneUID);
        }
        running_ = true;
        thread_ = std::thread([this] { Run(); });
        return true;
    }

    // Like AudioDeviceStop: returns once no IO is in flight.
    void Stop() override
    {
        if (!running_) {
            return;
        }
        running_ = false;
        thread_.join();
        world_.backends--;
    }

    bool NeedsRestart() const override { return running_ && world_.rate != rate_; }

private:
    static void Emit(void* context, const float* me, const float* farEnd, uint32_t frames)
    {
        auto self = static_cast<FakeBackend*>(context);
        self->sink_->Block(me, self->request_.callTap ? farEnd : nullptr, frames);
    }

    void Run()
    {
        if (world_.micSignal) {
            RunSignal();
            return;
        }
        const uint32_t block = uint32_t(rate_ / 100);
        std::vector<float> me(block), call(block);
        uint64_t sample = 0;
        // A device's cycles arrive on its clock, not one sleep after another.
        auto next = std::chrono::steady_clock::now();
        while (running_) {
            for (uint32_t i = 0; i < block; i++) {
                const double t = double(sample + i) / rate_;
                me[i] = float(0.2 * std::sin(2 * M_PI * 440 * t));
                call[i] = world_.callTone && !deadTap_ ? float(0.3 * std::sin(2 * M_PI * 1000 * t)) : 0.0f;
            }
            sample += block;
            sink_->Block(me.data(), request_.callTap ? call.data() : nullptr, block);
            next += 10ms;
            if (!world_.unpaced) {
                std::this_thread::sleep_until(next);
            }
        }
    }

    void RunSignal()
    {
        auto processor = MicProcessor::Create(rate_, world_.echoCancel && request_.callTap,
            MicProcessor::Isolation::Off, Emit, this, true);
        const auto& mic = *world_.micSignal;
        const auto& far = *world_.farSignal;
        constexpr uint32_t chunk = 512;
        std::vector<float> stereo(chunk * 2);
        for (size_t at = 0; at + chunk <= mic.size() && running_; at += chunk) {
            for (uint32_t i = 0; i < chunk; i++) {
                stereo[i * 2] = stereo[i * 2 + 1] = far[at + i];
            }
            processor->Process(&mic[at], 1, &stereo[0], 2, &stereo[1], 2, chunk);
        }
        world_.signalDone = true;
        while (running_) {
            std::this_thread::sleep_for(1ms);
        }
    }

    World& world_;
    const BackendRequest request_;
    FrameSink* sink_ = nullptr;
    double rate_ = 0;
    bool deadTap_ = false;
    std::atomic<bool> running_{false};
    std::thread thread_;
};

class FakeEnvironment : public CallEnvironment
{
public:
    explicit FakeEnvironment(World& world)
        : world_(world)
    {
    }

    std::string DefaultMicrophone() override
    {
        std::lock_guard lock(world_.mutex);
        return world_.defaultMic;
    }
    bool IsPhysical(const std::string&) override { return true; }
    std::unique_ptr<CaptureBackend> MakeBackend(const BackendRequest& request) override
    {
        return std::make_unique<FakeBackend>(world_, request);
    }
    bool CanTapCall(std::string& reason) override
    {
        reason = "injected";
        return !world_.tapBlocked;
    }
    bool CallIsPlaying() override { return world_.playing; }
    std::shared_ptr<void> Observe(dispatch_queue_t queue,
        std::function<void(SystemChange)> changed) override
    {
        {
            std::lock_guard lock(world_.mutex);
            world_.notify = std::move(changed);
            world_.queue = queue;
        }
        return std::shared_ptr<void>(nullptr, [&world = world_](void*) {
            std::lock_guard lock(world.mutex);
            world.notify = nullptr;
        });
    }

private:
    World& world_;
};

CallCaptureTiming FastTiming()
{
    CallCaptureTiming timing;
    timing.tick = 0.02;
    timing.retry = 0.06;
    timing.settle = 0.02;
    timing.microphoneLostAfter = 0.3;
    timing.silentAfter = 0.2;
    timing.stallAfter = 0;
    timing.ringSeconds = 4;
    return timing;
}

std::unique_ptr<CallCapture> MakeCapture(World& world, Stream& stream,
    CallCaptureTiming timing = FastTiming(), EchoMode echo = EchoMode::Off)
{
    CallCaptureOptions options;
    options.label = "test";
    options.callBundleID = "com.example.call";
    options.echo = echo;
    return std::make_unique<CallCapture>(options,
        [&stream](const float* m, const float* c, uint32_t n, uint64_t p) {
            stream.Frames(m, c, n, p);
        },
        [&stream](CallEvent e, const std::string& d) { stream.Event(e, d); },
        std::make_unique<FakeEnvironment>(world), timing);
}

void ThreadingTests()
{
    WithinTime("stop and destroy against a running IO thread", 60, [] {
        std::mt19937 random(3);
        for (int round = 0; round < 40; round++) {
            World world;
            world.unpaced = round % 2 == 0;
            Stream stream;
            auto capture = MakeCapture(world, stream);
            if (capture->Start() != CallStart::Started) {
                std::printf("FAIL start in round %d\n", round);
                failures++;
                return;
            }
            Sleep(int(random() % 8));
            // Stop from one thread while another reads diagnostics and a device change
            // lands, then destroy at once.
            std::thread diagnostics([&] {
                for (int i = 0; i < 5; i++) {
                    capture->Diagnostics();
                    Sleep(1);
                }
            });
            world.Trigger(SystemChange::Devices);
            capture->Stop();
            diagnostics.join();
            capture.reset();
            if (world.backends != 0) {
                std::printf("FAIL a backend outlived its capture in round %d\n", round);
                failures++;
                return;
            }
        }
        Check(true, "40 rounds of stop and destroy beside a running IO thread finish");
    });

    WithinTime("stop from inside the frames callback", 10, [] {
        World world;
        Stream stream;
        std::atomic<CallCapture*> self{nullptr};
        std::atomic<int> stops{0};
        CallCaptureOptions options;
        options.label = "reentrant";
        options.echo = EchoMode::Off;
        auto capture = std::make_unique<CallCapture>(options,
            [&](const float* m, const float* c, uint32_t n, uint64_t p) {
                stream.Frames(m, c, n, p);
                if (stops.fetch_add(1) == 2) {
                    self.load()->Stop();
                }
            },
            [](CallEvent, const std::string&) {}, std::make_unique<FakeEnvironment>(world),
            FastTiming());
        self = capture.get();
        capture->Start();
        for (int i = 0; i < 300 && world.backends > 0; i++) {
            Sleep(10);
        }
        Check(world.backends == 0, "a callback can stop the capture", double(world.backends));
        self = nullptr;
        capture.reset();
    });

    WithinTime("stop another capture from a callback", 10, [] {
        World worldA, worldB;
        Stream streamA, streamB;
        std::atomic<CallCapture*> other{nullptr};
        std::atomic<int> calls{0};
        CallCaptureOptions options;
        options.label = "first";
        options.echo = EchoMode::Off;
        auto a = std::make_unique<CallCapture>(options,
            [&](const float* m, const float* c, uint32_t n, uint64_t p) {
                streamA.Frames(m, c, n, p);
                if (calls.fetch_add(1) == 2) {
                    other.load()->Stop();
                }
            },
            [](CallEvent, const std::string&) {}, std::make_unique<FakeEnvironment>(worldA),
            FastTiming());
        auto b = MakeCapture(worldB, streamB);
        other = b.get();
        a->Start();
        b->Start();
        for (int i = 0; i < 300 && worldB.backends > 0; i++) {
            Sleep(10);
        }
        Check(worldB.backends == 0, "a callback can stop a different capture",
            double(worldB.backends));
        Check(streamB.Contiguous() && !streamB.me.empty(),
            "the other capture delivered what it had before it stopped");
        a->Stop();
        other = nullptr;
    });

    WithinTime("start failures", 10, [] {
        {
            World world;
            Stream stream;
            world.tapBlocked = true;
            auto capture = MakeCapture(world, stream);
            Check(capture->Start() == CallStart::CallUnavailable,
                "a tap that cannot start is callUnavailable");
            Check(world.backends == 0, "nothing is left running after callUnavailable",
                double(world.backends));
        }
        {
            World world;
            Stream stream;
            world.micBroken = true;
            world.tapBlocked = true;
            auto capture = MakeCapture(world, stream);
            Check(capture->Start() == CallStart::MicrophoneUnavailable,
                "no microphone is microphoneUnavailable, whatever the tap does");
        }
    });
}

void RecoveryTests()
{
    WithinTime("tap lost and restored", 20, [] {
        World world;
        Stream stream;
        auto capture = MakeCapture(world, stream);
        Check(capture->Start() == CallStart::Started, "the capture starts");
        Sleep(300);
        // The tap goes away and cannot come back for a while: the audio service restarted.
        world.tapBlocked = true;
        world.Trigger(SystemChange::ServiceRestarted);
        Sleep(500);
        world.tapBlocked = false;
        Sleep(600);
        capture->Stop();
        const int lost = stream.EventIndex("callTapLost");
        const int restored = stream.EventIndex("callTapRestored");
        Check(lost >= 0 && restored > lost, "callTapLost comes before callTapRestored", restored);
        Check(stream.EventIndex("audioServiceRestarted") >= 0, "the service restart is reported");
        {
            std::lock_guard lock(stream.mutex);
            int lostCount = int(std::count(stream.events.begin(), stream.events.end(), "callTapLost"));
            Check(lostCount == 1, "callTapLost is reported once", lostCount);
        }
        Check(stream.Contiguous(), "frames are continuous through the loss and the recovery");
        std::lock_guard lock(stream.mutex);
        // Mic alone runs while the tap is gone: a long stretch of Me with Call at zero.
        size_t run = 0, longest = 0;
        for (size_t i = 0; i < stream.me.size(); i++) {
            if (stream.call[i] == 0 && stream.me[i] != 0) {
                longest = std::max(longest, ++run);
            } else if (stream.call[i] != 0) {
                run = 0;
            }
        }
        Check(longest > 48000 * 0.2, "Me continues alone while the tap is lost", double(longest));
        Check(Rms(stream.call, stream.call.size() - 4800, 4800) > 0.1,
            "Call is back after the tap is restored", Rms(stream.call, stream.call.size() - 4800, 4800));
        Check(stream.me.size() > 48000 * 1.2, "the stream kept pace with the clock",
            double(stream.me.size()));
    });

    WithinTime("a tap that cannot join the microphone backs off", 20, [] {
        World world;
        Stream stream;
        CallCaptureTiming timing = FastTiming();
        timing.retryCeiling = 0.5;
        auto capture = MakeCapture(world, stream, timing);
        capture->Start();
        Sleep(200);
        world.jointFails = true;
        world.Trigger(SystemChange::ServiceRestarted);
        Sleep(200);
        const int before = world.starts;
        Sleep(1500);
        // Every try restarts the microphone's capture; at the fixed 60 ms there would be 25.
        const int tries = world.starts - before;
        Check(tries <= 8, "the microphone is not restarted every retry interval", tries);
        const int quiet = world.starts;
        world.Trigger(SystemChange::Devices);
        Sleep(300);
        Check(world.starts > quiet, "a system change tries the tap at once", world.starts - quiet);
        world.jointFails = false;
        world.Trigger(SystemChange::Devices);
        Sleep(400);
        Check(stream.EventIndex("callTapRestored") >= 0, "the tap comes back when it can");
        capture->Stop();
    });

    WithinTime("silence is reported while the app plays", 20, [] {
        World world;
        Stream stream;
        world.callTone = false;
        auto capture = MakeCapture(world, stream);
        capture->Start();
        Sleep(600);
        Check(stream.EventIndex("callSilent") >= 0, "callSilent after zeros while the app plays");
        world.callTone = true;
        Sleep(400);
        const int silent = stream.EventIndex("callSilent"), heard = stream.EventIndex("callHeard");
        Check(heard > silent, "callHeard follows the first sound", heard);
        capture->Stop();
    });

    WithinTime("silence rebuilds the tap once", 20, [] {
        World world;
        Stream stream;
        world.deadTapStarts = 1;
        auto capture = MakeCapture(world, stream);
        capture->Start();
        Sleep(900);
        Check(stream.EventIndex("callSilent") >= 0, "the dead tap is reported");
        Check(world.starts == 2, "and rebuilt once", world.starts);
        Check(stream.EventIndex("callHeard") > stream.EventIndex("callSilent"),
            "Call is heard after the rebuild");
        Check(stream.EventIndex("microphoneRestarted") < 0,
            "the rebuild is not a microphone restart");
        capture->Stop();
        // A call app that is quiet for real is not rebuilt again and again.
        World quiet;
        Stream quietStream;
        quiet.callTone = false;
        auto other = MakeCapture(quiet, quietStream);
        other->Start();
        Sleep(1500);
        Check(quiet.starts == 2, "a tap that stays silent is rebuilt only once", quiet.starts);
        other->Stop();
    });

    WithinTime("following the microphone", 20, [] {
        World world;
        Stream stream;
        auto capture = MakeCapture(world, stream);
        capture->Start();
        Sleep(200);
        world.SetMic("mic-b");
        world.Trigger(SystemChange::Devices);
        Sleep(500);
        {
            std::lock_guard lock(world.mutex);
            Check(world.startedMics.size() == 2 && world.startedMics.back() == "mic-b",
                "a new default input is followed", double(world.startedMics.size()));
        }
        Check(stream.EventIndex("microphoneRestarted") >= 0, "the change is reported");
        // The input disappears for a while, then returns.
        world.micBroken = true;
        world.SetMic("");
        world.Trigger(SystemChange::Devices);
        Sleep(700);
        Check(stream.EventIndex("microphoneLost") >= 0, "a missing microphone becomes a notice");
        world.micBroken = false;
        world.SetMic("mic-c");
        world.Trigger(SystemChange::Devices);
        Sleep(500);
        capture->Stop();
        Check(world.backends == 0, "the capture ends only when stopped");
        Check(stream.Contiguous(), "frames stay continuous across microphone changes");
        {
            std::lock_guard lock(stream.mutex);
            Check(std::count(stream.events.begin(), stream.events.end(), "microphoneRestarted") >= 2,
                "the microphone coming back is reported");
            const double after = Rms(stream.me, stream.me.size() - 4800, 4800);
            Check(after > 0.1, "Me is back on the new microphone", after);
        }
    });

    WithinTime("rate change", 20, [] {
        World world;
        Stream stream;
        world.rate = 44100;
        auto capture = MakeCapture(world, stream);
        capture->Start();
        Sleep(700);
        world.rate = 16000;
        world.Trigger(SystemChange::Devices);
        Sleep(700);
        world.rate = 48000;
        world.Trigger(SystemChange::Devices);
        Sleep(700);
        capture->Stop();
        Check(stream.Contiguous(), "output is continuous across rate changes");
        std::lock_guard lock(stream.mutex);
        const size_t n = stream.me.size();
        Check(n > 48000 * 1.8, "output length follows the clock, whatever the device rate",
            double(n));
        const double a = Db(Tone(stream.me, 9600, 14400, 440, 48000));
        const double b = Db(Tone(stream.me, n - 14400 - 4800, 14400, 440, 48000));
        // A rate mislabelled by the device change would move the tone.
        const double off = Db(Tone(stream.me, n - 14400 - 4800, 14400, 440 * 48000.0 / 16000, 48000));
        Check(a > -20 && b > -20 && b - off > 30, "Me keeps its pitch at every device rate",
            b - off);
        Check(Rms(stream.call, n - 9600, 4800) > 0.1, "Call keeps its level at the fixed rate",
            Rms(stream.call, n - 9600, 4800));
    });
}

// Echo, through the capture: a synthetic far end heard back by the microphone is removed
// from Me, and the far end arrives untouched as Call.
void EchoTests()
{
    std::mt19937 random(7);
    std::normal_distribution<float> noise(0, 1);
    constexpr double kRate = 48000;
    const size_t frames = size_t(10 * kRate);
    std::vector<float> speech(frames), silence(frames, 0.0f), voice(frames), echo(frames, 0.0f);
    float low1 = 0, low2 = 0;
    for (size_t i = 0; i < frames; i++) {
        low1 = 0.7f * low1 + 0.3f * noise(random);
        low2 = 0.7f * low2 + 0.3f * low1;
        const double t = double(i) / kRate;
        speech[i] = std::fmod(t, 1.0) < 0.6 ? 0.125f * low2 : 0.0f;
        voice[i] = float(0.1 * std::sin(2 * M_PI * 220 * t) *
                         (0.6 + 0.4 * std::sin(2 * M_PI * 3 * t)));
    }
    for (size_t i = 240; i < frames; i++) {
        echo[i] = 0.5f * speech[i - 240] + 0.0005f * noise(random);
    }

    auto run = [&](const std::vector<float>& mic, const std::vector<float>& far, Stream& stream) {
        World world;
        world.unpaced = true;
        world.micSignal = &mic;
        world.farSignal = &far;
        world.echoCancel = true;
        CallCaptureTiming timing = FastTiming();
        timing.ringSeconds = 30;
        auto capture = MakeCapture(world, stream, timing, EchoMode::On);
        capture->Start();
        for (int i = 0; i < 2000 && !world.signalDone; i++) {
            Sleep(5);
        }
        capture->Stop();
    };
    WithinTime("echo through the capture", 120, [&] {
        {
            Stream stream;
            run(echo, speech, stream);
            std::lock_guard lock(stream.mutex);
            if (stream.me.size() < size_t(5 * kRate)) {
                Check(false, "the echo run delivered audio", double(stream.me.size()));
                return;
            }
            const double removed = TailDb(echo, 3, kRate) - TailDb(stream.me, 3, kRate);
            Check(removed >= 25, "echo cancellation removes at least 25 dB of the call from Me",
                removed);
            const size_t blocks = stream.call.size() / 480 * 480;
            Check(blocks > 0 && std::equal(stream.call.begin(), stream.call.begin() + blocks,
                                    speech.begin()),
                "Call is the far end, untouched and aligned with Me");
        }
        {
            Stream stream;
            run(voice, silence, stream);
            std::lock_guard lock(stream.mutex);
            const double change = TailDb(stream.me, 3, kRate) - TailDb(voice, 3, kRate);
            Check(std::fabs(change) <= 3, "speech with no far end keeps its level", change);
            Check(Rms(stream.call, 0, stream.call.size()) == 0, "and Call stays silent");
        }
    });
}

void ApiTests()
{
    Check(BKVersion() && std::strlen(BKVersion()) > 0, "BKVersion names a release", 0);
    {
        BKCallCaptureOptions options = {};
        options.label = "api";
        options.callBundleID = "com.example.call";
        options.echo = BKEchoCancellationAutomatic;
        BKCallCapture* capture = BKCallCaptureCreate(&options,
            [](void*, const float*, const float*, uint32_t, uint64_t) {},
            [](void*, BKEventKind, const char*) {}, nullptr);
        Check(capture != nullptr, "a capture is created without touching a device");
        char* text = BKCallCaptureDiagnostics(capture);
        Check(text && std::strncmp(text, "stopped", 7) == 0, "a capture that never started says so");
        std::free(text);
        BKCallCaptureStop(capture);
        BKCallCaptureDestroy(capture);
        Check(true, "a capture that never started can be stopped and destroyed");
    }
    Check(BKCallCaptureCreate(nullptr, nullptr, nullptr, nullptr) == nullptr,
        "no options, no capture");
    {
        BKProbes* probes = BKProbesCreate("api");
        char error[128] = {};
        Check(BKProbesSet(probes, "[]", error, sizeof error), "an empty probe list is accepted");
        Check(!BKProbesSet(probes, "[{\"nope\":1}]", error, sizeof error) && error[0],
            "a probe without a bundle ID is refused with a message");
        float levels[4];
        Check(BKProbesLevels(probes, levels, 4) == 0, "no probes, no levels");
        BKProbesDestroy(probes);
    }
}

// The Core Audio environment's listeners must keep working after Observe returned and the
// caller's std::function is gone. The blocks are run here without registering them, so no
// device is touched.
void ObserveTests()
{
    auto hits = std::make_shared<std::atomic<int>>(0);
    auto kinds = std::make_shared<std::vector<SystemChange>>();
    std::vector<SystemListener> listeners;
    {
        std::function<void(SystemChange)> changed = [hits, kinds](SystemChange change) {
            kinds->push_back(change);
            hits->fetch_add(1);
        };
        listeners = SystemListenerBlocks(std::move(changed));
    }
    // A listener that borrowed the function would leave the capture list as the only owner.
    Check(hits.use_count() >= 2, "each listener owns its handler", double(hits.use_count()));
    if (hits.use_count() < 2) {
        return;
    }
    const AudioObjectPropertyAddress address = {};
    for (auto& listener : listeners) {
        listener.block(0, &address);
    }
    Check(listeners.size() == 4 && hits->load() == 4 &&
              kinds->back() == SystemChange::ServiceRestarted,
        "listeners run after the function they were made from is gone", double(hits->load()));
}

// Opens the real default microphone and taps a call app that is not running, to see the
// real path start, deliver and stop. Run by hand with BLENDKIT_LIVE=1.
void LiveTests()
{
    BKCallCaptureOptions options = {};
    options.label = "live";
    options.callBundleID = "com.apple.Safari";
    options.echo = BKEchoCancellationAutomatic;
    std::atomic<uint64_t> frames{0};
    BKCallCapture* capture = BKCallCaptureCreate(&options,
        [](void* context, const float*, const float*, uint32_t n, uint64_t) {
            static_cast<std::atomic<uint64_t>*>(context)->fetch_add(n);
        },
        [](void*, BKEventKind kind, const char* detail) {
            std::printf("     event %d %s\n", int(kind), detail ? detail : "");
        },
        &frames);
    const BKStartResult result = BKCallCaptureStart(capture);
    std::printf("     start result %d\n", int(result));
    if (result == BKStartStarted) {
        Sleep(2000);
        char* text = BKCallCaptureDiagnostics(capture);
        std::printf("     %s\n", text);
        std::free(text);
        BKCallCaptureStop(capture);
        Check(frames > 48000, "live capture delivered about two seconds", double(frames));
    }
    BKCallCaptureDestroy(capture);
}

} // namespace

int main()
{
    ConversionTests();
    GapTests();
    SilenceTests();
    LayoutTests();
    ApiTests();
    ObserveTests();
    ThreadingTests();
    RecoveryTests();
    EchoTests();
    if (const char* live = std::getenv("BLENDKIT_LIVE"); live && std::strcmp(live, "1") == 0) {
        LiveTests();
    }
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
