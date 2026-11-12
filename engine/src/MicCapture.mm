#include "MicCapture.hpp"

#include "HAL.hpp"
#include "Routing.hpp"

#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>

#include <algorithm>

#include <unistd.h>

namespace blend {

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
    const routing::Microphone route = routing::Mic(input, self->micChannels_,
        self->aggregate_ != kAudioObjectUnknown);
    if (!route.mic) {
        return noErr;
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
    AudioObjectID blend = kAudioObjectUnknown;
    pid_t pid = getpid();
    auto address = hal::Address(kAudioHardwarePropertyTranslatePIDToProcessObject);
    UInt32 size = sizeof(blend);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(pid), &pid, &size, &blend);
    NSArray* exclude = blend != kAudioObjectUnknown ? @[ @(blend) ] : @[];
    CATapDescription* description =
        [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:exclude];
    description.name = @"Blend: echo reference";
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
    return true;
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
    const bool reference = options_.reference == Reference::EverythingButSelf && AddReference();
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
    return proc_ &&
           (hal::DeviceForUID(options_.uid) != device_ || hal::NominalRate(device_) != rate_);
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
    processor_.reset();
    ioDevice_ = kAudioObjectUnknown;
}

std::string MicCapture::Describe() const
{
    return processor_ ? processor_->Describe() : std::string();
}

} // namespace blend
