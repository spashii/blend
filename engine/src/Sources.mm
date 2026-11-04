#include "Sources.hpp"

#include "Apps.hpp"
#include "HAL.hpp"

#import <AppKit/AppKit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>


#include <algorithm>
#include <cmath>

#include <unistd.h>

namespace blend {

namespace {

constexpr uint32_t kMaxProduceFrames = 8192;
constexpr size_t kRingFrames = 16384;

// Ring fill to hold: one source buffer, one bus buffer, and 3 ms of scheduling jitter.
size_t TargetFrames(double sourceRate, double busRate, uint32_t sourceFrames, uint32_t busFrames)
{
    return sourceFrames + size_t(std::ceil(busFrames * sourceRate / busRate)) +
           size_t(std::max(128.0, 0.003 * sourceRate));
}

} // namespace

Source::Stream::Stream(double sourceRate, double busRate, uint32_t sourceFrames,
    uint32_t busFrames)
    : rate(sourceRate)
    , ring(kRingFrames, 2)
    , reader(ring, sourceRate, busRate, TargetFrames(sourceRate, busRate, sourceFrames, busFrames))
{
}

Source::Source(std::string key, Retire retire)
    : key_(std::move(key))
    , retire_(std::move(retire))
    , stereo_(size_t(kMaxProduceFrames) * 2, 0.0f)
{
}

Source::~Source()
{
    delete stream_.exchange(nullptr);
}

void Source::Publish(double sourceRate, double busRate, uint32_t sourceFrames, uint32_t busFrames)
{
    auto stream = new Stream(sourceRate, busRate, std::max<uint32_t>(sourceFrames, 64), busFrames);
    if (auto old = stream_.exchange(stream, std::memory_order_acq_rel)) {
        retire_([old] { delete old; });
    }
}

void Source::Unpublish()
{
    if (auto old = stream_.exchange(nullptr, std::memory_order_acq_rel)) {
        retire_([old] { delete old; });
    }
}

void Source::Pull(float* stereo, uint32_t frames)
{
    Stream* stream = stream_.load(std::memory_order_acquire);
    if (!stream) {
        std::memset(stereo, 0, sizeof(float) * frames * 2);
        return;
    }
    stream->reader.Pull(stereo, frames);
    float peak = peak_.load(std::memory_order_relaxed);
    for (uint32_t i = 0; i < frames * 2; i++) {
        peak = std::max(peak, std::fabs(stereo[i]));
    }
    peak_.store(peak, std::memory_order_relaxed);
}

Source::Stats Source::GetStats() const
{
    Stats stats;
    if (Stream* stream = stream_.load(std::memory_order_acquire)) {
        stats.underruns = stream->reader.Underruns();
        stats.skips = stream->reader.Skips();
        stats.overflows = stream->ring.Overflows();
        stats.correction = stream->reader.Correction();
        stats.sourceRate = stream->rate;
    }
    return stats;
}

void Source::Produce(const AudioBufferList* input)
{
    Stream* stream = stream_.load(std::memory_order_acquire);
    if (!stream || !input || input->mNumberBuffers == 0) {
        return;
    }
    const AudioBuffer& first = input->mBuffers[0];
    const UInt32 firstChannels = std::max<UInt32>(1, first.mNumberChannels);
    const UInt32 frames =
        std::min<UInt32>(first.mDataByteSize / (sizeof(float) * firstChannels), kMaxProduceFrames);

    // Left and right come from the first two channels found across all buffers; a mono
    // source is copied to both.
    const float* left = nullptr;
    const float* right = nullptr;
    UInt32 leftStride = 1, rightStride = 1;
    for (UInt32 b = 0; b < input->mNumberBuffers && !right; b++) {
        const AudioBuffer& buffer = input->mBuffers[b];
        auto data = static_cast<const float*>(buffer.mData);
        for (UInt32 c = 0; c < buffer.mNumberChannels && !right; c++) {
            if (!left) {
                left = data + c;
                leftStride = buffer.mNumberChannels;
            } else {
                right = data + c;
                rightStride = buffer.mNumberChannels;
            }
        }
    }
    if (!left) {
        return;
    }
    if (!right) {
        right = left;
        rightStride = leftStride;
    }
    float peak = producedPeak_.load(std::memory_order_relaxed);
    for (UInt32 i = 0; i < frames; i++) {
        stereo_[i * 2] = left[i * leftStride];
        stereo_[i * 2 + 1] = right[i * rightStride];
        peak = std::max(peak, std::max(std::fabs(stereo_[i * 2]), std::fabs(stereo_[i * 2 + 1])));
    }
    producedPeak_.store(peak, std::memory_order_relaxed);
    stream->ring.Write(stereo_.data(), frames);
}

// DeviceSource

DeviceSource::DeviceSource(std::string key, std::string uid, bool echoCancel,
    MicProcessor::Isolation isolation, Retire retire)
    : Source(std::move(key), std::move(retire))
    , uid_(std::move(uid))
    , echoCancel_(echoCancel)
    , isolation_(isolation)
{
}

DeviceSource::~DeviceSource()
{
    Stop();
}

OSStatus DeviceSource::IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context)
{
    auto self = static_cast<DeviceSource*>(context);
    if (!self->processor_) {
        self->Produce(input);
        return noErr;
    }
    if (!input || input->mNumberBuffers == 0) {
        return noErr;
    }
    // The microphone's channels come first, then the tap's two, in subdevice order. The
    // first microphone channel is processed; a mono reference repeats its one channel.
    const float* channels[3] = {nullptr, nullptr, nullptr};
    UInt32 strides[3] = {1, 1, 1};
    const UInt32 wanted[3] = {0, self->micChannels_, self->micChannels_ + 1};
    UInt32 index = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer& buffer = input->mBuffers[b];
        for (UInt32 c = 0; c < buffer.mNumberChannels; c++, index++) {
            for (int k = 0; k < 3; k++) {
                if (index == wanted[k]) {
                    channels[k] = static_cast<const float*>(buffer.mData) + c;
                    strides[k] = buffer.mNumberChannels;
                }
            }
        }
    }
    if (!channels[0]) {
        return noErr;
    }
    if (self->aggregate_ == kAudioObjectUnknown) {
        channels[1] = channels[2] = nullptr;
    } else if (!channels[2]) {
        channels[2] = channels[1];
        strides[2] = strides[1];
    }
    const AudioBuffer& first = input->mBuffers[0];
    const UInt32 frames =
        first.mDataByteSize / (sizeof(float) * std::max<UInt32>(1, first.mNumberChannels));
    self->processor_->Process(channels[0], strides[0], channels[1], strides[1], channels[2],
        strides[2], frames);
    return noErr;
}

