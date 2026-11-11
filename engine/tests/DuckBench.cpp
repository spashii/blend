// CPU of a mix block with ducking on and off, over the same input: a microphone, an app and
// system audio into the mix, then the limiter, as the bus thread runs them. Not a test;
// build it with the engine tests and run it by hand: DuckBench [BLOCKS] [RUNS].

#include "../src/MixMath.hpp"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char** argv)
{
    const size_t blocks = argc > 1 ? size_t(std::atoll(argv[1])) : 400000;
    const int runs = argc > 2 ? std::atoi(argv[2]) : 15;
    constexpr uint32_t frames = 256;
    constexpr double rate = 48000;
    constexpr size_t entries = 3;
    // Two seconds of input per source, the microphone talking for half of each second so the
    // duck is engaged and released as it would be on a call.
    constexpr size_t period = 96000 / frames;
    std::vector<std::vector<float>> input(period, std::vector<float>(entries * frames * 2));
    for (size_t b = 0; b < period; b++) {
        for (uint32_t i = 0; i < frames; i++) {
            const double t = double(b * frames + i) / rate;
            const float voice = std::fmod(t, 1.0) < 0.5 ? 0.1f : 0.0f;
            const float mic = voice * float(std::sin(2 * M_PI * 220 * t));
            const float app = 0.2f * float(std::sin(2 * M_PI * 440 * t));
            const float system = 0.1f * float(std::sin(2 * M_PI * 660 * t));
            float* base = input[b].data();
            base[i * 2] = base[i * 2 + 1] = mic;
            base[frames * 2 + i * 2] = base[frames * 2 + i * 2 + 1] = app;
            base[frames * 4 + i * 2] = base[frames * 4 + i * 2 + 1] = system;
        }
    }
    const uint32_t index[] = {0, 1, 2};
    const float targets[] = {1.0f, 0.5f, 0.5f};
    const blend::Route routes[] = {blend::Route::Both, blend::Route::Both, blend::Route::Both};
    const blend::Role roles[] = {blend::Role::Key, blend::Role::Ducked, blend::Role::Ducked};

    auto run = [&](bool duck) {
        std::atomic<float> current[entries];
        for (auto& c : current) {
            c = 1.0f;
        }
        blend::DuckState state;
        blend::LimiterState limiter;
        std::vector<float> acc(frames * 2);
        const float release = 1.0f - std::exp(-1.0f / (0.1f * float(rate)));
        float sink = 0;
        const auto start = std::chrono::steady_clock::now();
        for (size_t b = 0; b < blocks; b++) {
            std::fill(acc.begin(), acc.end(), 0.0f);
            blend::MixBlock(acc.data(), frames, entries, input[b % period].data(), frames * 2,
                index, targets, routes, roles, current, 1.0f, rate, duck ? &state : nullptr);
            sink += blend::Limit(acc.data(), frames, true, 0.891f, release, limiter);
        }
        const auto ns = std::chrono::duration<double, std::nano>(
            std::chrono::steady_clock::now() - start).count();
        if (sink < 0) {
            std::printf("%f\n", sink);
        }
        return ns / double(blocks);
    };

    run(false);
    run(true);
    std::vector<double> off, on;
    for (int r = 0; r < runs; r++) {
        off.push_back(run(false));
        on.push_back(run(true));
    }
    auto report = [&](const char* name, const std::vector<double>& v) {
        double mean = 0;
        for (double x : v) {
            mean += x;
        }
        mean /= double(v.size());
        double var = 0;
        for (double x : v) {
            var += (x - mean) * (x - mean);
        }
        const double sd = std::sqrt(var / double(v.size() - 1));
        const double budget = frames / rate * 1e9;
        std::printf("%-3s %8.1f ns/block  sd %5.1f  (%.4f%% of a %.2f ms buffer)\n", name, mean,
            sd, mean / budget * 100, budget / 1e6);
        return mean;
    };
    const double a = report("off", off);
    const double b = report("on", on);
    std::printf("difference %+.1f ns/block (%+.2f%%), %d runs of %zu blocks\n", b - a,
        (b - a) / a * 100, runs, blocks);
}
