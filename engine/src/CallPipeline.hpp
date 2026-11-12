#pragma once

// Turns the aligned microphone and call blocks of a capture into one continuous stream at a
// rate that does not change for the life of the capture, and queues it for a delivery
// thread. Pure C++ with no Core Audio, so the conversion, the gaps and the queue can be
// tested without a device.
//
// Threads: Configure and the constructor run on the control thread while no IO runs. Push
// runs on the IO thread and never blocks, allocates or locks. Drain runs on the delivery
// thread. The IO and control threads never run at once (the device is stopped to
// reconfigure), so the only data shared at the same time is the queue and the counters.

#include "FrameRing.hpp"
#include "Resampler.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace blend {

class CallPipeline
{
public:
    // Seconds on any steady clock; replaceable so a test can make time pass.
    using Clock = double (*)();
    static double HostSeconds();

    // `ringSeconds` of output can wait for the delivery thread before frames are dropped.
    CallPipeline(uint32_t outputRate, double ringSeconds = 4, Clock clock = HostSeconds);

    uint32_t OutputRate() const { return outputRate_; }

    // Control thread, IO stopped: the input rate from now on. After the first call, the
    // time until the next Push is filled with silence, so the output keeps pace with the
    // clock across a restart.
    void Configure(double inputRate);
    double InputRate() const { return inputRate_; }

    // IO thread. `call` is null when no call audio exists, and is then silence.
    void Push(const float* me, const float* call, uint32_t frames);

    // Delivery thread. Calls deliver(me, call, frames, position) in order for everything
    // queued, filling any hole in the positions (a restart, a dropped block) with silence.
    // Returns the frames delivered.
    template <typename Deliver>
    uint64_t Drain(Deliver&& deliver);

    // Any thread.
    uint64_t Overflows() const { return overflows_.load(std::memory_order_relaxed); }
    uint64_t DroppedFrames() const { return dropped_.load(std::memory_order_relaxed); }
    uint64_t Pushes() const { return pushes_.load(std::memory_order_relaxed); }
    // True once since the last call if a Call sample was not exactly zero.
    bool TakeHeard() { return heard_.exchange(false, std::memory_order_relaxed); }
    // Output frames produced so far, gaps included.
    uint64_t Position() const { return produced_.load(std::memory_order_relaxed); }

private:
    struct Segment
    {
        uint64_t position = 0;
        uint32_t frames = 0;
    };
    static constexpr size_t kSegments = 4096;
    static constexpr uint32_t kChunk = 128;
    static constexpr uint32_t kMaxBlock = 2048;
    static constexpr uint32_t kDeliverFrames = 4800;

    void PushBlock(const float* me, const float* call, uint32_t frames);
    void Queue(const float* stereo, uint32_t frames);

    const uint32_t outputRate_;
    const Clock clock_;
    double inputRate_ = 0;
    bool configured_ = false;
    bool gapPending_ = false;
    bool hasData_ = false;
    double lastPush_ = 0;
    bool bypass_ = true;
    std::unique_ptr<Resampler> resampler_;
    std::vector<float> fifo_;   // interleaved stereo, input rate
    size_t fifoFrames_ = 0;
    std::vector<float> stereo_; // one block, interleaved
    std::vector<float> out_;    // converted output of one block, interleaved
    uint64_t position_ = 0;     // IO thread: position of the next frame to produce

    FrameRing ring_;
    std::array<Segment, kSegments> segments_;
    alignas(64) std::atomic<size_t> segmentWrite_{0};
    alignas(64) std::atomic<size_t> segmentRead_{0};
    std::atomic<uint64_t> produced_{0};
    std::atomic<uint64_t> overflows_{0};
    std::atomic<uint64_t> dropped_{0};
    std::atomic<uint64_t> pushes_{0};
    std::atomic<bool> heard_{false};

    // Delivery thread.
    uint64_t delivered_ = 0;
    const std::vector<float> silence_;
    std::vector<float> readStereo_;
    std::vector<float> readMe_;
    std::vector<float> readCall_;
};

// Decides when a call that should be audible is not. The caller reports each second
// whether any Call sample was non-zero and whether the call app is producing sound.
class SilenceDetector
{
public:
    enum class Change
    {
        None,
        Silent, // zeros for the whole window while the app plays
        Heard,  // the first sound after Silent
    };

    explicit SilenceDetector(double silentAfter = 3)
        : silentAfter_(silentAfter)
    {
    }

    Change Tick(bool heard, bool playing, double seconds)
    {
        if (heard) {
            zeros_ = 0;
            if (silent_) {
                silent_ = false;
                return Change::Heard;
            }
            return Change::None;
        }
        if (!playing) {
            zeros_ = 0;
            return Change::None;
        }
        zeros_ += seconds;
        if (zeros_ >= silentAfter_ && !silent_) {
            silent_ = true;
            return Change::Silent;
        }
        return Change::None;
    }

    void Reset()
    {
        zeros_ = 0;
        silent_ = false;
    }
    bool Silent() const { return silent_; }

private:
    double silentAfter_;
    double zeros_ = 0;
    bool silent_ = false;
};

template <typename Deliver>
uint64_t CallPipeline::Drain(Deliver&& deliver)
{
    uint64_t total = 0;
    auto emit = [&](const float* me, const float* call, uint32_t frames) {
        deliver(me, call, frames, delivered_);
        delivered_ += frames;
        total += frames;
    };
    for (;;) {
        const size_t r = segmentRead_.load(std::memory_order_relaxed);
        if (r == segmentWrite_.load(std::memory_order_acquire)) {
            break;
        }
        const Segment segment = segments_[r % kSegments];
        // Frames that never arrived are silence, so the stream keeps its length.
        while (delivered_ < segment.position) {
            emit(silence_.data(), silence_.data(),
                uint32_t(std::min<uint64_t>(kDeliverFrames, segment.position - delivered_)));
        }
        for (uint32_t done = 0; done < segment.frames;) {
            const uint32_t n = std::min(kDeliverFrames, segment.frames - done);
            ring_.Read(readStereo_.data(), n);
            for (uint32_t i = 0; i < n; i++) {
                readMe_[i] = readStereo_[size_t(i) * 2];
                readCall_[i] = readStereo_[size_t(i) * 2 + 1];
            }
            emit(readMe_.data(), readCall_.data(), n);
            done += n;
        }
        segmentRead_.store(r + 1, std::memory_order_release);
    }
    return total;
}

} // namespace blend
