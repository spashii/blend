#pragma once

// Moves one source's frames from its own clock onto the bus clock. The source's IO thread
// fills the ring; the bus thread pulls exactly the frames it needs, and a proportional
// controller nudges the resampling ratio to hold the ring at its target fill, so drift
// between the two clocks never accumulates into dropouts.

#include "FrameRing.hpp"
#include "Resampler.hpp"

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>

namespace blend {

class SourceReader
{
public:
    // targetFrames is the ring fill to hold, in source frames: enough to cover one source
    // IO buffer plus one bus buffer plus scheduling jitter.
    SourceReader(FrameRing& ring, double sourceRate, double busRate, size_t targetFrames,
        uint32_t maxBusFrames = 4096)
        : ring_(ring)
        , resampler_(ring.Channels(), sourceRate, busRate, maxBusFrames)
        , target_(double(targetFrames))
        , sourceRate_(sourceRate)
    {
    }

    // Bus thread. Always writes `frames` frames; silence while priming or after an underrun.
    void Pull(float* out, uint32_t frames)
    {
        const double fill = double(ring_.Available());
        if (priming_) {
            if (fill < target_) {
                std::memset(out, 0, sizeof(float) * frames * ring_.Channels());
                return;
            }
            // Start exactly at target: a source delivers whole buffers, so the first fill
            // overshoots, and the controller would otherwise bend pitch to work it off.
            ring_.Skip(size_t(fill - target_));
            priming_ = false;
            error_ = 0;
        }
        // Far too much queued (the bus stalled, or the source restarted): jump back to the
        // target instead of slowly draining seconds of stale audio. The limit stays below
        // the ring's capacity, or a ring that filled up would never trigger it.
        const double queued = double(ring_.Available());
        const double limit = std::min(target_ * 4 + 4096, double(ring_.Capacity()) - 1024);
        if (queued > limit) {
            ring_.Skip(size_t(queued - target_));
            resampler_.Reset();
            error_ = 0;
            skips_.fetch_add(1, std::memory_order_relaxed);
        }
        // Smooth over about 200 bus cycles: fill is a sawtooth of the two block sizes.
        error_ += 0.005 * ((double(ring_.Available()) - target_) - error_);
        // Two-second time constant, limited to 0.5% so a jump never sounds like a pitch bend.
        const double correction = 1.0 + std::clamp(error_ / (2 * sourceRate_), -0.005, 0.005);
        correction_.store(correction, std::memory_order_relaxed);
        if (ring_.Available() < resampler_.InputNeeded(frames, correction)) {
            std::memset(out, 0, sizeof(float) * frames * ring_.Channels());
            resampler_.Reset();
            priming_ = true;
            underruns_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        resampler_.Process(out, frames, correction,
            [this](float* dst, size_t n) { ring_.Read(dst, n); });
    }

    // Bus thread, when the source is (re)started.
    void Restart()
    {
        ring_.Skip(ring_.Available());
        resampler_.Reset();
        priming_ = true;
        error_ = 0;
    }

    uint64_t Underruns() const { return underruns_.load(std::memory_order_relaxed); }
    uint64_t Skips() const { return skips_.load(std::memory_order_relaxed); }
    double Correction() const { return correction_.load(std::memory_order_relaxed); }
    double Target() const { return target_; }

private:
    FrameRing& ring_;
    Resampler resampler_;
    double target_;
    double sourceRate_;
    bool priming_ = true;
    double error_ = 0;
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> skips_{0};
    std::atomic<double> correction_{1.0};
};

} // namespace blend
