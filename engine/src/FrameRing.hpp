#pragma once

// Single-producer, single-consumer ring of interleaved float frames. The producer is a
// source's IO thread, the consumer the bus IO thread; neither ever blocks or allocates.

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace blend {

class FrameRing
{
public:
    FrameRing(size_t minFrames, uint32_t channels)
        : channels_(channels)
    {
        size_t frames = 1;
        while (frames < minFrames) {
            frames <<= 1;
        }
        mask_ = frames - 1;
        data_.assign(frames * channels, 0.0f);
    }

    uint32_t Channels() const { return channels_; }
    size_t Capacity() const { return mask_ + 1; }

    // Producer side. Frames that do not fit are dropped and counted.
    size_t Write(const float* frames, size_t count)
    {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        const size_t n = std::min(count, Capacity() - (w - r));
        for (size_t done = 0; done < n;) {
            const size_t at = (w + done) & mask_;
            const size_t run = std::min(n - done, Capacity() - at);
            std::memcpy(&data_[at * channels_], frames + done * channels_,
                run * channels_ * sizeof(float));
            done += run;
        }
        write_.store(w + n, std::memory_order_release);
        if (n < count) {
            overflows_.fetch_add(1, std::memory_order_relaxed);
        }
        return n;
    }

    // Consumer side.
    size_t Available() const
    {
        return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_relaxed);
    }

    size_t Read(float* out, size_t count)
    {
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t n = std::min(count, write_.load(std::memory_order_acquire) - r);
        for (size_t done = 0; done < n;) {
            const size_t at = (r + done) & mask_;
            const size_t run = std::min(n - done, Capacity() - at);
            std::memcpy(out + done * channels_, &data_[at * channels_],
                run * channels_ * sizeof(float));
            done += run;
        }
        read_.store(r + n, std::memory_order_release);
        return n;
    }

    void Skip(size_t count)
    {
        const size_t r = read_.load(std::memory_order_relaxed);
        const size_t n = std::min(count, write_.load(std::memory_order_acquire) - r);
        read_.store(r + n, std::memory_order_release);
    }

    uint64_t Overflows() const { return overflows_.load(std::memory_order_relaxed); }

private:
    std::vector<float> data_;
    size_t mask_ = 0;
    uint32_t channels_;
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
    std::atomic<uint64_t> overflows_{0};
};

} // namespace blend
