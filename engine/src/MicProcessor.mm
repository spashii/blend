#include "MicProcessor.hpp"

#include <modules/audio_processing/include/audio_processing.h>

#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>

namespace blend {

namespace {

os_log_t Log()
{
    static os_log_t log = os_log_create("app.blend.engine", "processing");
    return log;
}

} // namespace

struct MicProcessor::Apm
{
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig stream;
};

MicProcessor::Isolation MicProcessor::ParseIsolation(const std::string& value)
{
    if (value == "standard") {
        return Isolation::Standard;
    }
    if (value == "high") {
        return Isolation::HighQuality;
    }
    return Isolation::Off;
}

MicProcessor::MicProcessor(double rate, Sink sink, void* context)
    : rate_(rate)
    , block_(uint32_t(std::lround(rate / 100)))
    , sink_(sink)
    , context_(context)
    , mic_(block_, 0.0f)
    , reference_(block_, 0.0f)
    , cleaned_(block_, 0.0f)
    , isolated_(block_, 0.0f)
{
}

std::unique_ptr<MicProcessor> MicProcessor::Create(double rate, bool echoCancel,
    Isolation isolation, Sink sink, void* context)
{
    if (rate < 8000 || (!echoCancel && isolation == Isolation::Off)) {
        return nullptr;
    }
    std::unique_ptr<MicProcessor> processor(new MicProcessor(rate, sink, context));
    if (echoCancel) {
        auto apm = webrtc::AudioProcessingBuilder().Create();
        webrtc::AudioProcessing::Config config;
        config.echo_canceller.enabled = true;
        config.echo_canceller.mobile_mode = false;
        // Removes rumble below 80 Hz, which AEC3 expects; noise is isolation's job.
        config.high_pass_filter.enabled = true;
        apm->ApplyConfig(config);
        // A rate AEC3 cannot take fails the first block, which then marks the stage failed.
        processor->apm_.reset(new Apm{apm, webrtc::StreamConfig(int(std::lround(rate)), 1)});
    }
    if (isolation != Isolation::Off && !processor->StartIsolation(isolation)) {
        os_log_error(Log(), "voice isolation could not start at %.0f Hz", rate);
    }
    if (!processor->apm_ && !processor->isolation_) {
        return nullptr;
    }
    return processor;
}

MicProcessor::~MicProcessor()
{
    if (isolation_) {
        AudioUnitUninitialize(isolation_);
        AudioComponentInstanceDispose(isolation_);
    }
}

bool MicProcessor::EchoCancelling() const
{
    return apm_ && !apmFailed_.load(std::memory_order_relaxed);
}

bool MicProcessor::StartIsolation(Isolation isolation)
{
    AudioComponentDescription description = {kAudioUnitType_Effect,
        kAudioUnitSubType_AUSoundIsolation, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &description);
    AudioUnit unit = nullptr;
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) {
        return false;
    }
    AudioStreamBasicDescription format = {};
    format.mSampleRate = rate_;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    UInt32 maxFrames = std::max<UInt32>(block_, 1024);
    AURenderCallbackStruct feed = {FeedIsolation, this};
    const Float32 model = isolation == Isolation::HighQuality
        ? Float32(kAUSoundIsolationSoundType_HighQualityVoice)
        : Float32(kAUSoundIsolationSoundType_Voice);
    bool ok =
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, sizeof(format)) == noErr &&
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
            &format, sizeof(format)) == noErr &&
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)) == noErr &&
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &feed, sizeof(feed)) == noErr &&
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate,
            kAudioUnitScope_Global, 0, model, 0) == noErr &&
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent,
            kAudioUnitScope_Global, 0, 100, 0) == noErr &&
        AudioUnitInitialize(unit) == noErr;
    if (!ok) {
        AudioComponentInstanceDispose(unit);
        return false;
    }
    Float64 latency = 0;
    UInt32 size = sizeof(latency);
    AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency,
        &size);
    isolationLatency_ = latency;
    isolation_ = unit;
    return true;
}

