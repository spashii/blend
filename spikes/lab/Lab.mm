// Blend lab: throwaway harness for spikes S1 (driver lifecycle) and S3 (app capture).
// It runs as an app bundle so macOS attributes microphone and system audio permission
// to it instead of the ssh session; run it through lab.sh, which uses `open`.

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#include "BlendEngine.h"

#include <dlfcn.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr const char* kBusUID = "app.blend.bus";
constexpr const char* kMixUIDPrefix = "app.blend.mix.";
constexpr const char* kDriverBundleID = "app.blend.driver";
constexpr AudioObjectPropertySelector kMixListProperty = 'bmxs';
constexpr int64_t kCounterMask = 0xFFFFF;
constexpr double kCounterScale = 1.0 / 1048576.0;

double Now()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void Sleep(double seconds)
{
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
}

std::string Str(CFStringRef s)
{
    if (!s) {
        return "";
    }
    char buf[1024];
    return CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8) ? buf : "";
}

std::string FourCC(UInt32 v)
{
    char c[5] = {char(v >> 24), char(v >> 16), char(v >> 8), char(v), 0};
    for (int i = 0; i < 4; i++) {
        if (c[i] < 32 || c[i] > 126) {
            return std::to_string(v);
        }
    }
    return c;
}

AudioObjectPropertyAddress Addr(AudioObjectPropertySelector sel,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    return {sel, scope, kAudioObjectPropertyElementMain};
}

template <typename T>
bool GetProp(AudioObjectID obj, AudioObjectPropertySelector sel, T& out,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal)
{
    auto a = Addr(sel, scope);
    UInt32 size = sizeof(T);
    return AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, &out) == noErr;
}

std::string GetString(AudioObjectID obj, AudioObjectPropertySelector sel)
{
    CFStringRef s = nullptr;
    if (!GetProp(obj, sel, s) || !s) {
        return "";
    }
    auto r = Str(s);
    CFRelease(s);
    return r;
}

template <typename T>
std::vector<T> GetArray(AudioObjectID obj, AudioObjectPropertySelector sel)
{
    auto a = Addr(sel);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, nullptr, &size) != noErr) {
        return {};
    }
    std::vector<T> v(size / sizeof(T));
    if (AudioObjectGetPropertyData(obj, &a, 0, nullptr, &size, v.data()) != noErr) {
        return {};
    }
    v.resize(size / sizeof(T));
    return v;
}

AudioObjectID Translate(AudioObjectPropertySelector sel, const char* key)
{
    CFStringRef s = CFStringCreateWithCString(nullptr, key, kCFStringEncodingUTF8);
    AudioObjectID out = kAudioObjectUnknown;
    auto a = Addr(sel);
    UInt32 size = sizeof(out);
    AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &a, sizeof(CFStringRef), &s, &size, &out);
    CFRelease(s);
    return out;
}

AudioObjectID DeviceForUID(const std::string& uid)
{
    return Translate(kAudioHardwarePropertyTranslateUIDToDevice, uid.c_str());
}

AudioObjectID DriverPlugin()
{
    return Translate(kAudioHardwarePropertyTranslateBundleIDToPlugIn, kDriverBundleID);
}

UInt32 Channels(AudioObjectID dev, AudioObjectPropertyScope scope)
{
    auto a = Addr(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &a, 0, nullptr, &size) != noErr || size == 0) {
        return 0;
    }
    std::vector<uint8_t> buf(size);
    auto list = reinterpret_cast<AudioBufferList*>(buf.data());
    if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &size, list) != noErr) {
        return 0;
    }
    UInt32 n = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        n += list->mBuffers[i].mNumberChannels;
    }
    return n;
}

void PrintDevice(AudioObjectID dev)
{
    UInt32 transport = 0, hidden = 0, domain = 0;
    Float64 rate = 0;
    GetProp(dev, kAudioDevicePropertyTransportType, transport);
    GetProp(dev, kAudioDevicePropertyIsHidden, hidden);
    GetProp(dev, kAudioDevicePropertyClockDomain, domain);
    GetProp(dev, kAudioDevicePropertyNominalSampleRate, rate);
    printf("%5u  %-34s %-40s %-5s in=%-2u out=%-2u %6.0f Hz%s domain=%s\n", dev,
        GetString(dev, kAudioObjectPropertyName).c_str(),
        GetString(dev, kAudioDevicePropertyDeviceUID).c_str(), FourCC(transport).c_str(),
        Channels(dev, kAudioObjectPropertyScopeInput),
        Channels(dev, kAudioObjectPropertyScopeOutput), rate, hidden ? " hidden" : "",
        FourCC(domain).c_str());
}

bool RequestMicrophone()
{
    auto status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        return true;
    }
    __block BOOL granted = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL ok) {
                               granted = ok;
                               dispatch_semaphore_signal(done);
                             }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    printf("microphone permission: %s\n", granted ? "granted" : "denied");
    return granted;
}

// Mix list control through the driver's custom property.

NSArray* GetMixes()
{
    AudioObjectID plugin = DriverPlugin();
    if (plugin == kAudioObjectUnknown) {
        return nil;
    }
    CFPropertyListRef list = nullptr;
    if (!GetProp(plugin, kMixListProperty, list) || !list) {
        return nil;
    }
    return CFBridgingRelease(list);
}

bool SetMixes(NSArray* mixes)
{
    AudioObjectID plugin = DriverPlugin();
    auto a = Addr(kMixListProperty);
    CFPropertyListRef list = (__bridge CFPropertyListRef)mixes;
    return AudioObjectSetPropertyData(plugin, &a, 0, nullptr, sizeof(list), &list) == noErr;
}

