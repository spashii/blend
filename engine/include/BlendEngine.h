// C interface to the Blend engine, for the Swift app.

#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BlendEngine BlendEngine;

#define BLEND_MAX_SOURCES 16
#define BLEND_MAX_USERS 4

typedef struct
{
    char id[64];
    bool deviceReady; // the driver has created this mix's device
    bool running;     // some other app is reading it
    int userCount;
    char users[BLEND_MAX_USERS][64]; // names of the apps reading it
    float peak;       // highest sample level since the previous call, 0 to 1
    int sourceCount;
    float sourcePeaks[BLEND_MAX_SOURCES]; // per source, in configuration order
    bool sourceLive[BLEND_MAX_SOURCES];   // per source: capturing right now
} BlendMixStatus;

BlendEngine* BlendEngineCreate(void);
void BlendEngineDestroy(BlendEngine* engine);

// Replaces the whole configuration (JSON, see engine/src/Config.hpp). On failure returns
// false and writes a message into error.
bool BlendEngineApply(BlendEngine* engine, const char* json, char* error, size_t errorSize);

// Writes up to capacity statuses in configuration order and returns how many were written.
size_t BlendEngineStatus(BlendEngine* engine, BlendMixStatus* statuses, size_t capacity);

// Returns a malloc'd, human-readable summary; free it with free().
char* BlendEngineDiagnostics(BlendEngine* engine);

// Runs one mix so it can be checked; with live, it also plays to the default output.
// Starting another check stops the previous one.
void BlendEngineStartCheck(BlendEngine* engine, const char* mixID, bool live);
void BlendEngineStopCheck(BlendEngine* engine);

// Copies what a mix carried since its check started (48 kHz interleaved stereo, oldest
// first, at most maxFrames) and returns the number of frames copied.
size_t BlendEngineCopyCheck(BlendEngine* engine, const char* mixID, float* stereo,
    size_t maxFrames);

// Running app copies as a malloc'd JSON array of
// {"bundleID", "name", "pid", "identity", "label", "playing", "listening"}; free it with
// free(). listening means the app is using a microphone, as a call app does in a call.
// identity tells copies of one app apart (engine/src/Identity.hpp).
char* BlendCopyRunningApps(void);

// Meters app copies without mixing them, for the source picker: a JSON array of
// {"bundleID", "instance"}. An empty array stops metering.
bool BlendEngineSetProbes(BlendEngine* engine, const char* json, char* error, size_t errorSize);

// Peak since the previous call for each probed copy, in the order given.
size_t BlendEngineProbeLevels(BlendEngine* engine, float* levels, size_t capacity);

// Silences one probed copy's own output while muted is true.
void BlendEngineMuteProbe(BlendEngine* engine, size_t index, bool muted);

#ifdef __cplusplus
}
#endif
