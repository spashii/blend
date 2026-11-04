#pragma once

// The bus thread's per-mix arithmetic, kept free of Core Audio so it builds and is tested
// on Linux too (tests/DspTests.cpp).
//
// A mix is stereo, and usually every source goes to both channels. A split mix has two
// sources, the first on the left channel only and the second on the right only, so a
// recorder gets them apart (say "me" and "the call") without any separation step.

#include <algorithm>
#include <cmath>
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