NSDictionary* Mix(NSString* mixID, NSString* name, int slot)
{
    return @{@"id" : mixID, @"name" : name, @"slot" : @(slot)};
}

std::string MixUID(NSString* mixID)
{
    return std::string(kMixUIDPrefix) + mixID.UTF8String;
}

// Waits until the HAL resolves `uid` to a device (or to nothing when `present` is false).
double WaitForDevice(const std::string& uid, bool present, double timeout = 3.0)
{
    double start = Now();
    while (Now() - start < timeout) {
        bool found = DeviceForUID(uid) != kAudioObjectUnknown;
        if (found == present) {
            return Now() - start;
        }
        Sleep(0.002);
    }
    return -1;
}

// Bus writer: slot s carries a sine at 220*(s+1) Hz on the left channel and a frame
// counter on the right, so a reader can detect every dropped, repeated or late frame.

struct Writer
{
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    std::atomic<uint64_t> cycles{0};
    std::atomic<uint32_t> channels{0};
};

OSStatus WriterProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
    const AudioTimeStamp*, AudioBufferList* out, const AudioTimeStamp* outTime, void* ctx)
{
    auto w = static_cast<Writer*>(ctx);
    if (out->mNumberBuffers < 1) {
        return noErr;
    }
    AudioBuffer& b = out->mBuffers[0];
    const UInt32 ch = b.mNumberChannels;
    const UInt32 frames = b.mDataByteSize / (sizeof(float) * ch);
    auto data = static_cast<float*>(b.mData);
    const int64_t t0 = int64_t(outTime->mSampleTime);
    for (UInt32 f = 0; f < frames; f++) {
        const int64_t t = t0 + f;
        const float counter = float(double(t & kCounterMask) * kCounterScale);
        for (UInt32 s = 0; s + 1 < ch; s += 2) {
            const double hz = 220.0 * (s / 2 + 1);
            data[f * ch + s] = float(0.2 * std::sin(2 * M_PI * hz * double(t) / 48000.0));
            data[f * ch + s + 1] = counter;
        }
    }
    w->channels.store(ch, std::memory_order_relaxed);
    w->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

bool StartWriter(Writer& w)
{
    w.device = DeviceForUID(kBusUID);
    if (w.device == kAudioObjectUnknown) {
        printf("bus device not found\n");
        return false;
    }
    if (AudioDeviceCreateIOProcID(w.device, WriterProc, &w, &w.proc) != noErr ||
        AudioDeviceStart(w.device, w.proc) != noErr) {
        printf("could not start the bus\n");
        return false;
    }
    return true;
}

void StopWriter(Writer& w)
{
    if (w.proc) {
        AudioDeviceStop(w.device, w.proc);
        AudioDeviceDestroyIOProcID(w.device, w.proc);
        w.proc = nullptr;
    }
}

struct Reader
{
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = nullptr;
    // Written only on the IO thread.
    std::atomic<uint64_t> frames{0}, silent{0}, glitches{0}, cycles{0}, offsetChanges{0};
    std::atomic<int64_t> offset{-1};
    std::atomic<float> peak{0};
    std::atomic<double> firstSoundAt{0}, lastSoundAt{0};
    std::atomic<uint64_t> crossings{0}, soundFrames{0};
    int64_t prev = -1;
    float lastLeft = 0;
    // Optional capture of everything read, for offline analysis.
    std::vector<float> capture;
    std::atomic<size_t> captured{0};
};

void WriteFloatWav(const std::string& path, const float* samples, size_t frames,
    uint16_t channels, uint32_t rate)
{
    FILE* out = fopen(path.c_str(), "wb");
    const uint32_t bytes = uint32_t(frames * channels * sizeof(float));
    const uint32_t header[] = {0x46464952, 36 + bytes, 0x45564157, 0x20746d66, 16};
    const uint16_t fmt[] = {3, channels};
    const uint32_t rates[] = {rate, rate * channels * 4};
    const uint16_t align[] = {uint16_t(channels * 4), 32};
    const uint32_t data[] = {0x61746164, bytes};
    fwrite(header, sizeof(header), 1, out);
    fwrite(fmt, sizeof(fmt), 1, out);
    fwrite(rates, sizeof(rates), 1, out);
    fwrite(align, sizeof(align), 1, out);
    fwrite(data, sizeof(data), 1, out);
    fwrite(samples, sizeof(float), frames * channels, out);
    fclose(out);
}

OSStatus ReaderProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* in,
    const AudioTimeStamp* inTime, AudioBufferList*, const AudioTimeStamp*, void* ctx)
{
    auto r = static_cast<Reader*>(ctx);
    if (in->mNumberBuffers < 1) {
        return noErr;
    }
    const AudioBuffer& b = in->mBuffers[0];
    const UInt32 ch = b.mNumberChannels;
    const UInt32 frames = b.mDataByteSize / (sizeof(float) * ch);
    auto data = static_cast<const float*>(b.mData);
    const int64_t t0 = int64_t(inTime->mSampleTime);
    if (!r->capture.empty() && ch >= 2) {
        size_t at = r->captured.load(std::memory_order_relaxed);
        const size_t n = std::min<size_t>(frames, r->capture.size() / 2 - at);
        for (size_t f = 0; f < n; f++) {
            r->capture[(at + f) * 2] = data[f * ch];
            r->capture[(at + f) * 2 + 1] = data[f * ch + 1];
        }
        r->captured.store(at + n, std::memory_order_relaxed);
    }
    float peak = r->peak.load(std::memory_order_relaxed);
    uint64_t silent = 0, glitches = 0, offsetChanges = 0;
    int64_t offset = r->offset.load(std::memory_order_relaxed);
    bool sound = false;
    for (UInt32 f = 0; f < frames; f++) {
        const float left = data[f * ch];
        const float right = ch > 1 ? data[f * ch + 1] : 0;
        if (left == 0 && right == 0) {
            silent++;
            r->prev = -1;
            continue;
        }
        sound = true;
        r->soundFrames.fetch_add(1, std::memory_order_relaxed);
        if ((left >= 0) != (r->lastLeft >= 0)) {
            r->crossings.fetch_add(1, std::memory_order_relaxed);
        }
        r->lastLeft = left;
        const int64_t v = std::llround(double(right) / kCounterScale) & kCounterMask;
        const int64_t off = ((t0 + f - v) % (kCounterMask + 1) + (kCounterMask + 1)) %
                            (kCounterMask + 1);
        if (off != offset) {
            if (offset >= 0) {
                offsetChanges++;
            }
            offset = off;
        }
        if (r->prev >= 0 && v != ((r->prev + 1) & kCounterMask)) {
            glitches++;
        }
        r->prev = v;
        peak = std::max(peak, std::fabs(left));
    }
    if (sound) {
        double now = Now();
        if (r->firstSoundAt.load(std::memory_order_relaxed) == 0) {
            r->firstSoundAt.store(now, std::memory_order_relaxed);
        }
        r->lastSoundAt.store(now, std::memory_order_relaxed);
    }
    r->peak.store(peak, std::memory_order_relaxed);
    r->offset.store(offset, std::memory_order_relaxed);
    r->silent.fetch_add(silent, std::memory_order_relaxed);
    r->glitches.fetch_add(glitches, std::memory_order_relaxed);
    r->offsetChanges.fetch_add(offsetChanges, std::memory_order_relaxed);
    r->frames.fetch_add(frames, std::memory_order_relaxed);
    r->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

bool StartReader(Reader& r, const std::string& uid)
{
    r.device = DeviceForUID(uid);
    if (r.device == kAudioObjectUnknown) {
        printf("device %s not found\n", uid.c_str());
        return false;
    }
    OSStatus err = AudioDeviceCreateIOProcID(r.device, ReaderProc, &r, &r.proc);
    if (err == noErr) {
        err = AudioDeviceStart(r.device, r.proc);
    }
    if (err != noErr) {
        printf("could not start reading %s: %s\n", uid.c_str(), FourCC(err).c_str());
        return false;
    }
    return true;
}

void StopReader(Reader& r)
{
    if (r.proc) {
        AudioDeviceStop(r.device, r.proc);
        AudioDeviceDestroyIOProcID(r.device, r.proc);
        r.proc = nullptr;
    }
}

void PrintReader(const char* label, const Reader& r)
{
    printf("%s: frames=%llu silent=%llu glitches=%llu offset=%lld offset_changes=%llu "
           "peak=%.3f cycles=%llu\n",
        label, r.frames.load(), r.silent.load(), r.glitches.load(), r.offset.load(),
        r.offsetChanges.load(), r.peak.load(), r.cycles.load());
}

// Commands

int CmdDevices()
{
    for (auto dev : GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyDevices)) {
        PrintDevice(dev);
    }
    AudioObjectID bus = DeviceForUID(kBusUID);
    printf("bus by UID: %s\n", bus == kAudioObjectUnknown ? "not found" : "");
    if (bus != kAudioObjectUnknown) {
        PrintDevice(bus);
    }
    printf("driver plug-in object: %u\n", DriverPlugin());
    return 0;
}