void MicProcessor::Process(const float* mic, uint32_t micStride, const float* refLeft,
    uint32_t refLeftStride, const float* refRight, uint32_t refRightStride, uint32_t frames)
{
    for (uint32_t i = 0; i < frames; i++) {
        mic_[filled_] = mic[size_t(i) * micStride];
        reference_[filled_] = refLeft ? 0.5f * (refLeft[size_t(i) * refLeftStride] +
                                                   refRight[size_t(i) * refRightStride])
                                      : 0.0f;
        if (++filled_ == block_) {
            ProcessBlock();
            filled_ = 0;
        }
    }
}

void MicProcessor::ProcessBlock()
{
    const float* block = mic_.data();
    if (apm_ && !apmFailed_.load(std::memory_order_relaxed)) {
        float* reference = reference_.data();
        float* mic = mic_.data();
        float* cleaned = cleaned_.data();
        auto& apm = *apm_->apm;
        const bool ok =
            apm.ProcessReverseStream(&reference, apm_->stream, apm_->stream, &reference) ==
                webrtc::AudioProcessing::kNoError &&
            apm.set_stream_delay_ms(0) == webrtc::AudioProcessing::kNoError &&
            apm.ProcessStream(&mic, apm_->stream, apm_->stream, &cleaned) ==
                webrtc::AudioProcessing::kNoError;
        if (ok) {
            block = cleaned_.data();
        } else {
            apmFailed_.store(true, std::memory_order_relaxed);
            os_log_error(Log(), "echo cancellation failed at %.0f Hz; the microphone goes unprocessed", rate_);
        }
    }
    if (isolation_ && !isolationFailed_.load(std::memory_order_relaxed)) {
        isolationInput_ = block;
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp time = {};
        time.mSampleTime = isolationTime_;
        time.mFlags = kAudioTimeStampSampleTimeValid;
        AudioBufferList output;
        output.mNumberBuffers = 1;
        output.mBuffers[0].mNumberChannels = 1;
        output.mBuffers[0].mDataByteSize = block_ * sizeof(float);
        output.mBuffers[0].mData = isolated_.data();
        if (AudioUnitRender(isolation_, &flags, &time, 0, block_, &output) == noErr) {
            block = static_cast<const float*>(output.mBuffers[0].mData);
        } else {
            isolationFailed_.store(true, std::memory_order_relaxed);
        }
        isolationTime_ += block_;
        isolationInput_ = nullptr;
    }
    sink_(context_, block, block_);
}

OSStatus MicProcessor::FeedIsolation(void* context, AudioUnitRenderActionFlags*,
    const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* data)
{
    auto self = static_cast<MicProcessor*>(context);
    const uint32_t available = self->isolationInput_ ? std::min(frames, self->block_) : 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        auto out = static_cast<float*>(data->mBuffers[b].mData);
        if (available) {
            std::memcpy(out, self->isolationInput_, available * sizeof(float));
        }
        std::memset(out + available, 0, (frames - available) * sizeof(float));
    }
    return noErr;
}

std::string MicProcessor::Describe() const
{
    std::ostringstream out;
    if (apm_) {
        out << " echo-cancel";
        if (apmFailed_.load()) {
            out << "=failed";
        } else {
            auto stats = apm_->apm->GetStatistics();
            if (stats.echo_return_loss_enhancement) {
                out << " erle=" << std::lround(*stats.echo_return_loss_enhancement) << "dB";
            }
            if (stats.delay_ms) {
                out << " echo-delay=" << *stats.delay_ms << "ms";
            }
        }
    }
    if (isolation_) {
        out << " isolation latency=" << std::lround(isolationLatency_ * 1000) << "ms"
            << (isolationFailed_.load() ? " failed" : "");
    }
    return out.str();
}

} // namespace blend
