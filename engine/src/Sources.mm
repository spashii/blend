#include "Sources.hpp"

#include "HAL.hpp"
#include "Routing.hpp"

#include <algorithm>
#include <cmath>
#include <sstream>

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

void Source::Produce(const AudioBufferList* input, routing::ChannelSpan span)
{
    Stream* stream = stream_.load(std::memory_order_acquire);
    if (!stream || !input || input->mNumberBuffers == 0) {
        return;
    }
    const AudioBuffer& first = input->mBuffers[0];
    const UInt32 firstChannels = std::max<UInt32>(1, first.mNumberChannels);
    const UInt32 frames =
        std::min<UInt32>(first.mDataByteSize / (sizeof(float) * firstChannels), kMaxProduceFrames);

    // Left and right come from the first two channels of the span, counted across all
    // buffers; a mono source is copied to both.
    const routing::Stereo pair = routing::FirstTwo(input, span);
    if (!pair.left) {
        return;
    }
    float peak = producedPeak_.load(std::memory_order_relaxed);
    for (UInt32 i = 0; i < frames; i++) {
        stereo_[i * 2] = pair.left[i];
        stereo_[i * 2 + 1] = pair.right[i];
        peak = std::max(peak, std::max(std::fabs(stereo_[i * 2]), std::fabs(stereo_[i * 2 + 1])));
    }
    producedPeak_.store(peak, std::memory_order_relaxed);
    stream->ring.Write(stereo_.data(), frames);
}

// DeviceSource

DeviceSource::DeviceSource(std::string key, std::string uid, bool echoCancel,
    MicProcessor::Isolation isolation, Retire retire)
    : Source(std::move(key), std::move(retire))
    , mic_(MicCapture::Options{std::move(uid),
          echoCancel ? MicCapture::Reference::EverythingButSelf : MicCapture::Reference::None,
          echoCancel, isolation, false})
{
}

DeviceSource::~DeviceSource()
{
    Stop();
}

void DeviceSource::Sink::Block(const float* me, const float*, uint32_t frames)
{
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = 1;
    list.mBuffers[0].mDataByteSize = frames * sizeof(float);
    list.mBuffers[0].mData = const_cast<float*>(me);
    owner_.Produce(&list);
}

bool DeviceSource::Start(double busRate, uint32_t busFrames)
{
    if (mic_.Running()) {
        return true;
    }
    busRate_ = busRate;
    busFrames_ = busFrames;
    return mic_.Start(sink_);
}

bool DeviceSource::NeedsRestart() const
{
    return mic_.NeedsRestart();
}

void DeviceSource::Stop()
{
    mic_.Stop();
}

std::string DeviceSource::Detail() const
{
    return mic_.Describe();
}

// AppSource

AppSource::AppSource(std::string bundleID, std::optional<std::string> instance, Retire retire)
    : AppSource(instance ? "app:" + bundleID + "#" + *instance : "app:" + bundleID,
          TapTarget{bundleID, instance, false}, std::move(retire))
{
}

AppSource::AppSource(std::string key, TapTarget target, Retire retire)
    : Source(std::move(key), std::move(retire))
    , tap_(std::move(target), "Blend")
{
}

std::shared_ptr<AppSource> AppSource::System(std::string key, Retire retire)
{
    return std::shared_ptr<AppSource>(
        new AppSource(std::move(key), TapTarget{{}, std::nullopt, true}, std::move(retire)));
}

AppSource::~AppSource()
{
    Stop();
}

bool AppSource::Start(double busRate, uint32_t busFrames)
{
    if (tap_.Running()) {
        return true;
    }
    busRate_ = busRate;
    busFrames_ = busFrames;
    return tap_.Start(sink_);
}

void AppSource::Stop()
{
    tap_.Stop();
}

std::string AppSource::Detail() const
{
    std::ostringstream out;
    out << " tap-channels=" << tap_.DeviceChannels() << "+" << tap_.TapChannels();
    if (tap_.ChannelMismatches()) {
        out << " channel-mismatches=" << tap_.ChannelMismatches();
    }
    return out.str();
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