int CmdMixes()
{
    NSArray* mixes = GetMixes();
    if (!mixes) {
        printf("driver not found or property unreadable\n");
        return 1;
    }
    NSData* json = [NSJSONSerialization dataWithJSONObject:mixes
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    printf("%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}

int CmdMixesSet(const char* json)
{
    NSData* data = [NSData dataWithBytes:json length:strlen(json)];
    NSArray* list = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![list isKindOfClass:[NSArray class]]) {
        printf("expected a JSON array\n");
        return 1;
    }
    double start = Now();
    bool ok = SetMixes(list);
    printf("set %s in %.1f ms\n", ok ? "ok" : "failed", (Now() - start) * 1000);
    return ok ? 0 : 1;
}

int CmdPlay(double seconds)
{
    Writer w;
    if (!StartWriter(w)) {
        return 1;
    }
    printf("writing %u channels to the bus for %.0f s\n", 32u, seconds);
    fflush(stdout);
    Sleep(seconds);
    StopWriter(w);
    printf("writer cycles=%llu channels=%u\n", w.cycles.load(), w.channels.load());
    return 0;
}

int CmdRecord(const std::string& uid, double seconds, const std::string& wav)
{
    if (!RequestMicrophone()) {
        return 1;
    }
    Reader r;
    if (!wav.empty()) {
        r.capture.assign(size_t((seconds + 1) * 48000) * 2, 0.0f);
    }
    if (!StartReader(r, uid)) {
        return 1;
    }
    double start = Now();
    Sleep(seconds);
    StopReader(r);
    PrintReader("record", r);
    if (!wav.empty()) {
        WriteFloatWav(wav, r.capture.data(), r.captured.load(), 2, 48000);
        printf("wrote %zu frames to %s\n", r.captured.load(), wav.c_str());
    }
    if (r.soundFrames > 0) {
        printf("left channel: %.0f Hz by zero crossings over %.2f s of sound\n",
            r.crossings.load() / 2.0 / (r.soundFrames.load() / 48000.0),
            r.soundFrames.load() / 48000.0);
    }
    if (r.firstSoundAt > 0) {
        printf("sound from %.2f s to %.2f s after start\n", r.firstSoundAt - start,
            r.lastSoundAt - start);
    }
    return 0;
}

// Writer and reader in one process: the basic loopback check.
int CmdLoop(const std::string& uid, double seconds)
{
    if (!RequestMicrophone()) {
        return 1;
    }
    Writer w;
    Reader r;
    if (!StartWriter(w) || !StartReader(r, uid)) {
        return 1;
    }
    for (int i = 0; i < int(seconds); i++) {
        Sleep(1);
        PrintReader("loop", r);
        fflush(stdout);
    }
    StopReader(r);
    StopWriter(w);
    return 0;
}

// Create, rename and delete mixes in a loop while one mix is being recorded.
int CmdStress(int iterations, double pause)
{
    if (!RequestMicrophone()) {
        return 1;
    }
    NSString* anchorID = @"anchor";
    if (!SetMixes(@[ Mix(anchorID, @"Anchor", 0) ]) ||
        WaitForDevice(MixUID(anchorID), true) < 0) {
        printf("anchor mix did not appear\n");
        return 1;
    }
    AudioObjectID anchorDevice = DeviceForUID(MixUID(anchorID));
    Writer w;
    Reader r;
    if (!StartWriter(w) || !StartReader(r, MixUID(anchorID))) {
        return 1;
    }
    Sleep(0.5);
    uint64_t silentBefore = r.silent.load();
    double maxSet = 0, maxAppear = 0, maxVanish = 0, sumAppear = 0;
    int missingAppear = 0, missingVanish = 0, nameMismatch = 0;
    for (int i = 0; i < iterations; i++) {
        NSMutableArray* list = [NSMutableArray array];
        NSString* anchorName = [NSString stringWithFormat:@"Anchor %d", i];
        [list addObject:Mix(anchorID, anchorName, 0)];
        NSString* extraID = [NSString stringWithFormat:@"s%d", i];
        int slot = 1 + (i % 15);
        [list addObject:Mix(extraID, [NSString stringWithFormat:@"Stress %d", i], slot)];

        double t = Now();
        bool ok = SetMixes(list);
        double took = Now() - t;
        if (!ok || took > 0.1) {
            printf("iteration %d add: %s after %.1f ms\n", i, ok ? "slow" : "FAILED",
                took * 1000);
        }
        maxSet = std::max(maxSet, took);
        double appear = WaitForDevice(MixUID(extraID), true);
        Sleep(pause);
        if (appear < 0 || appear > 0.1) {
            printf("iteration %d: device appeared %s\n", i,
                appear < 0 ? "never (3 s)" : [NSString stringWithFormat:@"after %.0f ms",
                                                     appear * 1000].UTF8String);
        }
        if (appear < 0) {
            missingAppear++;
        } else {
            maxAppear = std::max(maxAppear, appear);
            sumAppear += appear;
        }
        if (GetString(anchorDevice, kAudioObjectPropertyName) != anchorName.UTF8String) {
            Sleep(0.05);
            if (GetString(anchorDevice, kAudioObjectPropertyName) != anchorName.UTF8String) {
                nameMismatch++;
            }
        }

        t = Now();
        ok = SetMixes(@[ Mix(anchorID, anchorName, 0) ]);
        took = Now() - t;
        if (!ok || took > 0.1) {
            printf("iteration %d remove: %s after %.1f ms\n", i, ok ? "slow" : "FAILED",
                took * 1000);
        }
        maxSet = std::max(maxSet, took);
        double vanish = WaitForDevice(MixUID(extraID), false);
        Sleep(pause);
        if (vanish < 0) {
            missingVanish++;
        } else {
            maxVanish = std::max(maxVanish, vanish);
        }
        if (i % 25 == 24) {
            printf("iteration %d\n", i + 1);
            PrintReader("  anchor", r);
            fflush(stdout);
        }
    }
    uint64_t silentDuring = r.silent.load() - silentBefore;
    StopReader(r);
    StopWriter(w);
    printf("iterations=%d max_set_ms=%.1f appear_avg_ms=%.1f appear_max_ms=%.1f "
           "vanish_max_ms=%.1f missing_appear=%d missing_vanish=%d name_mismatch=%d\n",
        iterations, maxSet * 1000, sumAppear / std::max(1, iterations) * 1000,
        maxAppear * 1000, maxVanish * 1000, missingAppear, missingVanish, nameMismatch);
    printf("anchor device id unchanged: %s\n",
        DeviceForUID(MixUID(anchorID)) == anchorDevice ? "yes" : "no");
    printf("anchor silent frames during stress: %llu\n", silentDuring);
    PrintReader("anchor", r);
    return 0;
}

// Delete a mix while this process is recording from it.
int CmdRemoveLive()
{
    if (!RequestMicrophone()) {
        return 1;
    }
    NSArray* before = GetMixes() ?: @[];
    NSMutableArray* with = [before mutableCopy];
    [with addObject:Mix(@"victim", @"Victim", 15)];
    SetMixes(with);
    if (WaitForDevice(MixUID(@"victim"), true) < 0) {
        printf("victim did not appear\n");
        return 1;
    }
    Writer w;
    Reader r;
    if (!StartWriter(w) || !StartReader(r, MixUID(@"victim"))) {
        return 1;
    }
    Sleep(1);
    PrintReader("before removal", r);
    double t = Now();
    bool ok = SetMixes(before);
    printf("set %s after %.1f ms\n", ok ? "ok" : "FAILED", (Now() - t) * 1000);
    UInt32 alive = 1;
    uint64_t cycles = r.cycles.load(), silent = r.silent.load();
    Sleep(1);
    GetProp(r.device, kAudioDevicePropertyDeviceIsAlive, alive);
    printf("one second after delete: alive=%u reader cycles=%llu silent frames=%llu, "
           "still listed=%s\n",
        alive, r.cycles.load() - cycles, r.silent.load() - silent,
        DeviceForUID(MixUID(@"victim")) != kAudioObjectUnknown ? "yes" : "no");
    t = Now();
    StopReader(r);
    printf("stopping the reader took %.1f ms\n", (Now() - t) * 1000);
    double vanish = WaitForDevice(MixUID(@"victim"), false);
    printf("device gone %.0f ms after the reader stopped\n", vanish * 1000);
    StopWriter(w);
    printf("still responsive: devices=%zu\n",
        GetArray<AudioObjectID>(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)
            .size());
    return 0;
}

// S3: app audio capture through Core Audio process taps.

using ResponsibleFn = pid_t (*)(pid_t);

pid_t ResponsiblePID(pid_t pid)
{
    static auto fn = reinterpret_cast<ResponsibleFn>(
        dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"));
    return fn ? fn(pid) : -1;
}

pid_t ParentPID(pid_t pid)
{
    proc_bsdinfo info = {};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) <= 0) {
        return -1;
    }
    return pid_t(info.pbi_ppid);
}

std::string AppBundleID(pid_t pid)
{
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return app.bundleIdentifier ? app.bundleIdentifier.UTF8String : "";
}

std::string ProcName(pid_t pid)
{
    char name[256] = {};
    proc_name(pid, name, sizeof(name));
    return name;
}

struct AudioProcess
{
    AudioObjectID object;
    pid_t pid;
    std::string bundleID;
    std::string responsibleBundleID;
    bool output;
    bool input;
};

std::vector<AudioProcess> AudioProcesses()
{
    std::vector<AudioProcess> list;
    for (auto obj : GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyProcessObjectList)) {
        AudioProcess p{obj, -1, "", "", false, false};
        GetProp(obj, kAudioProcessPropertyPID, p.pid);
        p.bundleID = GetString(obj, kAudioProcessPropertyBundleID);
        UInt32 out = 0, in = 0;
        GetProp(obj, kAudioProcessPropertyIsRunningOutput, out);
        GetProp(obj, kAudioProcessPropertyIsRunningInput, in);
        p.output = out;
        p.input = in;
        pid_t resp = ResponsiblePID(p.pid);
        p.responsibleBundleID = resp > 0 ? AppBundleID(resp) : "";
        list.push_back(p);
    }
    return list;
}

