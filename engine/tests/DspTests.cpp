// Portable tests for the realtime building blocks; they build and run on Linux and macOS.

#include "../src/FrameRing.hpp"
#include "../src/MixMath.hpp"
#include "../src/Resampler.hpp"
#include "../src/SourceReader.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

int failures = 0;

#define CHECK(cond, ...)                                                                   \
    do {                                                                                   \
        if (!(cond)) {                                                                     \
            std::printf("FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);                   \
            std::printf(__VA_ARGS__);                                                      \
            std::printf("\n");                                                             \
            failures++;                                                                    \
        }                                                                                  \
    } while (0)

void TestRingWrapsAndCountsOverflow()
{
    blend::FrameRing ring(8, 2);
    std::vector<float> in(12 * 2), out(12 * 2);
    for (size_t i = 0; i < in.size(); i++) {
        in[i] = float(i);
    }
    CHECK(ring.Write(in.data(), 6) == 6, "first write");
    CHECK(ring.Read(out.data(), 4) == 4, "first read");
    CHECK(ring.Write(in.data() + 12, 6) == 6, "wrapping write");
    CHECK(ring.Available() == 8, "available %zu", ring.Available());
    CHECK(ring.Write(in.data(), 1) == 0 && ring.Overflows() == 1, "overflow counted");
    CHECK(ring.Read(out.data(), 8) == 8, "drain");
    CHECK(out[2 * 2] == 12 && out[7 * 2 + 1] == 23, "wrapped order %f %f", out[4], out[15]);
}

// Fits a sine of known frequency by least squares and returns residual power in dB
// relative to the fitted sine.
double ResidualDb(const std::vector<float>& x, size_t from, double freq, double rate)
{
    double ss = 0, cc = 0, sc = 0, xs = 0, xc = 0;
    for (size_t i = from; i < x.size(); i++) {
        const double s = std::sin(2 * M_PI * freq * i / rate);
        const double c = std::cos(2 * M_PI * freq * i / rate);
        ss += s * s;
        cc += c * c;
        sc += s * c;
        xs += x[i] * s;
        xc += x[i] * c;
    }
    const double det = ss * cc - sc * sc;
    const double a = (xs * cc - xc * sc) / det;
    const double b = (xc * ss - xs * sc) / det;
    double signal = 0, residual = 0;
    for (size_t i = from; i < x.size(); i++) {
        const double fit = a * std::sin(2 * M_PI * freq * i / rate) +
                           b * std::cos(2 * M_PI * freq * i / rate);
        signal += fit * fit;
        residual += (x[i] - fit) * (x[i] - fit);
    }
    return 10 * std::log10(residual / signal);
}

void TestResamplerQuality(double inRate, double outRate, double freq, double limitDb)
{
    blend::Resampler resampler(1, inRate, outRate);
    size_t produced = 0;
    std::vector<float> out;
    std::vector<float> block(256);
    while (out.size() < size_t(outRate)) {
        resampler.Process(block.data(), 256, 1.0, [&](float* dst, size_t n) {
            for (size_t i = 0; i < n; i++) {
                dst[i] = float(0.5 * std::sin(2 * M_PI * freq * double(produced + i) / inRate));
            }
            produced += n;
        });
        out.insert(out.end(), block.begin(), block.end());
    }
    const double db = ResidualDb(out, 1024, freq, outRate);
    std::printf("resampler %.0f -> %.0f Hz at %.0f Hz: residual %.1f dB\n", inRate, outRate,
        freq, db);
    CHECK(db < limitDb, "residual %.1f dB above %.1f", db, limitDb);
}

// Simulates a source clock running fast or slow against the bus clock and checks the
// reader holds its ring near target with no underruns after priming.
void TestDriftControl(double sourceRate, double ppm, uint32_t sourceBlock, uint32_t busBlock,
    double seconds)
{
    const double busRate = 48000;
    const double actualSourceRate = sourceRate * (1 + ppm * 1e-6);
    const size_t target = sourceBlock + size_t(busBlock * sourceRate / busRate) + 256;
    blend::FrameRing ring(16384, 2);
    blend::SourceReader reader(ring, sourceRate, busRate, target, busBlock);
    std::vector<float> in(sourceBlock * 2), out(busBlock * 2);
    double nextSource = 0, nextBus = 0.003;
    uint64_t sourceFrames = 0;
    double minFill = 1e9, maxFill = 0;
    uint64_t underrunsAfterStart = 0;
    double correctionSum = 0, correctionSq = 0;
    uint64_t correctionCount = 0;
    while (nextBus < seconds) {
        if (nextSource <= nextBus) {
            for (uint32_t i = 0; i < sourceBlock; i++) {
                const float v = float(0.3 * std::sin(2 * M_PI * 440 * double(sourceFrames + i) /
                                                     sourceRate));
                in[i * 2] = in[i * 2 + 1] = v;
            }
            ring.Write(in.data(), sourceBlock);
            sourceFrames += sourceBlock;
            nextSource += sourceBlock / actualSourceRate;
        } else {
            const uint64_t before = reader.Underruns();
            reader.Pull(out.data(), busBlock);
            if (nextBus > 2) {
                underrunsAfterStart += reader.Underruns() - before;
                minFill = std::min(minFill, double(ring.Available()));
                maxFill = std::max(maxFill, double(ring.Available()));
            }
            if (nextBus > seconds / 2) {
                correctionSum += reader.Correction();
                correctionSq += reader.Correction() * reader.Correction();
                correctionCount++;
            }
            nextBus += busBlock / busRate;
        }
    }
    const double mean = correctionSum / correctionCount;
    const double spreadPpm =
        1e6 * std::sqrt(std::max(0.0, correctionSq / correctionCount - mean * mean));
    std::printf("drift %.0f Hz %+.0f ppm, blocks %u/%u: fill %.0f..%.0f (target %zu), "
                "correction mean %+.1f ppm spread %.1f ppm, underruns %llu, skips %llu\n",
        sourceRate, ppm, sourceBlock, busBlock, minFill, maxFill, target, (mean - 1) * 1e6,
        spreadPpm, (unsigned long long)underrunsAfterStart, (unsigned long long)reader.Skips());
    CHECK(underrunsAfterStart == 0, "underruns after start");
    CHECK(reader.Skips() == 0, "skips");
    CHECK(std::fabs(mean - (1 + ppm * 1e-6)) < 15e-6, "mean correction does not track");
    // 0.1% is about 1.7 cents of pitch wobble, well below what anyone hears on speech.
    CHECK(spreadPpm < 1000, "correction wobbles by %.0f ppm", spreadPpm);
}

// A source that queued far more than the target before the first pull (the bus started
// late) must be trimmed once and then play, not emptied by a second skip.
void TestPrimingAfterBacklog()
{
    blend::FrameRing ring(16384, 2);
    blend::SourceReader reader(ring, 48000, 48000, 768, 256);
    std::vector<float> in(16384 * 2, 0.25f), out(256 * 2);
    ring.Write(in.data(), 16384);
    reader.Pull(out.data(), 256);
    std::printf("backlog: after the first pull %zu queued (target 768), underruns %llu\n",
        ring.Available(), (unsigned long long)reader.Underruns());
    CHECK(reader.Underruns() == 0, "no underrun after a backlog");
    CHECK(ring.Available() >= 400 && ring.Available() <= 768, "trimmed to the target");
    CHECK(out[255 * 2] != 0, "audio comes out at once");
}

// A ring that fills completely must still trigger stall recovery.
void TestStallRecoveryWithLargeSourceBuffer()
{
    blend::FrameRing ring(16384, 2);
    blend::SourceReader reader(ring, 48000, 48000, 4096 + 256 + 144, 256);
    std::vector<float> in(4096 * 2, 0.25f), out(256 * 2);
    ring.Write(in.data(), 4096);
    ring.Write(in.data(), 4096);
    reader.Pull(out.data(), 256); // primes
    for (int i = 0; i < 4; i++) {
        ring.Write(in.data(), 4096);
    }
    reader.Pull(out.data(), 256);
    std::printf("stall: %zu queued after a full ring, skips %llu\n", ring.Available(),
        (unsigned long long)reader.Skips());
    CHECK(reader.Skips() == 1, "a full ring triggers recovery");
}


// A block of interleaved stereo frames with a sine on both channels.
std::vector<float> StereoSine(uint32_t frames, double freq, float amplitude)
{
    std::vector<float> x(frames * 2);
    for (uint32_t i = 0; i < frames; i++) {
        x[i * 2] = x[i * 2 + 1] = amplitude * float(std::sin(2 * M_PI * freq * i / 48000));
    }
    return x;
}

double ChannelDb(const std::vector<float>& acc, int channel)
{
    double sum = 0;
    for (size_t i = channel; i < acc.size(); i += 2) {
        sum += double(acc[i]) * acc[i];
    }
    return 10 * std::log10(sum / (acc.size() / 2) + 1e-30);
}

// Split layout: the microphone only on the left, the app only on the right, each at the
// level it came in at.
void TestSplitRouting()
{
    const uint32_t frames = 4800;
    auto mic = StereoSine(frames, 440, 0.5f);
    auto app = StereoSine(frames, 1000, 0.5f);
    std::vector<float> acc(frames * 2, 0.0f);
    blend::AddSource(acc.data(), mic.data(), frames, 1, 1, 1, blend::Route::Left);
    blend::AddSource(acc.data(), app.data(), frames, 1, 1, 1, blend::Route::Right);
    std::vector<float> left(frames), right(frames);
    for (uint32_t i = 0; i < frames; i++) {
        left[i] = acc[i * 2];
        right[i] = acc[i * 2 + 1];
    }
    CHECK(ResidualDb(left, 0, 440, 48000) < -120, "left carries only the mic: %.1f dB",
        ResidualDb(left, 0, 440, 48000));
    CHECK(ResidualDb(right, 0, 1000, 48000) < -120, "right carries only the app: %.1f dB",
        ResidualDb(right, 0, 1000, 48000));
    const double expected = 20 * std::log10(0.5 / std::sqrt(2.0));
    CHECK(std::fabs(ChannelDb(acc, 0) - expected) < 0.1, "mic level kept: %.2f dB", ChannelDb(acc, 0));
    CHECK(std::fabs(ChannelDb(acc, 1) - expected) < 0.1, "app level kept: %.2f dB", ChannelDb(acc, 1));
}

// The usual layout still puts every source on both channels.
void TestStereoRouting()
{
    const uint32_t frames = 480;
    std::vector<float> src(frames * 2);
    for (uint32_t i = 0; i < frames; i++) {
        src[i * 2] = 0.25f;
        src[i * 2 + 1] = -0.5f;
    }
    std::vector<float> acc(frames * 2, 0.0f);
    blend::AddSource(acc.data(), src.data(), frames, 1, 1, 0.5f, blend::Route::Both);
    CHECK(acc[10] == 0.125f && acc[11] == -0.25f, "stereo kept: %f %f", acc[10], acc[11]);
}

// A call at full scale on the right: unlinked, the left keeps its level; linked, as in the
// usual layout, both sides come down together.
void TestLimiterLinking()
{
    const uint32_t frames = 4800;
    const float limit = 0.891f;
    const float release = 1.0f - std::exp(-1.0f / (0.1f * 48000));
    auto run = [&](bool linked) {
        auto me = StereoSine(frames, 440, 0.25f);
        auto call = StereoSine(frames, 1000, 2.0f);
        std::vector<float> acc(frames * 2, 0.0f);
        blend::AddSource(acc.data(), me.data(), frames, 1, 1, 1, blend::Route::Left);
        blend::AddSource(acc.data(), call.data(), frames, 1, 1, 1, blend::Route::Right);
        blend::LimiterState state;
        const float peak = blend::Limit(acc.data(), frames, linked, limit, release, state);
        CHECK(peak <= limit, "held at the limit: %f", peak);
        return ChannelDb(acc, 0);
    };
    const double untouched = 20 * std::log10(0.25 / std::sqrt(2.0));
    const double unlinked = run(false);
    const double linked = run(true);
    CHECK(std::fabs(unlinked - untouched) < 0.05, "unlinked left untouched: %.2f vs %.2f dB",
        unlinked, untouched);
    CHECK(linked < untouched - 6, "linked left pulled down: %.2f dB", linked);
}


// Ducking, driven through MixBlock the way the bus thread calls it: 256-frame blocks at
// 48 kHz, a microphone and a constant "music" source. The music source is constant (DC) so
// that any step in the output is a step in the gain.
struct DuckRun
{
    std::vector<float> music;    // the music's contribution to the mix, mono
    std::vector<float> micGain;  // the mic entry's ramped gain at the end of each block
};

constexpr uint32_t kBlock = 256;
constexpr double kRate = 48000;
constexpr float kMusic = 0.2f;

// `micLevel(t)` gives the microphone's amplitude (a 1 kHz sine) at time t seconds.
template <class Level>
DuckRun RunDuck(double seconds, Level micLevel, bool duck, float micTarget = 1.0f)
{
    const size_t blocks = size_t(seconds * kRate / kBlock);
    std::vector<float> sources(2 * kBlock * 2);
    const uint32_t index[] = {0, 1};
    const float targets[] = {micTarget, 1.0f};
    const blend::Route routes[] = {blend::Route::Both, blend::Route::Both};
    const blend::Role roles[] = {blend::Role::Key, blend::Role::Ducked};
    std::atomic<float> current[2];
    current[0] = micTarget;
    current[1] = 1.0f;
    blend::DuckState state;
    DuckRun run;
    for (size_t b = 0; b < blocks; b++) {
        for (uint32_t i = 0; i < kBlock; i++) {
            const double t = double(b * kBlock + i) / kRate;
            const float mic = float(micLevel(t) * std::sin(2 * M_PI * 1000 * t));
            sources[i * 2] = sources[i * 2 + 1] = mic;
            sources[kBlock * 2 + i * 2] = sources[kBlock * 2 + i * 2 + 1] = kMusic;
        }
        std::vector<float> acc(kBlock * 2, 0.0f);
        blend::MixBlock(acc.data(), kBlock, 2, sources.data(), kBlock * 2, index, targets,
            routes, roles, current, 1.0f, kRate, duck ? &state : nullptr);
        std::vector<float> micOnly(kBlock * 2, 0.0f);
        blend::AddSource(micOnly.data(), sources.data(), kBlock, micTarget, micTarget, 1.0f,
            blend::Route::Both);
        for (uint32_t i = 0; i < kBlock; i++) {
            run.music.push_back(acc[i * 2] - micOnly[i * 2]);
        }
        run.micGain.push_back(current[0].load());
    }
    return run;
}

double DbAt(const DuckRun& run, double t)
{
    return 20 * std::log10(std::fabs(run.music[size_t(t * kRate)]) / kMusic);
}

double Dbfs(double amplitude)
{
    return 20 * std::log10(amplitude);
}

void TestDuckAttackHoldRelease()
{
    // The voice is on from 1.0 s to 2.0 s, at -20 dBFS peak.
    auto voice = [](double t) { return t >= 1.0 && t < 2.0 ? 0.1 : 0.0; };
    const DuckRun run = RunDuck(4.0, voice, true);
    CHECK(std::fabs(DbAt(run, 0.9)) < 0.01, "untouched before the voice: %.2f dB", DbAt(run, 0.9));
    CHECK(std::fabs(DbAt(run, 1.0 + 0.012) + 12) < 0.5, "full depth within the attack: %.2f dB",
        DbAt(run, 1.012));
    CHECK(DbAt(run, 1.0 + 0.003) > -12 + 1, "attack is a ramp, not a step: %.2f dB",
        DbAt(run, 1.003));
    CHECK(std::fabs(DbAt(run, 1.9) + 12) < 0.5, "held while talking: %.2f dB", DbAt(run, 1.9));
    CHECK(std::fabs(DbAt(run, 2.0 + 0.28) + 12) < 0.5, "held 280 ms after the voice: %.2f dB",
        DbAt(run, 2.28));
    CHECK(std::fabs(DbAt(run, 2.0 + 0.3 + 0.25) + 6) < 1.0, "half way back after 250 ms: %.2f dB",
        DbAt(run, 2.55));
    CHECK(std::fabs(DbAt(run, 2.0 + 0.3 + 0.5 + 0.02)) < 0.3,
        "recovered after the release: %.2f dB", DbAt(run, 2.82));
    for (float g : run.micGain) {
        CHECK(g == 1.0f, "the microphone is never ducked: %f", g);
        if (g != 1.0f) {
            break;
        }
    }
}

void TestDuckHasNoSteps()
{
    auto voice = [](double t) { return t >= 1.0 && t < 2.0 ? 0.1 : 0.0; };
    const DuckRun run = RunDuck(4.0, voice, true);
    float worst = 0;
    for (size_t i = 1; i < run.music.size(); i++) {
        worst = std::max(worst, std::fabs(run.music[i] - run.music[i - 1]));
    }
    // Fastest legitimate change: 12 dB over 10 ms is about 0.0003 per sample at 0.2.
    CHECK(worst < 0.001, "largest sample step %.5f", worst);
}

void TestDuckThreshold()
{
    auto quiet = [](double) { return 0.002; }; // -54 dBFS peak, room noise
    auto soft = [](double) { return 0.05; };   // -26 dBFS peak, a soft voice
    const DuckRun low = RunDuck(1.0, quiet, true);
    const DuckRun high = RunDuck(1.0, soft, true);
    CHECK(std::fabs(DbAt(low, 0.9)) < 0.01, "room noise does not duck: %.2f dB", DbAt(low, 0.9));
    CHECK(std::fabs(DbAt(high, 0.9) + 12) < 0.5, "a soft voice ducks: %.2f dB", DbAt(high, 0.9));
    CHECK(Dbfs(0.05 / std::sqrt(2.0)) > Dbfs(blend::kDuckThreshold), "test voice is above");
    // A muted microphone is not talking.
    const DuckRun muted = RunDuck(1.0, soft, true, 0.0f);
    CHECK(std::fabs(DbAt(muted, 0.9)) < 0.01, "a muted mic does not duck: %.2f dB",
        DbAt(muted, 0.9));
}

void TestDuckOffIsBitExact()
{
    // Reference: the loop the bus thread ran before ducking existed.
    const uint32_t frames = 256;
    std::vector<float> sources(3 * frames * 2);
    uint32_t seed = 12345;
    for (float& v : sources) {
        seed = seed * 1664525u + 1013904223u;
        v = float(int32_t(seed >> 8) - (1 << 23)) / float(1 << 23);
    }
    const uint32_t index[] = {2, 0, 1};
    const float targets[] = {0.7f, 0.25f, 1.3f};
    const float starts[] = {0.7f, 0.5f, 1.0f};
    const blend::Route routes[] = {blend::Route::Both, blend::Route::Left, blend::Route::Right};
    // The roles must not matter while ducking is off, nor while it is on and nobody talks.
    const blend::Role roles[] = {blend::Role::Key, blend::Role::Ducked, blend::Role::Ducked};
    std::vector<float> reference(frames * 2, 0.0f);
    for (int e = 0; e < 3; e++) {
        blend::AddSource(reference.data(), &sources[index[e] * frames * 2], frames, starts[e],
            targets[e], 0.9f, routes[e]);
    }
    for (bool engaged : {false, true}) {
        std::vector<float> acc(frames * 2, 0.0f);
        std::atomic<float> current[3] = {starts[0], starts[1], starts[2]};
        blend::DuckState state;
        std::vector<float> silent = sources;
        if (engaged) {
            // Entry 0 is the key: make its level zero.
            std::fill_n(&silent[index[0] * frames * 2], frames * 2, 0.0f);
            std::vector<float> ref2(frames * 2, 0.0f);
            for (int e = 0; e < 3; e++) {
                blend::AddSource(ref2.data(), &silent[index[e] * frames * 2], frames, starts[e],
                    targets[e], 0.9f, routes[e]);
            }
            blend::MixBlock(acc.data(), frames, 3, silent.data(), frames * 2, index, targets,
                routes, roles, current, 0.9f, kRate, &state);
            CHECK(std::memcmp(acc.data(), ref2.data(), acc.size() * sizeof(float)) == 0,
                "idle ducking is bit-exact");
        } else {
            blend::MixBlock(acc.data(), frames, 3, sources.data(), frames * 2, index, targets,
                routes, roles, current, 0.9f, kRate, nullptr);
            CHECK(std::memcmp(acc.data(), reference.data(), acc.size() * sizeof(float)) == 0,
                "ducking off is bit-exact");
        }
        for (int e = 0; e < 3; e++) {
            CHECK(current[e].load() == targets[e], "ramp ends at the target");
        }
    }
}

} // namespace

int main()
{
    TestRingWrapsAndCountsOverflow();
    TestPrimingAfterBacklog();
    TestStallRecoveryWithLargeSourceBuffer();
    TestResamplerQuality(48000, 48000, 1000, -80);
    TestResamplerQuality(24000, 48000, 1000, -70);
    TestResamplerQuality(44100, 48000, 3000, -70);
    TestResamplerQuality(16000, 48000, 1000, -70);
    TestResamplerQuality(96000, 48000, 1000, -70);
    TestDriftControl(48000, +150, 256, 256, 600);
    TestDriftControl(48000, -150, 512, 128, 600);
    TestDriftControl(24000, +80, 480, 256, 600);
    TestDriftControl(44100, -40, 441, 512, 600);
    TestSplitRouting();
    TestStereoRouting();
    TestLimiterLinking();
    TestDuckAttackHoldRelease();
    TestDuckHasNoSteps();
    TestDuckThreshold();
    TestDuckOffIsBitExact();
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
