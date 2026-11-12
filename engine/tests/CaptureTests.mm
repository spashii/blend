// Pins how capture routes channels, so moving that code cannot change what Blend records:
// which two channels of a source's buffers become left and right in its ring, and which
// channels of an echo-cancelled microphone's aggregate are the microphone and the echo
// reference. Everything runs on synthetic buffer lists; no device or tap is opened.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <random>
#include <string>
#include <vector>

// The routing sits in protected and private members of the sources; the tests call them
// directly rather than through a device.
#define private public
#define protected public
#include "../src/Sources.hpp"
#undef protected
#undef private

namespace {

constexpr double kRate = 48000;
int failures = 0;

void Check(bool ok, const char* what, double value = 0)
{
    std::printf("%s %s (%.1f)\n", ok ? "ok  " : "FAIL", what, value);
    failures += ok ? 0 : 1;
}

// One channel's samples, a ramp that is distinct per channel and per frame. Every value is
// exact in a float, so no compiler rounding can make two computations of it differ.
float Sample(uint32_t channel, uint32_t frame)
{
    return float(channel + 1) + float(frame) / 1024.0f;
}

// An AudioBufferList whose buffers hold the given channel counts, each channel filled by
// Sample() with its index across all buffers.
struct Buffers
{
    Buffers(std::vector<uint32_t> layout, uint32_t frames)
        : frames(frames)
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
                    data[b][size_t(i) * layout[b] + c] = Sample(channel, i);
                }
            }
            list->mBuffers[b].mNumberChannels = layout[b];
            list->mBuffers[b].mDataByteSize = frames * layout[b] * sizeof(float);
            list->mBuffers[b].mData = data[b].data();
        }
    }
    uint32_t frames;
    std::vector<uint8_t> storage;
    AudioBufferList* list;
    std::vector<std::vector<float>> data;
};

// What a source's Produce queued, as interleaved stereo.
std::vector<float> Drain(blend::Source& source)
{
    auto& ring = source.stream_.load()->ring;
    std::vector<float> out(ring.Available() * 2);
    ring.Read(out.data(), ring.Available());
    return out;
}

// Stands in for a device or tap: Start and Stop do nothing, the test publishes the stream.
class TestSource : public blend::Source
{
public:
    TestSource()
        : Source("test", [](std::function<void()> free) { free(); })
    {
        Publish(kRate, kRate, 512, 512);
    }
    bool Start(double, uint32_t) override { return true; }
    void Stop() override {}
    void Feed(const AudioBufferList* input) { Produce(input); }
};