int CmdProcs()
{
    for (const auto& p : AudioProcesses()) {
        printf("obj=%-5u pid=%-6d out=%d in=%d bundle=%-45s responsible=%-30s parent=%d "
               "name=%s\n",
            p.object, p.pid, p.output, p.input, p.bundleID.c_str(),
            p.responsibleBundleID.c_str(), ParentPID(p.pid), ProcName(p.pid).c_str());
    }
    return 0;
}

std::vector<std::string> LaunchArguments(pid_t pid)
{
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int)) {
        return {};
    }
    std::vector<char> buffer(size);
    if (sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0) {
        return {};
    }
    int argc = 0;
    std::memcpy(&argc, buffer.data(), sizeof(argc));
    size_t at = sizeof(argc);
    while (at < size && buffer[at]) {
        at++;
    }
    while (at < size && !buffer[at]) {
        at++;
    }
    std::vector<std::string> args;
    while (int(args.size()) < argc && at < size) {
        std::string arg(&buffer[at]);
        at += arg.size() + 1;
        args.push_back(std::move(arg));
    }
    return args;
}

NSArray* JSONArgs(pid_t pid)
{
    NSMutableArray* out = [NSMutableArray array];
    for (const auto& a : LaunchArguments(pid)) {
        [out addObject:@(a.c_str()) ?: @""];
    }
    return out;
}

