#pragma once

// Variable-ratio resampler: a windowed-sinc filter bank with linear interpolation between
// phases. The ratio can change on every call (drift correction) without recomputing the
// filter or allocating; only the cutoff is fixed, from the nominal ratio.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace blend {

class Resampler
{
public:
    static constexpr int kTaps = 32;
    static constexpr int kPhases = 256;
    static constexpr int kCenter = kTaps / 2 - 1;

    // maxOutFrames and maxCorrection bound the history buffer, which is allocated here once.
    Resampler(uint32_t channels, double inRate, double outRate, uint32_t maxOutFrames = 4096,
        double maxCorrection = 1.01)
        : channels_(channels)
        , step_(inRate / outRate)
    {
        const double cutoff = std::min(1.0, outRate / inRate) * 0.94;
        bank_.resize(size_t(kPhases + 1) * kTaps);
        for (int p = 0; p <= kPhases; p++) {
            const double frac = double(p) / kPhases;
            double sum = 0;
            for (int k = 0; k < kTaps; k++) {
                const double x = double(k - kCenter) - frac;
                const double h = cutoff * Sinc(cutoff * x) * Kaiser(x, kTaps / 2.0, 9.0);
                bank_[size_t(p) * kTaps + k] = float(h);
                sum += h;
            }
            for (int k = 0; k < kTaps; k++) {
                bank_[size_t(p) * kTaps + k] = float(bank_[size_t(p) * kTaps + k] / sum);
            }
        }
        const size_t maxIn = size_t(std::ceil(maxOutFrames * step_ * maxCorrection)) + kTaps + 2;
        history_.assign((maxIn + kTaps) * channels_, 0.0f);
        Reset();
    }

    void Reset()
    {
        std::fill(history_.begin(), history_.end(), 0.0f);
        frames_ = kTaps;
        position_ = kCenter;
    }

    double Ratio() const { return step_; }

    // Input frames the next Process(outFrames, correction) call will ask its source for.
    size_t InputNeeded(uint32_t outFrames, double correction) const
    {
        const double last = position_ + double(outFrames - 1) * step_ * correction;
        const size_t needed = size_t(std::floor(last)) + kTaps - kCenter;
        return needed > frames_ ? needed - frames_ : 0;
    }

    // Writes outFrames frames. fetch(float* dst, size_t frames) must fill exactly that many
    // input frames. correction scales the input step: above 1 consumes input faster.
    template <typename Fetch>
    void Process(float* out, uint32_t outFrames, double correction, Fetch&& fetch)
    {
        const size_t need = InputNeeded(outFrames, correction);
        fetch(&history_[frames_ * channels_], need);
        frames_ += need;

        const double step = step_ * correction;
        for (uint32_t i = 0; i < outFrames; i++) {
            const double t = position_ + double(i) * step;
            const size_t base = size_t(t);
            const double phase = (t - double(base)) * kPhases;
            const int p = std::min(int(phase), kPhases - 1);
            const float a = float(phase - p);
            const float* h0 = &bank_[size_t(p) * kTaps];
            const float* h1 = h0 + kTaps;
            const float* x = &history_[(base - kCenter) * channels_];
            for (uint32_t c = 0; c < channels_; c++) {
                float acc = 0;
                for (int k = 0; k < kTaps; k++) {
                    const float h = h0[k] + a * (h1[k] - h0[k]);
                    acc += h * x[size_t(k) * channels_ + c];
                }
                out[size_t(i) * channels_ + c] = acc;
            }
        }
        position_ += double(outFrames) * step;

        // Keep only the history the next output still needs.
        const size_t drop = size_t(position_) - kCenter;
        if (drop > 0) {
            std::memmove(history_.data(), &history_[drop * channels_],
                (frames_ - drop) * channels_ * sizeof(float));
            frames_ -= drop;
            position_ -= double(drop);
        }
    }

    // Group delay in input frames.
    static constexpr double LatencyFrames() { return kCenter; }

private:
    static double Sinc(double x)
    {
        return std::fabs(x) < 1e-9 ? 1.0 : std::sin(M_PI * x) / (M_PI * x);
    }

    static double BesselI0(double x)
    {
        double sum = 1, term = 1;
        for (int k = 1; k < 50; k++) {
            term *= (x / (2 * k)) * (x / (2 * k));
            sum += term;
        }
        return sum;
    }

    static double Kaiser(double x, double half, double beta)
    {
        const double r = x / half;
        if (std::fabs(r) >= 1) {
            return 0;
        }
        return BesselI0(beta * std::sqrt(1 - r * r)) / BesselI0(beta);
    }

    uint32_t channels_;
    double step_;
    std::vector<float> bank_;
    std::vector<float> history_;
    size_t frames_ = 0;
    double position_ = 0;
};

} // namespace blend
