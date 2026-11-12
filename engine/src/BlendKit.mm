#include "BlendKit.h"

#include "CallCapture.hpp"
#include "Probes.hpp"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <cstring>

#ifndef BLEND_KIT_VERSION
#define BLEND_KIT_VERSION "0.0.0"
#endif

struct BKCallCapture
{
    std::unique_ptr<blend::CallCapture> capture;
};

struct BKProbes
{
    blend::Probes probes;
};

const char* BKVersion(void)
{
    return BLEND_KIT_VERSION;
}

namespace {

BKEventKind Kind(blend::CallEvent event)
{
    switch (event) {
    case blend::CallEvent::MicrophoneRestarted: return BKEventMicrophoneRestarted;
    case blend::CallEvent::MicrophoneLost: return BKEventMicrophoneLost;
    case blend::CallEvent::CallTapLost: return BKEventCallTapLost;
    case blend::CallEvent::CallTapRestored: return BKEventCallTapRestored;
    case blend::CallEvent::CallSilent: return BKEventCallSilent;
    case blend::CallEvent::CallHeard: return BKEventCallHeard;
    case blend::CallEvent::EchoCancellationFailed: return BKEventEchoCancellationFailed;
    case blend::CallEvent::Overflow: return BKEventOverflow;
    case blend::CallEvent::AudioServiceRestarted: return BKEventAudioServiceRestarted;
    }
    return BKEventOverflow;
}

} // namespace

BKCallCapture* BKCallCaptureCreate(const BKCallCaptureOptions* options, BKFramesCallback frames,
    BKEventCallback events, void* context)
{
    if (!options || !frames) {
        return nullptr;
    }
    blend::CallCaptureOptions copy;
    copy.label = options->label && *options->label ? options->label : "Blend";
    copy.microphoneUID = options->microphoneUID ? options->microphoneUID : "";
    switch (options->echo) {
    case BKEchoCancellationOff: copy.echo = blend::EchoMode::Off; break;
    case BKEchoCancellationOn: copy.echo = blend::EchoMode::On; break;
    default: copy.echo = blend::EchoMode::Automatic; break;
    }
    switch (options->isolation) {
    case BKIsolationStandard: copy.isolation = blend::MicProcessor::Isolation::Standard; break;
    case BKIsolationHighQuality: copy.isolation = blend::MicProcessor::Isolation::HighQuality; break;
    default: copy.isolation = blend::MicProcessor::Isolation::Off; break;
    }
    copy.callBundleID = options->callBundleID ? options->callBundleID : "";
    if (options->callInstance) {
        copy.callInstance = options->callInstance;
    }
    copy.outputRate = options->outputRate;
    auto result = new BKCallCapture;
    result->capture = std::make_unique<blend::CallCapture>(std::move(copy),
        [=](const float* me, const float* call, uint32_t count, uint64_t position) {
            frames(context, me, call, count, position);
        },
        [=](blend::CallEvent event, const std::string& detail) {
            if (events) {
                events(context, Kind(event), detail.empty() ? nullptr : detail.c_str());
            }
        });
    return result;
}

BKStartResult BKCallCaptureStart(BKCallCapture* capture)
{
    switch (capture->capture->Start()) {
    case blend::CallStart::Started: return BKStartStarted;
    case blend::CallStart::CallUnavailable: return BKStartCallUnavailable;
    default: return BKStartMicrophoneUnavailable;
    }
}

void BKCallCaptureStop(BKCallCapture* capture)
{
    capture->capture->Stop();
}

void BKCallCaptureDestroy(BKCallCapture* capture)
{
    delete capture;
}

char* BKCallCaptureDiagnostics(BKCallCapture* capture)
{
    return strdup(capture->capture->Diagnostics().c_str());
}

BKProbes* BKProbesCreate(const char* label)
{
    return new BKProbes{blend::Probes(label && *label ? label : "Blend")};
}

bool BKProbesSet(BKProbes* probes, const char* json, char* error, size_t errorSize)
{
    std::vector<blend::Probes::Target> targets;
    try {
        for (const auto& item : nlohmann::json::parse(json ? json : "[]")) {
            std::optional<std::string> instance;
            if (item.contains("instance") && item["instance"].is_string()) {
                instance = item["instance"].get<std::string>();
            }
            targets.push_back({item.at("bundleID").get<std::string>(), instance});
        }
    } catch (const std::exception& e) {
        if (error && errorSize) {
            std::strncpy(error, e.what(), errorSize - 1);
            error[errorSize - 1] = 0;
        }
        return false;
    }
    probes->probes.Set(std::move(targets));
    return true;
}

size_t BKProbesLevels(BKProbes* probes, float* levels, size_t capacity)
{
    const auto values = probes->probes.Levels();
    const size_t count = std::min(values.size(), capacity);
    std::copy_n(values.begin(), count, levels);
    return count;
}

void BKProbesMute(BKProbes* probes, size_t index, bool muted)
{
    probes->probes.SetMuted(index, muted);
}

void BKProbesDestroy(BKProbes* probes)
{
    delete probes;
}