bool SameBytes(const std::vector<float>& a, const std::vector<float>& b)
{
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

// The stereo a source should have queued: left and right are channels of Buffers by index.
std::vector<float> Expected(uint32_t left, uint32_t right, uint32_t frames)
{
    std::vector<float> out(size_t(frames) * 2);
    for (uint32_t i = 0; i < frames; i++) {
        out[i * 2] = Sample(left, i);
        out[i * 2 + 1] = Sample(right, i);
    }
    return out;
}

void CheckProduce(const char* what, std::vector<uint32_t> layout, uint32_t left, uint32_t right)
{
    TestSource source;
    Buffers input(layout, 300);
    source.Feed(input.list);
    Check(SameBytes(Drain(source), Expected(left, right, 300)), what);
}

void ProduceTests()
{
    CheckProduce("stereo interleaved: left and right as delivered", {2}, 0, 1);
    CheckProduce("mono is copied to both sides", {1}, 0, 0);
    CheckProduce("three interleaved channels: the first two", {3}, 0, 1);
    CheckProduce("two planar buffers: one channel each", {1, 1}, 0, 1);
    CheckProduce("mono buffer then stereo buffer: the first two across buffers", {1, 2}, 0, 1);
    CheckProduce("stereo buffer then mono buffer: the first buffer's pair", {2, 1}, 0, 1);
    // Today a device's own input channels come before a tap's: a headset's microphone is
    // taken as the app's left side, and its first tap channel as the right.
    CheckProduce("one device channel then a stereo tap: device and tap left", {1, 2}, 0, 1);
    CheckProduce("one device channel then a mono tap: both from the device", {1, 1}, 0, 1);

    {
        TestSource source;
        Buffers input({2}, 300);
        source.Feed(input.list);
        const float peak = source.TakeProducedPeak();
        Check(peak == Sample(1, 299), "produced peak is the loudest sample", peak);
    }
    {
        // The frame count is the first buffer's; a longer second buffer is not read past.
        TestSource source;
        Buffers input({1, 1}, 200);
        input.list->mBuffers[1].mDataByteSize = 400 * sizeof(float);
        source.Feed(input.list);
        Check(Drain(source).size() == 400, "frames come from the first buffer");
    }
    {
        // One call never queues more than 8192 frames.
        TestSource source;
        Buffers input({2}, 10000);
        source.Feed(input.list);
        Check(Drain(source).size() == 8192 * 2, "at most 8192 frames per call");
    }
    {
        TestSource source;
        source.Feed(nullptr);
        AudioBufferList empty;
        empty.mNumberBuffers = 0;
        source.Feed(&empty);
        AudioBufferList none;
        none.mNumberBuffers = 1;
        none.mBuffers[0].mNumberChannels = 0;
        none.mBuffers[0].mDataByteSize = 0;
        none.mBuffers[0].mData = nullptr;
        source.Feed(&none);
        Check(Drain(source).empty(), "no buffers, or no channels, queue nothing");
    }
    {
        // Nothing is queued before the stream is published, and nothing after Unpublish.
        TestSource source;
        source.Unpublish();
        Buffers input({2}, 64);
        source.Feed(input.list);
        Check(source.stream_.load() == nullptr, "an unpublished source queues nothing");
    }
}

// Collects what a MicCapture delivers in blocks.
class CollectSink : public blend::FrameSink
{
public:
    void Block(const float* me, const float*, uint32_t frames) override
    {
        mono.insert(mono.end(), me, me + frames);
    }
    std::vector<float> mono;
};

// A microphone capture as MicCapture::Start sets it up after the aggregate exists, minus
// the device calls.
struct MicRig
{
    MicRig(uint32_t micChannels, bool reference)
        : capture(blend::MicCapture::Options{"no-such-device",
              blend::MicCapture::Reference::EverythingButSelf, true,
              blend::MicProcessor::Isolation::Off, false})
    {
        capture.sink_ = &sink;
        capture.micChannels_ = micChannels;
        // Any non-zero id marks the reference as present; nothing here calls the HAL with it.
        capture.aggregate_ = reference ? 1 : kAudioObjectUnknown;
        capture.processor_ = blend::MicProcessor::Create(kRate, true,
            blend::MicProcessor::Isolation::Off, blend::MicCapture::Emit, &capture);
    }
    ~MicRig()
    {
        capture.aggregate_ = kAudioObjectUnknown;
        capture.Stop();
    }

    // Calls the IO proc with `channels` laid out as `layout`, one chunk at a time, and
    // returns the processed mono signal.
    std::vector<float> Run(std::vector<uint32_t> layout,
        const std::function<float(uint32_t channel, size_t frame)>& signal, size_t frames)
    {
        constexpr uint32_t chunk = 512;
        for (size_t at = 0; at + chunk <= frames; at += chunk) {
            Buffers input(layout, chunk);
            uint32_t channel = 0;
            for (size_t b = 0; b < layout.size(); b++) {
                for (uint32_t c = 0; c < layout[b]; c++, channel++) {
                    for (uint32_t i = 0; i < chunk; i++) {
                        input.data[b][size_t(i) * layout[b] + c] = signal(channel, at + i);
                    }
                }
            }
            blend::MicCapture::IOProc(0, nullptr, input.list, nullptr, nullptr, nullptr, &capture);
        }
        return sink.mono;
    }

    CollectSink sink;
    blend::MicCapture capture;
};

double TailDb(const std::vector<float>& x, double seconds)
{
    const size_t n = size_t(seconds * kRate);
    double sum = 0;
    for (size_t i = x.size() - n; i < x.size(); i++) {
        sum += double(x[i]) * x[i];
    }
    return 10 * std::log10(sum / double(n) + 1e-20);
}

// Energy of one frequency in the last `seconds` of a signal, in dB (Goertzel).
double ToneDb(const std::vector<float>& x, double hz, double seconds)
{
    const size_t n = size_t(seconds * kRate);
    const double w = 2 * M_PI * hz / kRate;
    const double coeff = 2 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (size_t i = x.size() - n; i < x.size(); i++) {
        const double s = x[i] + coeff * s1 - s2;
        s2 = s1;
        s1 = s;
    }
    const double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    return 10 * std::log10(power / (double(n) * n) + 1e-20);
}

void MicRoutingTests()
{
    const size_t frames = size_t(10 * kRate);
    std::mt19937 random(7);
    std::normal_distribution<float> noise(0, 1);

    // Which microphone channel is processed: with no reference, the processor passes the
    // near end, so a tone on channel 0 comes out and tones on the others do not.
    {
        MicRig rig(2, false);
        auto tone = [](uint32_t channel, size_t frame) {
            const double hz = 500.0 * (channel + 1);
            return float(0.1 * std::sin(2 * M_PI * hz * double(frame) / kRate));
        };
        auto out = rig.Run({2}, tone, frames);
        const double zero = ToneDb(out, 500, 2), one = ToneDb(out, 1000, 2);
        Check(zero > one + 40, "the microphone is channel 0, not channel 1", zero - one);
    }
    {
        // Planar buffers: channel 0 is the first buffer's.
        MicRig rig(2, false);
        auto tone = [](uint32_t channel, size_t frame) {
            const double hz = 500.0 * (channel + 1);
            return float(0.1 * std::sin(2 * M_PI * hz * double(frame) / kRate));
        };
        auto out = rig.Run({1, 1}, tone, frames);
        Check(ToneDb(out, 500, 2) > ToneDb(out, 1000, 2) + 40,
            "the microphone is channel 0 of the first buffer");
    }

    // The far end talks in bursts; the microphone hears it 5 ms late at half level.
    std::vector<float> speech(frames);
    float low1 = 0, low2 = 0;
    for (size_t i = 0; i < frames; i++) {
        low1 = 0.7f * low1 + 0.3f * noise(random);
        low2 = 0.7f * low2 + 0.3f * low1;
        speech[i] = std::fmod(double(i) / kRate, 1.0) < 0.6 ? 0.125f * low2 : 0.0f;
    }
    std::vector<float> echo(frames, 0.0f);
    for (size_t i = 240; i < frames; i++) {
        echo[i] = 0.5f * speech[i - 240] + 0.0005f * noise(random);
    }
    // A signal per channel: the microphone's channels carry the echo on channel 0 and
    // nothing else, `reference` channels (by index) carry the far end.
    auto layout = [&](std::vector<uint32_t> reference) {
        return [&, reference](uint32_t channel, size_t frame) {
            if (channel == 0) {
                return echo[frame];
            }
            return std::count(reference.begin(), reference.end(), channel) ? speech[frame] : 0.0f;
        };
    };

    {
        // Two microphone channels, then the tap's left and right.
        MicRig rig(2, true);
        auto out = rig.Run({4}, layout({2, 3}), frames);
        const double removed = TailDb(echo, 3) - TailDb(out, 3);
        Check(removed >= 25, "reference is the two channels after the microphone's", removed);
    }
    {
        // One microphone channel, a mono tap after it: the one channel stands for both.
        MicRig rig(1, true);
        auto out = rig.Run({2}, layout({1}), frames);
        const double removed = TailDb(echo, 3) - TailDb(out, 3);
        Check(removed >= 25, "a mono reference is repeated for both sides", removed);
    }
    {
        // Planar: microphone, then a buffer per tap channel.
        MicRig rig(1, true);
        auto out = rig.Run({1, 1, 1}, layout({1, 2}), frames);
        const double removed = TailDb(echo, 3) - TailDb(out, 3);
        Check(removed >= 25, "the reference is found across buffers", removed);
    }
    {
        // The far end on a microphone channel is not the reference.
        MicRig rig(2, true);
        auto out = rig.Run({4}, layout({1}), frames);
        const double removed = TailDb(echo, 3) - TailDb(out, 3);
        Check(removed < 3, "channels before micChannels are not the reference", removed);
    }
    {
        // Without the aggregate there is no reference to find, whatever the channels hold.
        MicRig rig(2, false);
        auto out = rig.Run({4}, layout({2, 3}), frames);
        const double removed = TailDb(echo, 3) - TailDb(out, 3);
        Check(removed < 3, "no aggregate, no reference", removed);
    }
}

} // namespace

int main()
{
    ProduceTests();
    MicRoutingTests();
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
