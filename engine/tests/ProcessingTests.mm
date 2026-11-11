// Checks the microphone processing chain on synthetic signals, through the same calls the
// capture thread makes: echo cancellation has to remove a delayed copy of the reference,
// leave a voice alone when nothing plays, and voice isolation has to remove steady noise.
// macOS only, since it runs WebRTC and Apple's isolation unit for real.

#include "../src/HAL.hpp"
#include "../src/MicProcessor.hpp"

#include <cmath>
#include <cstdio>
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
};

void Collect(void* context, const float* mono, uint32_t frames)
{
    auto out = static_cast<Output*>(context);
    out->samples.insert(out->samples.end(), mono, mono + frames);
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

} // namespace

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

    // Only physical inputs key ducking. The built-in microphone is one; a device that does
    // not exist, as BlackHole does not on a Mac without it, is not.
    const auto builtIn = blend::hal::DeviceForUID("BuiltInMicrophoneDevice");
    if (builtIn != kAudioObjectUnknown) {
        Check(blend::hal::IsPhysicalInput(builtIn), "the built-in microphone is physical", 0);
    }
    Check(!blend::hal::IsPhysicalInput(blend::hal::DeviceForUID("no-such-device")),
        "an unknown device is not physical", 0);

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
