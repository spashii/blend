// Checks the microphone processing chain on synthetic signals, through the same calls the
// capture thread makes: echo cancellation has to remove a delayed copy of the reference,
// leave a voice alone when nothing plays, and voice isolation has to remove steady noise.
// macOS only, since it runs WebRTC and Apple's isolation unit for real.

#include "../src/HAL.hpp"
#include "../src/MicProcessor.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

namespace {

constexpr double kRate = 48000;
constexpr uint32_t kChunk = 512; // a typical device buffer, not a multiple of 10 ms
int failures = 0;

void Check(bool ok, const char* what, double value)
{
    std::printf("%s %s (%.1f dB)\n", ok ? "ok  " : "FAIL", what, value);
    failures += ok ? 0 : 1;
}

struct Output
{
    std::vector<float> samples;
    std::vector<float> farEnd;
    bool sawNullFarEnd = false;
};

void Collect(void* context, const float* mono, const float* farEnd, uint32_t frames)
{
    auto out = static_cast<Output*>(context);
    out->samples.insert(out->samples.end(), mono, mono + frames);
    if (farEnd) {
        out->farEnd.insert(out->farEnd.end(), farEnd, farEnd + frames);
    } else {
        out->sawNullFarEnd = true;
    }
}

// Energy over the last `seconds` of a signal, in dB.
double TailDb(const std::vector<float>& x, double seconds)
{
    const size_t n = size_t(seconds * kRate);
    double sum = 0;
    for (size_t i = x.size() - n; i < x.size(); i++) {
        sum += double(x[i]) * x[i];
    }
    return 10 * std::log10(sum / double(n) + 1e-20);
}

// Feeds mic and reference through a processor in device-sized chunks, with the reference
// as interleaved stereo the way a tap delivers it.
std::vector<float> Run(bool echoCancel, blend::MicProcessor::Isolation isolation,
    const std::vector<float>& mic, const std::vector<float>& reference)
{
    Output out;
    auto processor = blend::MicProcessor::Create(kRate, echoCancel, isolation, Collect, &out);
    if (!processor) {
        std::printf("FAIL processor did not start\n");
        failures++;
        return {};
    }
    std::vector<float> stereo(reference.size() * 2);
    for (size_t i = 0; i < reference.size(); i++) {
        stereo[i * 2] = stereo[i * 2 + 1] = reference[i];
    }
    for (size_t at = 0; at + kChunk <= mic.size(); at += kChunk) {
        processor->Process(&mic[at], 1, &stereo[at * 2], 2, &stereo[at * 2 + 1], 2, kChunk);
    }
    std::printf("     %s\n", processor->Describe().c_str());
    return out.samples;
}

bool SameBytes(const std::vector<float>& a, const std::vector<float>& b)
{
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

// The far end handed to the sink is the reference as it went in: left and right averaged,
// untouched by echo cancellation, which rewrites its input. Distinct channels show the
// average and not a pass of one side.
void FarEndTests(const std::vector<float>& mic, const std::vector<float>& reference)
{
    std::vector<float> left(reference.size()), right(reference.size());
    std::vector<float> stereo(reference.size() * 2), expected;
    for (size_t i = 0; i < reference.size(); i++) {
        left[i] = reference[i];
        right[i] = 0.25f * reference[i] + 0.01f;
        stereo[i * 2] = left[i];
        stereo[i * 2 + 1] = right[i];
    }
    const size_t usable = mic.size() / kChunk * kChunk;
    const size_t blocks = usable / 480;
    for (size_t i = 0; i < blocks * 480; i++) {
        expected.push_back(0.5f * (left[i] + right[i]));
    }
    for (bool echoCancel : {true, false}) {
        Output out;
        auto processor = blend::MicProcessor::Create(kRate, echoCancel,
            blend::MicProcessor::Isolation::Off, Collect, &out, true);
        if (!processor) {
            std::printf("FAIL processor did not start\n");
            failures++;
            continue;
        }
        for (size_t at = 0; at + kChunk <= mic.size(); at += kChunk) {
            processor->Process(&mic[at], 1, &stereo[at * 2], 2, &stereo[at * 2 + 1], 2, kChunk);
        }
        Check(SameBytes(out.farEnd, expected),
            echoCancel ? "the far end reaches the sink bit-exact with echo cancellation on"
                       : "the far end reaches the sink bit-exact with both stages off",
            0);
        Check(!out.sawNullFarEnd, "blocks with a reference carry a far end", 0);
    }
}

// Pass-through: both stages off, the microphone comes out unchanged in 10 ms blocks.
void PassThroughTests(const std::vector<float>& mic)
{
    Output out;
    Check(!blend::MicProcessor::Create(kRate, false, blend::MicProcessor::Isolation::Off,
              Collect, &out),
        "without pass-through, no stages means no processor", 0);
    auto processor = blend::MicProcessor::Create(kRate, false,
        blend::MicProcessor::Isolation::Off, Collect, &out, true);
    if (!processor) {
        std::printf("FAIL pass-through processor did not start\n");
        failures++;
        return;
    }
    Check(processor->BlockFrames() == 480, "pass-through keeps 10 ms blocks", processor->BlockFrames());
    for (size_t at = 0; at + kChunk <= mic.size(); at += kChunk) {
        processor->Process(&mic[at], 1, nullptr, 1, nullptr, 1, kChunk);
    }
    std::vector<float> expected(mic.begin(), mic.begin() + out.samples.size());
    Check(!out.samples.empty() && SameBytes(out.samples, expected),
        "pass-through leaves the microphone bit-exact", 0);
    Check(out.farEnd.empty() && out.sawNullFarEnd, "without a reference the far end is null", 0);
}

} // namespace

// A raw built-in array: three channels averaged, the makeup applied with a ramp, and a
// limiter after it, in front of the same blocks as always.
void ArrayTests()
{
    const float makeup = std::pow(10.0f, 18.0f / 20.0f);
    std::vector<float> tone(size_t(2 * kRate));
    for (size_t i = 0; i < tone.size(); i++) {
        tone[i] = float(0.01 * std::sin(2 * M_PI * 440 * double(i) / kRate));
    }
    auto run = [&](bool raw, const std::vector<float>& a, const std::vector<float>& b,
                   const std::vector<float>& c, float gain, uint64_t* limited, Output& out) {
        auto processor = blend::MicProcessor::Create(kRate, false, blend::MicProcessor::Isolation::Off,
            Collect, &out, true);
        processor->SetArrayMakeup(gain);
        for (size_t at = 0; at + kChunk <= a.size(); at += kChunk) {
            blend::routing::Channel mics[3] = {{&a[at], 1}, {&b[at], 1}, {&c[at], 1}};
            processor->ProcessArray(mics, 3, raw, nullptr, 1, nullptr, 1, kChunk);
        }
        if (limited) {
            *limited = processor->LimiterActivations();
        }
    };
    std::vector<float> zero(tone.size(), 0.0f);
    {
        Output out;
        run(true, tone, tone, tone, makeup, nullptr, out);
        const double gain = TailDb(out.samples, 1) - TailDb(tone, 1);
        Check(std::fabs(gain - 18) < 0.3, "a raw array gets the makeup", gain);
    }
    {
        Output out;
        run(true, tone, zero, zero, makeup, nullptr, out);
        const double gain = TailDb(out.samples, 1) - TailDb(tone, 1);
        Check(std::fabs(gain - (18 - 9.54)) < 0.3, "channels are averaged, not picked", gain);
    }
    {
        Output out;
        run(false, tone, tone, tone, makeup, nullptr, out);
        const double gain = TailDb(out.samples, 1) - TailDb(tone, 1);
        Check(std::fabs(gain) < 0.1, "not raw: gain 1", gain);
    }
    {
        // The gain ramps: no step between samples larger than a 50 ms slope allows.
        Output out;
        run(true, tone, tone, tone, makeup, nullptr, out);
        const float slope = (makeup - 1.0f) / float(kRate * 0.05);
        float worst = 0;
        for (size_t i = 1; i < 4000; i++) {
            const float expectedMax = std::fabs(tone[i] - tone[i - 1]) * makeup + std::fabs(tone[i]) * slope;
            worst = std::max(worst, std::fabs(out.samples[i] - out.samples[i - 1]) - expectedMax);
        }
        Check(worst < 1e-5f, "the gain ramps, it does not step", worst);
    }
    {
        // A knock: peaks above -19 dBFS in the raw signal would clip after 18 dB.
        std::vector<float> knock = tone;
        for (size_t i = 24000; i < 24100; i++) {
            knock[i] = 0.5f * float(std::sin(2 * M_PI * 800 * double(i) / kRate));
        }
        Output out;
        uint64_t limited = 0;
        run(true, knock, knock, knock, makeup, &limited, out);
        float peak = 0;
        for (float v : out.samples) {
            peak = std::max(peak, std::fabs(v));
        }
        Check(peak <= 0.891f + 1e-4f, "the limiter keeps the knock under -1 dBFS", peak);
        Check(limited > 0, "and counts that it acted", double(limited));
    }
    {
        // Echo cancellation's input: does WebRTC clamp a float input above 1.0? A mic
        // sample of 3.0 must still reach the sink above the limiter's reach unclipped by APM
        // when the processor runs without the array path.
        Output out;
        auto processor = blend::MicProcessor::Create(kRate, true, blend::MicProcessor::Isolation::Off, Collect, &out);
        std::vector<float> loud(size_t(kRate), 0.0f);
        for (size_t i = 0; i < loud.size(); i++) {
            loud[i] = 3.0f * float(std::sin(2 * M_PI * 440 * double(i) / kRate));
        }
        std::vector<float> stereo(loud.size() * 2, 0.0f);
        for (size_t at = 0; at + kChunk <= loud.size(); at += kChunk) {
            processor->Process(&loud[at], 1, &stereo[at * 2], 2, &stereo[at * 2 + 1], 2, kChunk);
        }
        float peak = 0;
        for (size_t i = out.samples.size() / 2; i < out.samples.size(); i++) {
            peak = std::max(peak, std::fabs(out.samples[i]));
        }
        std::printf("     APM float input of 3.0 leaves as a peak of %.2f\n", peak);
    }
}

int main()
{
    std::mt19937 random(7);
    std::normal_distribution<float> noise(0, 1);
    const size_t frames = size_t(10 * kRate);

    // Echo: the microphone hears the far end 5 ms late at half level, plus a quiet room.
    // The far end talks like speech, in bursts with pauses. AEC3 is tuned for that; sound
    // that never pauses (music) it reduces by only 10 to 15 dB, and keeps the rest as if
    // it were room noise.
    std::vector<float> speech(frames), music(frames), silence(frames, 0.0f);
    float low1 = 0, low2 = 0;
    for (size_t i = 0; i < frames; i++) {
        low1 = 0.7f * low1 + 0.3f * noise(random);
        low2 = 0.7f * low2 + 0.3f * low1;
        const double t = double(i) / kRate;
        music[i] = 0.125f * low2 * float(0.2 + 0.8 * std::fabs(std::sin(2 * M_PI * 2.5 * t)));
        speech[i] = std::fmod(t, 1.0) < 0.6 ? 0.125f * low2 : 0.0f;
    }
    auto echoOf = [&](const std::vector<float>& far) {
        std::vector<float> mic(frames, 0.0f);
        for (size_t i = 240; i < frames; i++) {
            mic[i] = 0.5f * far[i - 240] + 0.0005f * noise(random);
        }
        return mic;
    };
    const auto speechEcho = echoOf(speech);
    auto cancelled = Run(true, blend::MicProcessor::Isolation::Off, speechEcho, speech);
    if (!cancelled.empty()) {
        const double removed = TailDb(speechEcho, 3) - TailDb(cancelled, 3);
        Check(removed >= 25, "echo cancellation removes at least 25 dB of speech echo", removed);
    }
    // The same without the reference: what is removed above comes from the reference.
    auto unreferenced = Run(true, blend::MicProcessor::Isolation::Off, speechEcho, silence);
    if (!unreferenced.empty()) {
        const double removed = TailDb(speechEcho, 3) - TailDb(unreferenced, 3);
        Check(removed < 3, "without the reference nothing is cancelled", removed);
    }
    // Music from the speakers: echo cancellation and voice isolation together, as in the
    // Call template, remove what echo cancellation leaves.
    const auto musicEcho = echoOf(music);
    auto both = Run(true, blend::MicProcessor::Isolation::Standard, musicEcho, music);
    if (!both.empty()) {
        const double removed = TailDb(musicEcho, 3) - TailDb(both, 3);
        Check(removed >= 25, "with isolation, at least 25 dB of music echo is removed", removed);
    }

    // Near end only: a voice-like tone with nothing playing keeps its level.
    std::vector<float> voice(frames);
    for (size_t i = 0; i < frames; i++) {
        const double t = double(i) / kRate;
        voice[i] = float(0.1 * std::sin(2 * M_PI * 220 * t) * (0.6 + 0.4 * std::sin(2 * M_PI * 3 * t)));
    }
    auto kept = Run(true, blend::MicProcessor::Isolation::Off, voice, silence);
    if (!kept.empty()) {
        const double change = TailDb(kept, 3) - TailDb(voice, 3);
        Check(std::fabs(change) <= 3, "echo cancellation leaves the near end within 3 dB", change);
    }

    // Isolation: steady noise with no voice in it is removed.
    std::vector<float> hiss(frames);
    for (auto& v : hiss) {
        v = 0.03f * noise(random);
    }
    auto isolated = Run(false, blend::MicProcessor::Isolation::Standard, hiss, silence);
    if (!isolated.empty()) {
        const double removed = TailDb(hiss, 3) - TailDb(isolated, 3);
        Check(removed >= 10, "voice isolation removes at least 10 dB of noise", removed);
    }

    FarEndTests(speechEcho, speech);
    PassThroughTests(voice);

    // Only physical inputs key ducking. The built-in microphone is one; a device that does
    // not exist, as BlackHole does not on a Mac without it, is not.
    const auto builtIn = blend::hal::DeviceForUID("BuiltInMicrophoneDevice");
    if (builtIn != kAudioObjectUnknown) {
        Check(blend::hal::IsPhysicalInput(builtIn), "the built-in microphone is physical", 0);
    }
    Check(!blend::hal::IsPhysicalInput(blend::hal::DeviceForUID("no-such-device")),
        "an unknown device is not physical", 0);

    ArrayTests();

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
