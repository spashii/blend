#pragma once

// The bus thread's per-mix arithmetic, kept free of Core Audio so it builds and is tested
// on Linux too (tests/DspTests.cpp).
//
// A mix is stereo, and usually every source goes to both channels. A split mix has two
// sources, the first on the left channel only and the second on the right only, so a
// recorder gets them apart (say "me" and "the call") without any separation step.

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace blend {

enum class Route : uint8_t {
    Both,  // stereo in, stereo out
    Left,  // folded to mono, left channel only
    Right, // folded to mono, right channel only
};

// Adds `frames` interleaved stereo frames of `src` into `acc`, ramping the source gain from
// `from` to `to` across the block so a slider never clicks. Folding to mono averages the two
// channels, which keeps a microphone (the same signal on both) at its level.
inline void AddSource(float* acc, const float* src, uint32_t frames, float from, float to,
    float mixGain, Route route)
{
    const float step = (to - from) / float(frames);
    for (uint32_t i = 0; i < frames; i++) {
        const float g = (from + step * float(i)) * mixGain;
        const float l = src[i * 2];
        const float r = src[i * 2 + 1];
        switch (route) {
        case Route::Both:
            acc[i * 2] += l * g;
            acc[i * 2 + 1] += r * g;
            break;
        case Route::Left:
            acc[i * 2] += 0.5f * (l + r) * g;
            break;
        case Route::Right:
            acc[i * 2 + 1] += 0.5f * (l + r) * g;
            break;
        }
    }
}

// Ducking: while a microphone in the mix is talking, every other source is lowered, so the
// call or the music steps back for the voice.
//
// The level that keys it is the microphone's after echo cancellation and voice isolation,
// before its own gain, so the slider does not move the threshold. -40 dBFS RMS sits above
// what those leave of a quiet room and below ordinary speech, so breathing and keyboard
// noise do not duck and a soft voice does.
constexpr float kDuckThresholdDb = -40.0f;
constexpr float kDuckDepthDb = -12.0f;
constexpr float kDuckAttack = 0.010f;  // seconds to reach the full depth
constexpr float kDuckHold = 0.300f;    // seconds the depth stays after the voice stops
constexpr float kDuckRelease = 0.500f; // seconds to come back from the full depth

enum class Role : uint8_t {
    Plain,  // never ducked
    Key,    // a microphone: its level triggers the duck
    Ducked, // lowered while a Key is above the threshold
};

struct DuckState
{
    float db = 0;   // current reduction, 0 down to kDuckDepthDb
    float hold = 0; // seconds of hold left
};

// RMS of interleaved stereo folded to mono.
inline float BlockRms(const float* stereo, uint32_t frames)
{
    float sum = 0;
    for (uint32_t i = 0; i < frames; i++) {
        const float m = 0.5f * (stereo[i * 2] + stereo[i * 2 + 1]);
        sum += m * m;
    }
    return frames ? std::sqrt(sum / float(frames)) : 0.0f;
}

// Advances the duck by one block and returns the linear gain the ducked sources should
// reach at its end. The reduction moves in dB at the attack or release rate, so each block
// ends where the last one began and the per-entry ramp joins them without a step.
inline float DuckStep(float level, uint32_t frames, double rate, DuckState& state)
{
    const float seconds = float(double(frames) / rate);
    const bool talking = level >= std::pow(10.0f, kDuckThresholdDb / 20.0f);
    if (talking) {
        state.hold = kDuckHold;
        state.db = std::max(kDuckDepthDb, state.db + kDuckDepthDb / kDuckAttack * seconds);
    } else {
        state.hold = std::max(0.0f, state.hold - seconds);
        if (state.hold <= 0) {
            state.db = std::min(0.0f, state.db - kDuckDepthDb / kDuckRelease * seconds);
        }
    }
    return std::pow(10.0f, state.db / 20.0f);
}

// Mixes one block of a mix's sources into `acc`: `sources + index[e] * stride` is entry e's
// interleaved stereo, ramped from `current[e]` to `targets[e]`. With `duck` set, the Key
// entries' level moves the duck and the Ducked entries' targets are scaled by it, so the
// reduction rides the same ramps as a slider. With it null, nothing differs from AddSource.
inline void MixBlock(float* acc, uint32_t frames, size_t count, const float* sources,
    size_t stride, const uint32_t* index, const float* targets, const Route* routes,
    const Role* roles, std::atomic<float>* current, float mixGain, double rate, DuckState* duck)
{
    float duckGain = 1;
    if (duck) {
        float level = 0;
        for (size_t e = 0; e < count; e++) {
            if (roles[e] == Role::Key && targets[e] > 0) {
                level = std::max(level, BlockRms(sources + index[e] * stride, frames));
            }
        }
        duckGain = DuckStep(level, frames, rate, *duck);
    }
    for (size_t e = 0; e < count; e++) {
        const float from = current[e].load(std::memory_order_relaxed);
        float to = targets[e];
        if (duck && roles[e] == Role::Ducked) {
            to *= duckGain;
        }
        AddSource(acc, sources + index[e] * stride, frames, from, to, mixGain, routes[e]);
        current[e].store(to, std::memory_order_relaxed);
    }
}

// Peak limiter state for one mix.
struct LimiterState
{
    float gain[2] = {1, 1};
};

// Holds the mix at `limit`: instant attack, a release of `release` per frame, then a hard
// ceiling for the first sample of a transient. Linked, both channels get the same gain, so
// the stereo image stays put. Unlinked, each channel has its own, so in the split layout a
// loud call can't pull the speaker's own voice down. Returns the block's peak.
inline float Limit(float* acc, uint32_t frames, bool linked, float limit, float release,
    LimiterState& state)
{
    float gainL = state.gain[0];
    float gainR = linked ? state.gain[0] : state.gain[1];
    float peak = 0;
    for (uint32_t i = 0; i < frames; i++) {
        const float al = std::fabs(acc[i * 2]);
        const float ar = std::fabs(acc[i * 2 + 1]);
        const float levelL = linked ? std::max(al, ar) : al;
        const float levelR = linked ? levelL : ar;
        const float targetL = levelL > limit ? limit / levelL : 1.0f;
        const float targetR = levelR > limit ? limit / levelR : 1.0f;
        gainL = targetL < gainL ? targetL : gainL + (targetL - gainL) * release;
        gainR = targetR < gainR ? targetR : gainR + (targetR - gainR) * release;
        const float l = std::clamp(acc[i * 2] * gainL, -limit, limit);
        const float r = std::clamp(acc[i * 2 + 1] * gainR, -limit, limit);
        acc[i * 2] = l;
        acc[i * 2 + 1] = r;
        peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
    }
    state.gain[0] = gainL;
    state.gain[1] = gainR;
    return peak;
}

} // namespace blend
