// Blend Lab Speaker: a stand-in for a call app. It keeps its output running for the whole
// run, as a call app does, and plays speech then exact zeros in turn, so a capture of it
// sees the pauses of a conversation.
//
// Its level is fixed at -100 dB, below what a Mac's speakers can make audible, because the
// test Mac's only output may be its speakers; `lab callwatch` also mutes it with a tap.
//
// Usage: BlendLabSpeaker SPEECH_FILE OUT_PREFIX SPEECH_S PAUSE_S TOTAL_S GO_FILE
// Plays zeros until GO_FILE exists, then the schedule, then writes OUT_PREFIX.source.f32
// (the peak of each 10 ms block it played) and OUT_PREFIX.speaker.json, and quits.

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#include <mach/mach_time.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr double kRate = 48000;
constexpr uint32_t kBlock = 480;
// -100 dBFS. A constant, not an argument, so no run can make it louder.
constexpr float kGain = 1e-5f;

struct Player
{
    std::vector<float> speech;
    uint64_t speechFrames = 0;
    uint64_t pauseFrames = 0;
    uint64_t totalFrames = 0;
    std::atomic<bool> go{false};
    std::atomic<bool> done{false};
    uint64_t played = 0;
    uint64_t goHostTime = 0;
    std::vector<float> peaks;
    float blockPeak = 0;
};

OSStatus Render(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp* time, UInt32,
    UInt32 frames, AudioBufferList* data)
{
    auto& p = *static_cast<Player*>(context);
    float* out = static_cast<float*>(data->mBuffers[0].mData);
    for (UInt32 i = 0; i < frames; i++) {
        float sample = 0;
        if (p.go.load(std::memory_order_relaxed) && p.played < p.totalFrames) {
            if (p.played == 0) {
                p.goHostTime = time->mHostTime;
            }
            const uint64_t cycle = p.speechFrames + p.pauseFrames;
            const uint64_t within = p.played % cycle;
            if (within < p.speechFrames) {
                const uint64_t at = (p.played / cycle) * p.speechFrames + within;
                sample = p.speech[at % p.speech.size()] * kGain;
            }
            p.blockPeak = std::max(p.blockPeak, std::fabs(sample));
            p.played++;
            if (p.played % kBlock == 0) {
                if (p.peaks.size() < p.peaks.capacity()) {
                    p.peaks.push_back(p.blockPeak);
                }
                p.blockPeak = 0;
            }
            if (p.played == p.totalFrames) {
                p.done.store(true);
            }
        }
        out[i] = sample;
    }
    for (UInt32 b = 1; b < data->mNumberBuffers; b++) {
        memcpy(data->mBuffers[b].mData, out, frames * sizeof(float));
    }
    return noErr;
}

bool Load(const char* path, std::vector<float>& out)
{
    ExtAudioFileRef file = nullptr;
    NSURL* url = [NSURL fileURLWithPath:@(path)];
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &file) != noErr) {
        return false;
    }
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = 4;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(format), &format);
    std::vector<float> chunk(8192);
    for (;;) {
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0] = {1, UInt32(chunk.size() * 4), chunk.data()};
        UInt32 frames = UInt32(chunk.size());
        if (ExtAudioFileRead(file, &frames, &list) != noErr || frames == 0) {
            break;
        }
        out.insert(out.end(), chunk.begin(), chunk.begin() + frames);
    }
    ExtAudioFileDispose(file);
    return !out.empty();
}

double HostSeconds(uint64_t host)
{
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return double(host) * base.numer / base.denom / 1e9;
}

} // namespace

int main(int argc, const char* argv[])
{
    @autoreleasepool {
        if (argc < 7) {
            fprintf(stderr, "usage: BlendLabSpeaker SPEECH OUT_PREFIX SPEECH_S PAUSE_S TOTAL_S GO_FILE\n");
            return 2;
        }
        // A regular app, so captures attribute its audio process to it as they do a call app.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        static Player player;
        if (!Load(argv[1], player.speech)) {
            fprintf(stderr, "could not read %s\n", argv[1]);
            return 1;
        }
        const std::string prefix = argv[2];
        player.speechFrames = uint64_t(atof(argv[3]) * kRate);
        player.pauseFrames = uint64_t(atof(argv[4]) * kRate);
        player.totalFrames = uint64_t(atof(argv[5]) * kRate);
        player.peaks.reserve(player.totalFrames / kBlock + 16);
        const std::string goFile = argv[6];

        AudioComponentDescription description = {kAudioUnitType_Output,
            kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent component = AudioComponentFindNext(nullptr, &description);
        AudioUnit unit = nullptr;
        AudioComponentInstanceNew(component, &unit);
        AudioStreamBasicDescription format = {};
        format.mSampleRate = kRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 32;
        format.mBytesPerFrame = 4;
        format.mFramesPerPacket = 1;
        format.mBytesPerPacket = 4;
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, sizeof(format));
        AURenderCallbackStruct callback = {Render, &player};
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, sizeof(callback));
        if (AudioUnitInitialize(unit) != noErr || AudioOutputUnitStart(unit) != noErr) {
            fprintf(stderr, "could not start output\n");
            return 1;
        }

        std::thread([goFile] {
            while (![NSFileManager.defaultManager fileExistsAtPath:@(goFile.c_str())]) {
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
            player.go.store(true);
        }).detach();

        auto finish = [unit, prefix] {
            AudioOutputUnitStop(unit);
            FILE* f = fopen((prefix + ".source.f32").c_str(), "wb");
            fwrite(player.peaks.data(), sizeof(float), player.peaks.size(), f);
            fclose(f);
            FILE* j = fopen((prefix + ".speaker.json").c_str(), "w");
            fprintf(j,
                "{\"go_host\": %.6f, \"rate\": %.0f, \"block\": %u, \"speech_s\": %.3f, "
                "\"pause_s\": %.3f, \"played_frames\": %llu}\n",
                HostSeconds(player.goHostTime), kRate, kBlock, player.speechFrames / kRate,
                player.pauseFrames / kRate, (unsigned long long)player.played);
            fclose(j);
            exit(0);
        };
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term =
            dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ finish(); });
        dispatch_resume(term);
        dispatch_source_t poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
            dispatch_get_main_queue());
        dispatch_source_set_timer(poll, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(poll, ^{
            if (player.done.load()) {
                finish();
            }
        });
        dispatch_resume(poll);
        [NSApp run];
    }
    return 0;
}
