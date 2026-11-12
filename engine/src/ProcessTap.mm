#include "ProcessTap.hpp"

#include "Apps.hpp"
#include "HAL.hpp"

#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

#include <algorithm>

#include <unistd.h>

namespace blend {

namespace {

NSArray<NSNumber*>* Numbers(const std::vector<AudioObjectID>& objects)
{
    NSMutableArray* numbers = [NSMutableArray arrayWithCapacity:objects.size()];
    for (AudioObjectID object : objects) {
        [numbers addObject:@(object)];
    }
    return numbers;
}

} // namespace

ProcessTap::ProcessTap(TapTarget target, std::string namePrefix)
    : target_(std::move(target))
    , namePrefix_(std::move(namePrefix))
{
}

ProcessTap::~ProcessTap()
{
    Stop();
}

OSStatus ProcessTap::IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context)
{
    auto self = static_cast<ProcessTap*>(context);
    if (!input || input->mNumberBuffers == 0) {
        return noErr;
    }
    const routing::TapSpan tap =
        routing::Tap(routing::TotalChannels(input), self->deviceChannels_, self->tapChannels_);
    if (tap.mismatch) {
        self->mismatches_.fetch_add(1, std::memory_order_relaxed);
    }
    self->sink_->Raw(input, tap.span);
    return noErr;
}

// Every audio process whose owning app copy is this tap's app, and, with an instance, the
// copy launched with that identity. For system audio: this process, whose output carries
// the mixes, and every process of the excluded app copies.
std::vector<AudioObjectID> ProcessTap::Matching(const TapTarget& target,
    const std::vector<int>& excludedOwners)
{
    std::vector<AudioObjectID> matches;
    for (AudioObjectID object : hal::GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyProcessObjectList)) {
        pid_t pid = -1;
        hal::Get(object, kAudioProcessPropertyPID, pid);
        if (target.system) {
            const int owner = pid > 0 ? OwnerPID(pid) : 0;
            if (pid == getpid() ||
                (owner && std::find(excludedOwners.begin(), excludedOwners.end(), owner) !=
                        excludedOwners.end())) {
                matches.push_back(object);
            }
            continue;
        }
        const int owner = pid > 0 ? OwnerPID(pid) : 0;
        if (!owner || AppBundleID(owner) != target.bundleID) {
            continue;
        }
        if (target.instance && CopyIdentity(owner) != *target.instance) {
            continue;
        }
        matches.push_back(object);
    }
    std::sort(matches.begin(), matches.end());
    return matches;
}

bool ProcessTap::Start(FrameSink& sink)
{
    if (proc_) {
        return true;
    }
    sink_ = &sink;
    processes_ = MatchingProcesses();
    CATapDescription* description = target_.system
        ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:Numbers(processes_)]
        : [[CATapDescription alloc] initStereoMixdownOfProcesses:Numbers(processes_)];
    description.name = target_.system
        ? [NSString stringWithFormat:@"%s: system audio", namePrefix_.c_str()]
        : [NSString stringWithFormat:@"%s: %s", namePrefix_.c_str(), target_.bundleID.c_str()];
    description.privateTap = YES;
    description.muteBehavior = muted_ ? CATapMuted : CATapUnmuted;
    if (AudioHardwareCreateProcessTap(description, &tap_) != noErr) {
        tap_ = kAudioObjectUnknown;
        return false;
    }
    description_ = (__bridge_retained void*)description;

    // The tap needs a clock; the default output device is where the app's audio goes.
    AudioObjectID output = kAudioObjectUnknown;
    hal::Get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, output);
    NSString* outputUID = @(hal::GetString(output, kAudioDevicePropertyDeviceUID).c_str());
    NSString* tapUID = @(hal::GetString(tap_, kAudioTapPropertyUID).c_str());
    NSDictionary* aggregate = @{
        @kAudioAggregateDeviceNameKey : description.name,
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        // Auto-start made other apps' mic starts hang in Chromium's testing.
        @kAudioAggregateDeviceTapAutoStartKey : @NO,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : outputUID} ],
        @kAudioAggregateDeviceTapListKey :
            @[ @{@kAudioSubTapUIDKey : tapUID, @kAudioSubTapDriftCompensationKey : @YES} ],
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &aggregate_) !=
        noErr) {
        aggregate_ = kAudioObjectUnknown;
        Stop();
        return false;
    }
    // The aggregate lists the clock device's own input channels before the tap's.
    deviceChannels_ = hal::ChannelCount(output, kAudioObjectPropertyScopeInput);
    AudioStreamBasicDescription format = {};
    tapChannels_ = hal::Get(tap_, kAudioTapPropertyFormat, format) ? format.mChannelsPerFrame : 0;
    mismatches_.store(0, std::memory_order_relaxed);
    sink.Prepare(hal::NominalRate(aggregate_), hal::BufferFrames(aggregate_));
    if (AudioDeviceCreateIOProcID(aggregate_, IOProc, this, &proc_) != noErr ||
        AudioDeviceStart(aggregate_, proc_) != noErr) {
        Stop();
        return false;
    }
    return true;
}

void ProcessTap::RefreshProcesses()
{
    if (!description_) {
        return;
    }
    auto now = MatchingProcesses();
    if (now == processes_) {
        return;
    }
    processes_ = now;
    CATapDescription* description = (__bridge CATapDescription*)description_;
    description.processes = Numbers(processes_);
    auto address = hal::Address(kAudioTapPropertyDescription);
    CATapDescription* value = description;
    AudioObjectSetPropertyData(tap_, &address, 0, nullptr, sizeof(value), &value);
}

void ProcessTap::SetMuted(bool muted)
{
    muted_ = muted;
    if (!description_) {
        return;
    }
    CATapDescription* description = (__bridge CATapDescription*)description_;
    description.muteBehavior = muted ? CATapMuted : CATapUnmuted;
    auto address = hal::Address(kAudioTapPropertyDescription);
    CATapDescription* value = description;
    AudioObjectSetPropertyData(tap_, &address, 0, nullptr, sizeof(value), &value);
}

void ProcessTap::Stop()
{
    if (proc_) {
        AudioDeviceStop(aggregate_, proc_);
        AudioDeviceDestroyIOProcID(aggregate_, proc_);
        proc_ = nullptr;
    }
    if (sink_) {
        sink_->Stopped();
        sink_ = nullptr;
    }
    if (aggregate_ != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregate_);
        aggregate_ = kAudioObjectUnknown;
    }
    if (tap_ != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tap_);
        tap_ = kAudioObjectUnknown;
    }
    if (description_) {
        CFBridgingRelease(description_);
        description_ = nullptr;
    }
    processes_.clear();
}

} // namespace blend