// Every absolute path in the arguments (alone or after --flag=) that is a directory right
// now, so identity tests can run later on another machine.
NSArray* JSONDirectories(pid_t pid)
{
    NSMutableArray* out = [NSMutableArray array];
    for (auto a : LaunchArguments(pid)) {
        if (a.rfind('-', 0) == 0 && a.find('=') != std::string::npos) {
            a = a.substr(a.find('=') + 1);
        }
        BOOL isDir = NO;
        if (!a.empty() && a[0] == '/' &&
            [NSFileManager.defaultManager fileExistsAtPath:@(a.c_str()) isDirectory:&isDir] &&
            isDir) {
            [out addObject:@(a.c_str())];
        }
    }
    return out;
}

// Step 1 of the source identity work: everything macOS exposes about running app copies
// and audio processes, as JSON, so the same snapshot can be compared across machines.
int CmdInventory()
{
    NSMutableArray* apps = [NSMutableArray array];
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
            continue;
        }
        [apps addObject:@{
            @"bundleID" : app.bundleIdentifier ?: @"",
            @"name" : app.localizedName ?: @"",
            @"pid" : @(app.processIdentifier),
            @"launched" : @(app.launchDate.timeIntervalSince1970),
            @"alive" : @(kill(app.processIdentifier, 0) == 0 || errno == EPERM),
            @"bundlePath" : app.bundleURL.path ?: @"",
            @"args" : JSONArgs(app.processIdentifier),
            @"directories" : JSONDirectories(app.processIdentifier),
        }];
    }
    NSMutableArray* audio = [NSMutableArray array];
    for (const auto& p : AudioProcesses()) {
        pid_t responsible = ResponsiblePID(p.pid);
        [audio addObject:@{
            @"object" : @(p.object),
            @"pid" : @(p.pid),
            @"bundleID" : @(p.bundleID.c_str()),
            @"parent" : @(ParentPID(p.pid)),
            @"responsible" : @(responsible),
            @"responsibleBundleID" : @(p.responsibleBundleID.c_str()),
            @"playing" : @(p.output),
            @"recording" : @(p.input),
            @"name" : @(ProcName(p.pid).c_str()),
            @"args" : JSONArgs(p.pid),
        }];
    }
    NSData* json = [NSJSONSerialization
        dataWithJSONObject:@{@"apps" : apps, @"audio" : audio, @"taken" : @(NSDate.date.timeIntervalSince1970)}
                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                     error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n");
    return 0;
}

