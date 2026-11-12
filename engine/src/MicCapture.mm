#include "MicCapture.hpp"

#include "HAL.hpp"
#include "Routing.hpp"

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

MicCapture::MicCapture(Options options)
    : options_(std::move(options))
{
}

MicCapture::~MicCapture()
{
    Stop();
}

OSStatus MicCapture::IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context)
{
    auto self = static_cast<MicCapture*>(context);
    if (!self->processor_) {
        self->sink_->Raw(input, {});
        return noErr;
    }
    if (!input || input->mNumberBuffers == 0) {
        return noErr;
    }
    // The microphone's channels come first, then the tap's two, in subdevice order.
    const bool reference = self->aggregate_ != kAudioObjectUnknown;
    const routing::Microphone route = reference && self->tapChannels_
        ? routing::MicTap(input, self->micChannels_, self->tapChannels_)
        : routing::Mic(input, self->micChannels_, reference);
    if (!route.mic) {
        return noErr;
    }
    if (route.mismatch) {
        self->mismatches_.fetch_add(1, std::memory_order_relaxed);
    }
    self->processor_->Process(route.mic.data, route.mic.stride, route.left.data,
        route.left.stride, route.right.data, route.right.stride, routing::Frames(input));
    return noErr;
}

void MicCapture::Emit(void* context, const float* me, const float* farEnd, uint32_t frames)
{
    static_cast<MicCapture*>(context)->sink_->Block(me, farEnd, frames);
}

// Everything the Mac plays except this process: its output carries the mixes, which
// contain this microphone, and cancelling them would cancel the voice.
bool MicCapture::AddReference()
{
    CATapDescription* description = nil;
    if (options_.reference == Reference::Processes) {
        processes_ = ProcessTap::Matching(options_.target, {});
        description = [[CATapDescription alloc] initStereoMixdownOfProcesses:Numbers(processes_)];
        description.name = [NSString
            stringWithFormat:@"%s: %s", options_.tapPrefix.c_str(), options_.target.bundleID.c_str()];
    } else {
        AudioObjectID blend = kAudioObjectUnknown;
        pid_t pid = getpid();
        auto address = hal::Address(kAudioHardwarePropertyTranslatePIDToProcessObject);
        UInt32 size = sizeof(blend);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(pid), &pid, &size,
            &blend);
        NSArray* exclude = blend != kAudioObjectUnknown ? @[ @(blend) ] : @[];
        description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
        description.name = @"Blend: echo reference";
    }
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    if (AudioHardwareCreateProcessTap(description, &tap_) != noErr) {
        tap_ = kAudioObjectUnknown;
        return false;
    }
    NSString* micUID = @(options_.uid.c_str());
    NSString* tapUID = @(hal::GetString(tap_, kAudioTapPropertyUID).c_str());
    NSDictionary* aggregate = @{
        @kAudioAggregateDeviceNameKey : description.name,
        @kAudioAggregateDeviceUIDKey : [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey : micUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @NO,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : micUID} ],
        @kAudioAggregateDeviceTapListKey :
            @[ @{@kAudioSubTapUIDKey : tapUID, @kAudioSubTapDriftCompensationKey : @YES} ],
    };
    if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &aggregate_) !=
        noErr) {
        aggregate_ = kAudioObjectUnknown;
        AudioHardwareDestroyProcessTap(tap_);
        tap_ = kAudioObjectUnknown;
        return false;
    }
    ioDevice_ = aggregate_;
    AudioStreamBasicDescription format = {};
    tapChannels_ = hal::Get(tap_, kAudioTapPropertyFormat, format) ? format.mChannelsPerFrame : 0;
    description_ = (__bridge_retained void*)description;
    return true;
}

void MicCapture::RefreshProcesses()
{
    if (!description_ || options_.reference != Reference::Processes) {
        return;
    }
    auto now = ProcessTap::Matching(options_.target, {});
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

bool MicCapture::Start(FrameSink& sink)
{
    if (proc_) {
        return true;
    }
    device_ = hal::DeviceForUID(options_.uid);
    micChannels_ = device_ == kAudioObjectUnknown
        ? 0 : hal::ChannelCount(device_, kAudioObjectPropertyScopeInput);
    if (micChannels_ == 0) {
        return false;
    }
    sink_ = &sink;
    rate_ = hal::NominalRate(device_);
    ioDevice_ = device_;
    // Without the reference, echo cancellation is skipped and isolation still runs.
    const bool reference = options_.reference != Reference::None && AddReference();
    if (options_.reference == Reference::Processes && !reference) {
        Stop();
        return false;
    }
    mismatches_.store(0, std::memory_order_relaxed);
    ioRate_ = hal::NominalRate(ioDevice_);
    processor_ = MicProcessor::Create(hal::NominalRate(ioDevice_),
        reference && options_.echoCancel, options_.isolation, Emit, this,
        options_.passThrough || reference);
    // The buffer size is left alone: on a physical device it applies to every app. A
    // processed microphone delivers in 10 ms blocks, which the sink has to absorb.
    uint32_t frames = std::min<uint32_t>(hal::BufferFrames(ioDevice_), 4096);
    if (processor_) {
        frames += processor_->BlockFrames();
    }
    sink.Prepare(hal::NominalRate(ioDevice_), frames);
    if (AudioDeviceCreateIOProcID(ioDevice_, IOProc, this, &proc_) != noErr ||
        AudioDeviceStart(ioDevice_, proc_) != noErr) {
        Stop();
        return false;
    }
    return true;
}

bool MicCapture::NeedsRestart() const
{
    if (!proc_) {
        return false;
    }
    if (hal::DeviceForUID(options_.uid) != device_ || hal::NominalRate(device_) != rate_) {
        return true;
    }
    // The aggregate labels what the host receives, so its own rate has to hold still.
    return options_.reference == Reference::Processes &&
           hal::NominalRate(ioDevice_) != ioRate_;
}

bool MicCapture::EchoCancelFailed() const
{
    return processor_ && options_.echoCancel && aggregate_ != kAudioObjectUnknown &&
           !processor_->EchoCancelling();
}

void MicCapture::Stop()
{
    if (proc_) {
        AudioDeviceStop(ioDevice_, proc_);
        AudioDeviceDestroyIOProcID(ioDevice_, proc_);
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
    tapChannels_ = 0;
    processor_.reset();
    ioDevice_ = kAudioObjectUnknown;
}

std::string MicCapture::Describe() const
{
    return processor_ ? processor_->Describe() : std::string();
}

} // namespace blend