void DeviceSource::Emit(void* context, const float* mono, uint32_t frames)
{
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = frames * sizeof(float);
    list.mBuffers[0].mData = const_cast<float*>(mono);
    static_cast<DeviceSource*>(context)->Produce(&list);
}

// Everything the Mac plays except Blend itself: Blend's own output carries the mixes,
// which contain this microphone, and cancelling them would cancel the voice.
bool DeviceSource::AddReference()
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
    NSString* micUID = @(uid_.c_str());
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

bool DeviceSource::Start(double busRate, uint32_t busFrames)
{
    if (proc_) {
        return true;
    }
    device_ = hal::DeviceForUID(uid_);
    micChannels_ = device_ == kAudioObjectUnknown
        ? 0 : hal::ChannelCount(device_, kAudioObjectPropertyScopeInput);
    if (micChannels_ == 0) {
        return false;
    }
    rate_ = hal::NominalRate(device_);
    ioDevice_ = device_;
    // Without the reference, echo cancellation is skipped and isolation still runs.
    const bool reference = echoCancel_ && AddReference();
    processor_ = MicProcessor::Create(hal::NominalRate(ioDevice_), reference, isolation_, Emit,
        this);
    // The buffer size is left alone: on a physical device it applies to every app. A
    // processed microphone delivers in 10 ms blocks, which the ring has to absorb.
    uint32_t frames = std::min<uint32_t>(hal::BufferFrames(ioDevice_), 4096);
    if (processor_) {
        frames += processor_->BlockFrames();
    }
    Publish(hal::NominalRate(ioDevice_), busRate, frames, busFrames);
    if (AudioDeviceCreateIOProcID(ioDevice_, IOProc, this, &proc_) != noErr ||
        AudioDeviceStart(ioDevice_, proc_) != noErr) {
        Stop();
        return false;
    }
    return true;
}

bool DeviceSource::NeedsRestart() const
{
    return proc_ && (hal::DeviceForUID(uid_) != device_ || hal::NominalRate(device_) != rate_);
}

void DeviceSource::Stop()
{
    if (proc_) {
        AudioDeviceStop(ioDevice_, proc_);
        AudioDeviceDestroyIOProcID(ioDevice_, proc_);
        proc_ = nullptr;
    }
    Unpublish();
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

std::string DeviceSource::Detail() const
{
    return processor_ ? processor_->Describe() : std::string();
}

// AppSource

AppSource::AppSource(std::string bundleID, std::optional<std::string> instance, Retire retire)
    : Source(instance ? "app:" + bundleID + "#" + *instance : "app:" + bundleID,
          std::move(retire))
    , bundleID_(std::move(bundleID))
    , instance_(std::move(instance))
{
}

AppSource::~AppSource()
{
    Stop();
}

OSStatus AppSource::IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
    const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* context)
{
    static_cast<AppSource*>(context)->Produce(input);
    return noErr;
}