bool Matches(const AudioProcess& p, const std::string& prefix, bool useResponsible)
{
    if (p.bundleID.rfind(prefix, 0) == 0) {
        return true;
    }
    return useResponsible && p.responsibleBundleID.rfind(prefix, 0) == 0;
}

struct TapMeter
{
    std::atomic<float> peak{0};
    std::atomic<uint64_t> cycles{0};
};

OSStatus TapProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* in,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* ctx)
{
    auto m = static_cast<TapMeter*>(ctx);
    float peak = 0;
    for (UInt32 b = 0; b < in->mNumberBuffers; b++) {
        auto data = static_cast<const float*>(in->mBuffers[b].mData);
        UInt32 n = in->mBuffers[b].mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < n; i++) {
            peak = std::max(peak, std::fabs(data[i]));
        }
    }
    float old = m->peak.load(std::memory_order_relaxed);
    while (peak > old && !m->peak.compare_exchange_weak(old, peak)) {
    }
    m->cycles.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}

int CmdTap(const std::string& prefix, double seconds, bool useResponsible)
{
    auto select = [&] {
        std::vector<AudioObjectID> objects;
        for (const auto& p : AudioProcesses()) {
            if (Matches(p, prefix, useResponsible)) {
                objects.push_back(p.object);
            }
        }
        std::sort(objects.begin(), objects.end());
        return objects;
    };
    auto objects = select();
    printf("matching process objects at start: %zu (responsible lookup %s)\n", objects.size(),
        useResponsible ? "on" : "off");
    NSMutableArray* numbers = [NSMutableArray array];
    for (auto o : objects) {
        [numbers addObject:@(o)];
    }
    CATapDescription* desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:numbers];
    desc.name = @"Blend lab tap";
    desc.privateTap = YES;
    desc.muteBehavior = CATapUnmuted;
    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus err = AudioHardwareCreateProcessTap(desc, &tap);
    if (err != noErr) {
        printf("create tap failed: %s\n", FourCC(err).c_str());
        return 1;
    }
    std::string tapUID = GetString(tap, kAudioTapPropertyUID);

    AudioObjectID output = kAudioObjectUnknown;
    GetProp(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, output);
    NSString* outputUID = @(GetString(output, kAudioDevicePropertyDeviceUID).c_str());
    NSDictionary* agg = @{
        @kAudioAggregateDeviceNameKey : @"Blend lab tap",
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @NO,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : outputUID} ],
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : @(tapUID.c_str()),
            @kAudioSubTapDriftCompensationKey : @YES
        } ],
    };
    AudioObjectID aggregate = kAudioObjectUnknown;
    err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &aggregate);
    if (err != noErr) {
        printf("create aggregate failed: %s\n", FourCC(err).c_str());
        AudioHardwareDestroyProcessTap(tap);
        return 1;
    }
    TapMeter meter;
    AudioDeviceIOProcID proc = nullptr;
    AudioDeviceCreateIOProcID(aggregate, TapProc, &meter, &proc);
    double start = Now();
    err = AudioDeviceStart(aggregate, proc);
    printf("start: %s after %.1f s\n", err == noErr ? "ok" : FourCC(err).c_str(), Now() - start);
    fflush(stdout);

    for (int i = 0; i < int(seconds); i++) {
        Sleep(1);
        float peak = meter.peak.exchange(0);
        auto now = select();
        const char* change = "";
        if (now != objects) {
            objects = now;
            NSMutableArray* updated = [NSMutableArray array];
            for (auto o : objects) {
                [updated addObject:@(o)];
            }
            desc.processes = updated;
            auto a = Addr(kAudioTapPropertyDescription);
            CATapDescription* value = desc;
            OSStatus e =
                AudioObjectSetPropertyData(tap, &a, 0, nullptr, sizeof(value), &value);
            change = e == noErr ? " (process list changed, tap updated)"
                                : " (process list changed, tap update FAILED)";
        }
        printf("t=%2d peak=%6.1f dBFS objects=%zu cycles=%llu%s\n", i + 1,
            peak > 0 ? 20 * std::log10(peak) : -999.0, objects.size(), meter.cycles.load(),
            change);
        fflush(stdout);
    }
    AudioDeviceStop(aggregate, proc);
    AudioDeviceDestroyIOProcID(aggregate, proc);
    AudioHardwareDestroyAggregateDevice(aggregate);
    AudioHardwareDestroyProcessTap(tap);
    return 0;
}

