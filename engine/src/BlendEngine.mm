#include "BlendEngine.h"

#include "Apps.hpp"
#include "Engine.hpp"
#include "Identity.hpp"

#include <nlohmann/json.hpp>

#include <cstdlib>
#include <cstring>

struct BlendEngine
{
    blend::Engine engine;
};

BlendEngine* BlendEngineCreate(void)
{
    return new BlendEngine;
}

void BlendEngineDestroy(BlendEngine* engine)
{
    delete engine;
}

bool BlendEngineApply(BlendEngine* engine, const char* json, char* error, size_t errorSize)
{
    std::string message;
    if (engine->engine.Apply(json ? json : "", message)) {
        return true;
    }
    if (error && errorSize) {
        std::strncpy(error, message.c_str(), errorSize - 1);
        error[errorSize - 1] = 0;
    }
    return false;
}

size_t BlendEngineStatus(BlendEngine* engine, BlendMixStatus* statuses, size_t capacity)
{
    auto status = engine->engine.Status();
    size_t n = std::min(capacity, status.size());
    for (size_t i = 0; i < n; i++) {
        std::memset(&statuses[i], 0, sizeof(BlendMixStatus));
        std::strncpy(statuses[i].id, status[i].id.c_str(), sizeof(statuses[i].id) - 1);
        statuses[i].deviceReady = status[i].deviceReady;
        statuses[i].running = status[i].running;
        statuses[i].peak = status[i].peak;
        statuses[i].userCount = int(std::min<size_t>(status[i].users.size(), BLEND_MAX_USERS));
        for (int u = 0; u < statuses[i].userCount; u++) {
            std::strncpy(statuses[i].users[u], status[i].users[size_t(u)].c_str(),
                sizeof(statuses[i].users[u]) - 1);
        }
        statuses[i].sourceCount =
            int(std::min<size_t>(status[i].sourcePeaks.size(), BLEND_MAX_SOURCES));
        for (int s = 0; s < statuses[i].sourceCount; s++) {
            statuses[i].sourcePeaks[s] = status[i].sourcePeaks[size_t(s)];
            statuses[i].sourceLive[s] = status[i].sourceLive[size_t(s)];
        }
    }
    return n;
}

char* BlendEngineDiagnostics(BlendEngine* engine)
{
    return strdup(engine->engine.Diagnostics().c_str());
}

char* BlendCopyRunningApps(void)
{
    auto list = nlohmann::json::array();
    for (const auto& copy : blend::RunningCopies()) {
        list.push_back({{"bundleID", copy.bundleID}, {"name", copy.name}, {"pid", copy.pid},
            {"identity", copy.identity}, {"label", blend::IdentityLabel(copy.identity)},
            {"playing", copy.playing}, {"listening", copy.listening}});
    }
    return strdup(list.dump().c_str());
}

bool BlendEngineSetProbes(BlendEngine* engine, const char* json, char* error, size_t errorSize)
{
    std::string message;
    if (engine->engine.SetProbes(json ? json : "[]", message)) {
        return true;
    }
    if (error && errorSize) {
        std::strncpy(error, message.c_str(), errorSize - 1);
        error[errorSize - 1] = 0;
    }
    return false;
}

size_t BlendEngineProbeLevels(BlendEngine* engine, float* levels, size_t capacity)
{
    auto values = engine->engine.ProbeLevels();
    size_t n = std::min(capacity, values.size());
    std::copy(values.begin(), values.begin() + long(n), levels);
    return n;
}

void BlendEngineMuteProbe(BlendEngine* engine, size_t index, bool muted)
{
    engine->engine.MuteProbe(index, muted);
}

void BlendEngineStartCheck(BlendEngine* engine, const char* mixID, bool live)
{
    engine->engine.StartCheck(mixID ? mixID : "", live);
}

void BlendEngineStopCheck(BlendEngine* engine)
{
    engine->engine.StopCheck();
}

size_t BlendEngineCopyCheck(BlendEngine* engine, const char* mixID, float* stereo,
    size_t maxFrames)
{
    return engine->engine.CopyCheck(mixID ? mixID : "", stereo, maxFrames);
}
