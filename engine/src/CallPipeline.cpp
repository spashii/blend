#include "CallPipeline.hpp"

#include <chrono>
#include <cmath>
#include <cstring>

namespace blend {

double CallPipeline::HostSeconds()
{
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

CallPipeline::CallPipeline(uint32_t outputRate, double ringSeconds, Clock clock)
    : outputRate_(outputRate)
    , clock_(clock)
    , ring_(size_t(std::max(1.0, ringSeconds * outputRate)), 2)
    , silence_(kDeliverFrames, 0.0f)
    , readStereo_(size_t(kDeliverFrames) * 2)
    , readMe_(kDeliverFrames)
    , readCall_(kDeliverFrames)
{
    stereo_.resize(size_t(kMaxBlock) * 2);
}

void CallPipeline::Configure(double inputRate)
{
    if (!(inputRate >= 1000)) {
        configured_ = false;
        return;
    }
    inputRate_ = inputRate;
    bypass_ = std::lround(inputRate) == long(outputRate_);
    resampler_.reset();
    fifoFrames_ = 0;
    if (!bypass_) {
        resampler_ = std::make_unique<Resampler>(2, inputRate, outputRate_, kChunk);
        // Enough for one block plus what a chunk still needs from the one before.
        const size_t most = size_t(kMaxBlock) + size_t(std::ceil(kChunk * inputRate / outputRate_)) +
                            Resampler::kTaps + 8;
        fifo_.assign(most * 2, 0.0f);
    }
    // A block plus the input carried over, converted, in whole chunks.
    const double ratio = double(outputRate_) / inputRate;
    const double carried = std::ceil(kChunk * inputRate / outputRate_) + Resampler::kTaps + 8;
    out_.assign((size_t(std::ceil((kMaxBlock + carried) * ratio)) + 2 * kChunk) * 2, 0.0f);
    configured_ = true;
    // Time that passes with no IO has to appear in the output.
    gapPending_ = hasData_;
}

void CallPipeline::Push(const float* me, const float* call, uint32_t frames)
{
    if (!configured_) {
        return;
    }
    pushes_.fetch_add(1, std::memory_order_relaxed);
    const double now = clock_();
    if (gapPending_) {
        gapPending_ = false;
        const double gap = now - lastPush_ - double(frames) / inputRate_;
        if (gap > 0) {
            position_ += uint64_t(std::llround(gap * outputRate_));
        }
    }
    lastPush_ = now;
    hasData_ = true;
    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = std::min(kMaxBlock, frames - done);
        PushBlock(me + done, call ? call + done : nullptr, n);
        done += n;
    }
}

void CallPipeline::PushBlock(const float* me, const float* call, uint32_t frames)
{
    if (call && !heard_.load(std::memory_order_relaxed)) {
        for (uint32_t i = 0; i < frames; i++) {
            if (call[i] != 0.0f) {
                heard_.store(true, std::memory_order_relaxed);
                break;
            }
        }
    }
    float* stereo = bypass_ ? out_.data() : stereo_.data();
    for (uint32_t i = 0; i < frames; i++) {
        stereo[size_t(i) * 2] = me[i];
        stereo[size_t(i) * 2 + 1] = call ? call[i] : 0.0f;
    }
    if (bypass_) {
        Queue(stereo, frames);
        return;
    }
    std::memcpy(&fifo_[fifoFrames_ * 2], stereo, size_t(frames) * 2 * sizeof(float));
    fifoFrames_ += frames;
    uint32_t produced = 0;
    size_t consumed = 0;
    // The resampler pulls the input it needs from the front of the FIFO.
    for (;;) {
        const size_t need = resampler_->InputNeeded(kChunk, 1.0);
        if (fifoFrames_ - consumed < need) {
            break;
        }
        resampler_->Process(&out_[size_t(produced) * 2], kChunk, 1.0,
            [&](float* dst, size_t count) {
                std::memcpy(dst, &fifo_[consumed * 2], count * 2 * sizeof(float));
                consumed += count;
            });
        produced += kChunk;
    }
    if (consumed) {
        std::memmove(fifo_.data(), &fifo_[consumed * 2], (fifoFrames_ - consumed) * 2 * sizeof(float));
        fifoFrames_ -= consumed;
    }
    if (produced) {
        Queue(out_.data(), produced);
    }
}

// All or nothing: a dropped block leaves a hole in the positions, which the delivery thread
// fills with silence, so a slow consumer costs audio and never shifts what follows.
void CallPipeline::Queue(const float* stereo, uint32_t frames)
{
    const uint64_t position = position_;
    position_ += frames;
    produced_.store(position_, std::memory_order_relaxed);
    const size_t w = segmentWrite_.load(std::memory_order_relaxed);
    const size_t r = segmentRead_.load(std::memory_order_acquire);
    if (w - r >= kSegments || ring_.Capacity() - ring_.Available() < frames) {
        overflows_.fetch_add(1, std::memory_order_relaxed);
        dropped_.fetch_add(frames, std::memory_order_relaxed);
        return;
    }
    ring_.Write(stereo, frames);
    segments_[w % kSegments] = {position, frames};
    segmentWrite_.store(w + 1, std::memory_order_release);
}

} // namespace blend