// S4 fixtures: raw built-in mic plus a tap of everything the system plays, captured by
// one private aggregate so both share a clock. Writes a 3-channel float WAV:
// channel 0 is the mic, channels 1 and 2 are the speaker reference.

struct EchoRecorder
{
    std::vector<float> samples;
    std::atomic<size_t> frames{0};
    size_t capacity = 0;
    std::atomic<uint32_t> layout{0};
};

OSStatus EchoProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* in,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* ctx)
{
    auto r = static_cast<EchoRecorder*>(ctx);
    if (in->mNumberBuffers < 1) {
        return noErr;
    }
    // Buffers arrive as [mic (1 ch), tap (2 ch)] in subdevice order.
    UInt32 frames = in->mBuffers[0].mDataByteSize /
                    (sizeof(float) * std::max<UInt32>(1, in->mBuffers[0].mNumberChannels));
    size_t at = r->frames.load(std::memory_order_relaxed);
    if (at + frames > r->capacity) {
        frames = UInt32(r->capacity - at);
    }
    uint32_t layout = 0;
    for (UInt32 f = 0; f < frames; f++) {
        float out[3] = {0, 0, 0};
        UInt32 channel = 0;
        for (UInt32 b = 0; b < in->mNumberBuffers && channel < 3; b++) {
            const AudioBuffer& buf = in->mBuffers[b];
            auto data = static_cast<const float*>(buf.mData);
            for (UInt32 c = 0; c < buf.mNumberChannels && channel < 3; c++) {
                out[channel++] = data[f * buf.mNumberChannels + c];
            }
        }
        layout = channel;
        std::memcpy(&r->samples[(at + f) * 3], out, sizeof(out));
    }
    r->layout.store(in->mNumberBuffers * 10 + layout, std::memory_order_relaxed);
    r->frames.store(at + frames, std::memory_order_relaxed);
    return noErr;
}

int CmdRecordEcho(double seconds, const std::string& path)
{
    if (!RequestMicrophone()) {
        return 1;
    }
    CATapDescription* desc = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    desc.name = @"Blend lab echo reference";
    desc.privateTap = YES;
    desc.muteBehavior = CATapUnmuted;
    AudioObjectID tap = kAudioObjectUnknown;
    if (AudioHardwareCreateProcessTap(desc, &tap) != noErr) {
        printf("create tap failed\n");
        return 1;
    }
    std::string tapUID = GetString(tap, kAudioTapPropertyUID);
    NSString* micUID = @"BuiltInMicrophoneDevice";
    NSDictionary* agg = @{
        @kAudioAggregateDeviceNameKey : @"Blend lab echo",
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey : micUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @NO,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : micUID} ],
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : @(tapUID.c_str()),
            @kAudioSubTapDriftCompensationKey : @YES
        } ],
    };
    AudioObjectID aggregate = kAudioObjectUnknown;
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &aggregate) != noErr) {
        printf("create aggregate failed\n");
        AudioHardwareDestroyProcessTap(tap);
        return 1;
    }
    Float64 rate = 0;
    GetProp(aggregate, kAudioDevicePropertyNominalSampleRate, rate);
    EchoRecorder rec;
    rec.capacity = size_t(seconds * 48000) + 48000;
    rec.samples.assign(rec.capacity * 3, 0.0f);
    AudioDeviceIOProcID proc = nullptr;
    AudioDeviceCreateIOProcID(aggregate, EchoProc, &rec, &proc);
    AudioDeviceStart(aggregate, proc);
    printf("recording mic + speaker reference at %.0f Hz for %.0f s\n", rate, seconds);
    fflush(stdout);
    Sleep(seconds);
    AudioDeviceStop(aggregate, proc);
    AudioDeviceDestroyIOProcID(aggregate, proc);
    AudioHardwareDestroyAggregateDevice(aggregate);
    AudioHardwareDestroyProcessTap(tap);

    // Plain float WAV: AVAudioFormat refuses more than two channels without a layout.
    size_t frames = rec.frames.load();
    FILE* out = fopen(path.c_str(), "wb");
    const uint32_t bytes = uint32_t(frames * 3 * sizeof(float));
    const uint32_t header[] = {0x46464952, 36 + bytes, 0x45564157, 0x20746d66, 16};
    const uint16_t fmt[] = {3, 3};
    const uint32_t rates[] = {uint32_t(rate), uint32_t(rate) * 12};
    const uint16_t align[] = {12, 32};
    const uint32_t data[] = {0x61746164, bytes};
    fwrite(header, sizeof(header), 1, out);
    fwrite(fmt, sizeof(fmt), 1, out);
    fwrite(rates, sizeof(rates), 1, out);
    fwrite(align, sizeof(align), 1, out);
    fwrite(data, sizeof(data), 1, out);
    fwrite(rec.samples.data(), sizeof(float), frames * 3, out);
    fclose(out);
    NSError* error = nil;
    float micPeak = 0, refPeak = 0;
    for (size_t f = 0; f < frames; f++) {
        micPeak = std::max(micPeak, std::fabs(rec.samples[f * 3]));
        refPeak = std::max(refPeak, std::fabs(rec.samples[f * 3 + 1]));
    }
    uint32_t layout = rec.layout.load();
    printf("wrote %zu frames to %s (%s); buffers=%u channels=%u mic_peak=%.1f dBFS "
           "ref_peak=%.1f dBFS\n",
        frames, path.c_str(), error ? error.localizedDescription.UTF8String : "ok",
        layout / 10, layout % 10, 20 * std::log10(micPeak + 1e-9),
        20 * std::log10(refPeak + 1e-9));
    return 0;
}

