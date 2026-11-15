// C interface to BlendKit: recording both sides of an online call, and metering the apps
// that could be part of one. Declared beside BlendEngine.h, which is unchanged.
//
// No call here may be made from a callback this interface delivers, except
// BKCallCaptureStop, which is safe from the frames callback.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The Blend release this library was built from, such as "0.9.0". Static; do not free.
const char* BKVersion(void);

typedef struct BKCallCapture BKCallCapture;
typedef struct BKProbes BKProbes;

typedef enum
{
    BKEchoCancellationOff = 0,
    BKEchoCancellationOn = 1,
    // On for a physical microphone (built in, USB, Bluetooth), off for a virtual one.
    BKEchoCancellationAutomatic = 2,
} BKEchoCancellation;

typedef enum
{
    BKIsolationOff = 0,
    BKIsolationStandard = 1,
    BKIsolationHighQuality = 2,
} BKIsolation;

typedef enum
{
    BKStartStarted = 0,
    BKStartMicrophoneUnavailable = 1,
    // The microphone works and the call app's audio could not be tapped; nothing is left
    // running, so the caller can fall back to the microphone alone.
    BKStartCallUnavailable = 2,
} BKStartResult;

// Makeup gain for a built-in microphone array that macOS delivers raw because another app
// holds it with Apple voice processing: how much quieter capsule 0 hears speech than the
// normal input does, in the 300 Hz to 7 kHz band. Measured on the MacBook Air (Mac17,3), see
// docs/internals/measurements.md. A model not in the table in MicCapture.mm uses this
// value, and BKArrayMakeupDb says which applies on this Mac.
#define BK_ARRAY_MAKEUP_DB 14.0f
#define BK_ARRAY_RAMP_MS 50
#define BK_LIMIT_THRESHOLD 0.891f
#define BK_LIMIT_RELEASE_MS 100

typedef enum
{
    // Gain follows the microphone: on while the built-in array arrives raw.
    BKArrayGainAutomatic = 0,
    BKArrayGainOff = 1,
} BKArrayGain;

typedef enum
{
    BKEventMicrophoneRestarted = 1,
    // The microphone has been missing for 10 seconds. A notice; the capture keeps trying.
    BKEventMicrophoneLost = 2,
    // The call app's audio stopped arriving and could not be rebuilt. Call is silence, Me
    // continues from the microphone alone, and the capture retries every 2 seconds. detail
    // says why.
    BKEventCallTapLost = 3,
    BKEventCallTapRestored = 4,
    // The call app has been producing sound for 3 seconds and every Call sample is zero.
    // Usually the System Audio Recording permission was revoked.
    BKEventCallSilent = 5,
    BKEventCallHeard = 6,
    // Echo cancellation stopped working; Me continues unprocessed.
    BKEventEchoCancellationFailed = 7,
    // The frames callback fell about 4 seconds behind and frames were dropped. detail says
    // how many.
    BKEventOverflow = 8,
    BKEventAudioServiceRestarted = 9,
    // The microphone's channel count changed under the running capture because another app
    // started or stopped Apple voice processing. Not a restart: nothing is rebuilt. detail
    // is "raw-array channels=3 holders=net.whatsapp.WhatsApp" or "normal".
    BKEventMicrophoneModeChanged = 10,
} BKEventKind;

typedef struct
{
    // Names the capture's queues and the call app's tap: "<label>: <bundle id>".
    const char* label;
    // NULL follows the default input device, also when it changes.
    const char* microphoneUID;
    BKEchoCancellation echo;
    BKIsolation isolation;
    // The call app, by bundle ID. callInstance tells copies of one app apart (see
    // BlendCopyRunningApps); NULL covers every copy.
    const char* callBundleID;
    const char* callInstance;
    // Frames per second of what the callback receives, fixed for the capture's life; 0 is
    // 48000.
    uint32_t outputRate;
    // BKArrayGainAutomatic or BKArrayGainOff. Zero-initialised structs get Automatic.
    BKArrayGain arrayGain;
} BKCallCaptureOptions;

typedef struct
{
    bool builtIn;
    // Input channels the device lists now.
    uint32_t channels;
    // The device's preferred channel layout tag for input, 0 when it has none.
    uint32_t layoutTag;
    // Apple silicon, built in, more than one channel and a discrete or missing layout.
    bool rawArray;
    // Bundle IDs of the other processes running input, comma separated.
    char holders[256];
} BKMicState;

// The makeup gain in dB for this Mac's raw built-in array: its model's measurement, or
// BK_ARRAY_MAKEUP_DB for a model that has none.
float BKArrayMakeupDb(void);

// Reads a device's microphone state. `uid` NULL is the default input device. False when
// there is no such device.
bool BKMicrophoneState(const char* uid, BKMicState* out);

// Me and Call are mono, at outputRate, for the same instants. `position` counts output
// frames since BKCallCaptureStart and follows the clock: time with no audio (a restart)
// arrives as silence, so positions never skip. Runs on a private queue; the pointers are
// valid only during the call.
typedef void (*BKFramesCallback)(void* context, const float* me, const float* call,
    uint32_t frames, uint64_t position);
// On the same queue as the frames. `detail` may be NULL.
typedef void (*BKEventCallback)(void* context, BKEventKind kind, const char* detail);

// Creates the capture without touching any device. The options are copied.
BKCallCapture* BKCallCaptureCreate(const BKCallCaptureOptions* options, BKFramesCallback frames,
    BKEventCallback events, void* context);
// Blocks until capturing or failed. Not from a callback.
BKStartResult BKCallCaptureStart(BKCallCapture* capture);
// Blocks until the device has stopped and every queued frame has reached the callback.
void BKCallCaptureStop(BKCallCapture* capture);
// Stops, then frees. No callback runs after it returns.
void BKCallCaptureDestroy(BKCallCapture* capture);
// A human-readable summary, malloc'd; free it with free().
char* BKCallCaptureDiagnostics(BKCallCapture* capture);

// Meters app copies without capturing them for anything else.
BKProbes* BKProbesCreate(const char* label);
// `json` is an array of {"bundleID", "instance"} (instance optional); an empty array stops
// metering. On a parse failure returns false and writes a message into error.
bool BKProbesSet(BKProbes* probes, const char* json, char* error, size_t errorSize);
// Peak since the previous call for each probed copy, in the order given, 0 to 1. Returns
// the number written.
size_t BKProbesLevels(BKProbes* probes, float* levels, size_t capacity);
// Silences one probed copy's own output while muted is true.
void BKProbesMute(BKProbes* probes, size_t index, bool muted);
void BKProbesDestroy(BKProbes* probes);

#ifdef __cplusplus
}
#endif
