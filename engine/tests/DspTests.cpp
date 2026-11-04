// Portable tests for the realtime building blocks; they build and run on Linux and macOS.

#include "../src/FrameRing.hpp"
#include "../src/Resampler.hpp"
#include "../src/SourceReader.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
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
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