// Runs the real engine with a configuration file, printing status every second.
int CmdEngine(const std::string& path, double seconds, const std::string& recentWav)
{
    if (!RequestMicrophone()) {
        return 1;
    }
    NSString* json = [NSString stringWithContentsOfFile:@(path.c_str())
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!json) {
        printf("cannot read %s\n", path.c_str());
        return 1;
    }
    BlendEngine* engine = BlendEngineCreate();
    char error[512] = {};
    if (!BlendEngineApply(engine, json.UTF8String, error, sizeof(error))) {
        printf("apply failed: %s\n", error);
        return 1;
    }
    // With a WAV path, check the first mix the way the app does on speakers and save what
    // the check recorded; with LAB_LISTEN set, check it live to the default output.
    if (!recentWav.empty() || getenv("LAB_LISTEN")) {
        Sleep(0.5); // the status snapshot fills once the configuration is applied
        BlendMixStatus first;
        if (BlendEngineStatus(engine, &first, 1) == 1) {
            BlendEngineStartCheck(engine, first.id, getenv("LAB_LISTEN") != nullptr);
        }
    }
    for (int i = 0; i < int(seconds); i++) {
        Sleep(1);
        BlendMixStatus statuses[16];
        size_t n = BlendEngineStatus(engine, statuses, 16);
        for (size_t m = 0; m < n; m++) {
            printf("t=%d mix %s ready=%d running=%d peak=%.1f dBFS\n", i + 1, statuses[m].id,
                statuses[m].deviceReady, statuses[m].running,
                statuses[m].peak > 0 ? 20 * std::log10(statuses[m].peak) : -999.0);
        }
        if (i % 5 == 4 || i + 1 == int(seconds)) {
            char* text = BlendEngineDiagnostics(engine);
            printf("%s", text);
            free(text);
        }
        fflush(stdout);
    }
    if (!recentWav.empty()) {
        BlendMixStatus first;
        if (BlendEngineStatus(engine, &first, 1) == 1) {
            std::vector<float> recent(5 * 48000 * 2);
            size_t frames = BlendEngineCopyCheck(engine, first.id, recent.data(), 5 * 48000);
            WriteFloatWav(recentWav, recent.data(), frames, 2, 48000);
            printf("saved %zu frames of mix %s to %s\n", frames, first.id, recentWav.c_str());
        }
    }
    BlendEngineDestroy(engine);
    return 0;
}

void Usage()
{
    printf("usage: lab devices | mixes | mixes-set JSON | play SECONDS | record UID SECONDS [OUT.wav] |\n"
           "           loop UID SECONDS | stress ITERATIONS [PAUSE_MS] | remove-live | procs |\n"
           "           tap BUNDLE_PREFIX SECONDS [--no-responsible] | record-echo SECONDS OUT.wav |\n"
           "           access\n");
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IOLBF, 0);
        if (argc < 2) {
            Usage();
            return 2;
        }
        std::string cmd = argv[1];
        // A wedged audio server blocks HAL calls forever; give up loudly instead.
        const double watchdog = getenv("LAB_TIMEOUT") ? atof(getenv("LAB_TIMEOUT")) : 180;
        std::thread([watchdog] {
            Sleep(watchdog);
            printf("WATCHDOG: no exit after %.0f s, the audio server is probably hung\n",
                watchdog);
            fflush(stdout);
            _exit(3);
        }).detach();
        auto arg = [&](int i, const char* fallback = "") {
            return i < argc ? std::string(argv[i]) : std::string(fallback);
        };
        if (cmd == "devices") {
            return CmdDevices();
        }
        if (cmd == "mixes") {
            return CmdMixes();
        }
        if (cmd == "mixes-set" && argc > 2) {
            return CmdMixesSet(argv[2]);
        }
        if (cmd == "play") {
            return CmdPlay(std::stod(arg(2, "10")));
        }
        if (cmd == "record" && argc > 2) {
            return CmdRecord(arg(2), std::stod(arg(3, "5")), arg(4));
        }
        if (cmd == "loop" && argc > 2) {
            return CmdLoop(arg(2), std::stod(arg(3, "5")));
        }
        if (cmd == "stress") {
            return CmdStress(std::stoi(arg(2, "200")), std::stod(arg(3, "0")) / 1000);
        }
        if (cmd == "remove-live") {
            return CmdRemoveLive();
        }
        if (cmd == "inventory") {
            return CmdInventory();
        }
        if (cmd == "procs") {
            return CmdProcs();
        }
        if (cmd == "tap" && argc > 2) {
            return CmdTap(arg(2), std::stod(arg(3, "10")), arg(4) != "--no-responsible");
        }
        if (cmd == "record-echo" && argc > 3) {
            return CmdRecordEcho(std::stod(arg(2)), arg(3));
        }
        if (cmd == "engine" && argc > 2) {
            return CmdEngine(arg(2), std::stod(arg(3, "10")), arg(4));
        }
        if (cmd == "access") {
            return RequestMicrophone() ? 0 : 1;
        }
        Usage();
        return 2;
    }
}