// Every audio process whose owning app copy is this source's app, and, with an instance,
// the copy launched with that identity.
std::vector<AudioObjectID> AppSource::MatchingProcesses() const
{
    std::vector<AudioObjectID> matches;
    for (AudioObjectID object : hal::GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyProcessObjectList)) {
        pid_t pid = -1;
        hal::Get(object, kAudioProcessPropertyPID, pid);
        const int owner = pid > 0 ? OwnerPID(pid) : 0;
        if (!owner || AppBundleID(owner) != bundleID_) {
            continue;
        }
        if (instance_ && CopyIdentity(owner) != *instance_) {
            continue;
        }
        matches.push_back(object);
    }
    std::sort(matches.begin(), matches.end());
    return matches;
}

static NSArray<NSNumber*>* Numbers(const std::vector<AudioObjectID>& objects)
{
    NSMutableArray* numbers = [NSMutableArray arrayWithCapacity:objects.size()];
    for (AudioObjectID object : objects) {
        [numbers addObject:@(object)];
    }
    return numbers;
}

bool AppSource::Start(double busRate, uint32_t busFrames)
{
    if (proc_) {
        return true;
    }
    processes_ = MatchingProcesses();
    CATapDescription* description =
        [[CATapDescription alloc] initStereoMixdownOfProcesses:Numbers(processes_)];
    description.name = [NSString stringWithFormat:@"Blend: %s", bundleID_.c_str()];
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
    Publish(hal::NominalRate(aggregate_), busRate, hal::BufferFrames(aggregate_), busFrames);
    if (AudioDeviceCreateIOProcID(aggregate_, IOProc, this, &proc_) != noErr ||
        AudioDeviceStart(aggregate_, proc_) != noErr) {
        Stop();
        return false;
    }
    return true;
}

void AppSource::RefreshProcesses()
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

void AppSource::SetMuted(bool muted)
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

void AppSource::Stop()
{
    if (proc_) {
        AudioDeviceStop(aggregate_, proc_);
        AudioDeviceDestroyIOProcID(aggregate_, proc_);
        proc_ = nullptr;
    }
    Unpublish();
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

// MonitorOutput

MonitorOutput::MonitorOutput(Retire retire)
    : Source("monitor", std::move(retire))
    , scratch_(size_t(4096) * 2, 0.0f)
{
}

MonitorOutput::~MonitorOutput()
{
    Stop();
}

bool MonitorOutput::Start(double busRate, uint32_t busFrames)
{
    if (proc_) {
        return true;
    }
    hal::Get(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, device_);
    if (device_ == kAudioObjectUnknown) {
        return false;
    }
    // Here the bus is the producer and the output device the consumer. The output's
    // buffer size is left alone; it is shared with every app playing sound.
    Publish(busRate, hal::NominalRate(device_), busFrames,
        std::min<uint32_t>(hal::BufferFrames(device_), 4096));
    if (AudioDeviceCreateIOProcID(device_, IOProc, this, &proc_) != noErr ||
        AudioDeviceStart(device_, proc_) != noErr) {
        Stop();
        return false;
    }
    return true;
}

void MonitorOutput::Stop()
{
    if (proc_) {
        AudioDeviceStop(device_, proc_);
        AudioDeviceDestroyIOProcID(device_, proc_);
        proc_ = nullptr;
    }
    Unpublish();
}

void MonitorOutput::Feed(const float* stereo, uint32_t frames)
{
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 2;
    list.mBuffers[0].mDataByteSize = frames * 2 * sizeof(float);
    list.mBuffers[0].mData = const_cast<float*>(stereo);
    Produce(&list);
}

OSStatus MonitorOutput::IOProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
    const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*, void* context)
{
    auto self = static_cast<MonitorOutput*>(context);
    if (!output || output->mNumberBuffers == 0) {
        return noErr;
    }
    const AudioBuffer& first = output->mBuffers[0];
    const UInt32 channels = std::max<UInt32>(1, first.mNumberChannels);
    const UInt32 frames = std::min<UInt32>(first.mDataByteSize / (sizeof(float) * channels), 4096);
    self->Pull(self->scratch_.data(), frames);
    // Left and right go to the first two output channels found; everything else is silent.
    UInt32 channel = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer& buffer = output->mBuffers[b];
        auto data = static_cast<float*>(buffer.mData);
        for (UInt32 c = 0; c < buffer.mNumberChannels; c++, channel++) {
            for (UInt32 i = 0; i < frames; i++) {
                data[i * buffer.mNumberChannels + c] =
                    channel < 2 ? self->scratch_[i * 2 + channel] : 0.0f;
            }
        }
    }
    return noErr;
}

} // namespace blend
