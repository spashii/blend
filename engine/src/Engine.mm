#include "Engine.hpp"

#include "Apps.hpp"
#include "HAL.hpp"

#import <Foundation/Foundation.h>

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <set>
#include <sstream>

#include <unistd.h>

namespace blend {

namespace {

constexpr char kBusUID[] = "app.blend.bus";
constexpr char kMixUIDPrefix[] = "app.blend.mix.";
constexpr char kDriverBundleID[] = "app.blend.driver";
constexpr AudioObjectPropertySelector kMixListProperty = 'bmxs';
// The apps running IO on a mix device, as [{pid, bundleID}] (driver/src/Driver.cpp). Mixed
// case, so it can never clash with Apple's selectors, which are all lower case.
constexpr AudioObjectPropertySelector kClientsProperty = 'BLus';
constexpr uint32_t kBusChannels = 32;
constexpr uint32_t kMaxSources = 32;
constexpr uint32_t kMaxFrames = 4096;
// -1 dBFS: headroom for codecs downstream, and the point the limiter holds.
constexpr float kLimit = 0.891f;
// Recent output kept per mix for a check on speakers, with a second of margin.
constexpr size_t kHistoryFrames = 6 * 48000;

float DbToGain(float db)
{
    return std::pow(10.0f, db / 20.0f);
}

std::string MixUID(const std::string& id)
{
    return kMixUIDPrefix + id;
}

// What the engine watches on each mix device: whether it is read, and by whom.
std::array<AudioObjectPropertySelector, 2> MixDeviceProperties()
{
    return {kAudioDevicePropertyDeviceIsRunningSomewhere, kClientsProperty};
}

} // namespace

Engine::MixState::MixState()
    : history(kHistoryFrames * 2, 0.0f)
{
}

Engine::Engine()
    : queue_(dispatch_queue_create("app.blend.engine", DISPATCH_QUEUE_SERIAL))
    , scratch_(size_t(kMaxSources) * kMaxFrames * 2, 0.0f)
    , mixBuffer_(size_t(kMaxFrames) * 2, 0.0f)
{
    monitor_ = std::make_unique<MonitorOutput>(
        [this](std::function<void()> fn) { RetireLater(std::move(fn)); });
    sweep_ = std::make_unique<RepeatingTimer>(queue_, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC, ^{
        if (shuttingDown_) {
            return;
        }
        Sweep();
        RestartStaleSources();
        if (++sweeps_ % 20 == 0) {
            RetryFailedSources();
        }
    });
    dispatch_sync(queue_, ^{ AddSystemListeners(); });
}

// Listener and timer blocks capture this engine and may already be queued, so they are
// stopped first, and every block checks shuttingDown_ before touching anything.
Engine::~Engine()
{
    dispatch_sync(queue_, ^{
        shuttingDown_ = true;
        alive_->store(false);
        sweep_->Stop();
        observer_ = nullptr;
        RemoveSystemListeners();
        for (auto& [id, mix] : mixDevices_) {
            RemoveMixListener(mix);
        }
        mixDevices_.clear();
        StopCheckOnQueue();
        StopBus();
        for (auto& probe : probes_) {
            probe->Stop();
        }
        probes_.clear();
        for (auto& [key, source] : sources_) {
            source->Stop();
        }
        delete graph_.exchange(nullptr);
        sources_.clear();
        Sweep();
    });
    dispatch_sync(queue_, ^{});
}

bool Engine::Apply(const std::string& json, std::string& error)
{
    Config config;
    if (!ParseConfig(json, config, error)) {
        return false;
    }
    __block Config moved = std::move(config);
    dispatch_async(queue_, ^{
        if (!shuttingDown_) {
            ApplyOnQueue(std::move(moved));
        }
    });
    return true;
}

void Engine::ApplyOnQueue(Config config)
{
    config_ = std::move(config);
    PushMixesToDriver();

    std::set<std::string> wanted;
    std::set<std::string> mixIDs;
    for (const auto& mix : config_.mixes) {
        mixIDs.insert(mix.id);
        if (!mixStates_.count(mix.id)) {
            mixStates_[mix.id] = std::make_shared<MixState>();
        }
        for (const auto& source : mix.sources) {
            wanted.insert(source.Key());
            SourceFor(source);
        }
    }
    for (auto it = mixStates_.begin(); it != mixStates_.end();) {
        it = mixIDs.count(it->first) ? std::next(it) : mixStates_.erase(it);
    }
    if (!checking_.empty() && !mixIDs.count(checking_)) {
        StopCheckOnQueue();
    }
    for (auto it = sources_.begin(); it != sources_.end();) {
        if (wanted.count(it->first)) {
            ++it;
            continue;
        }
        it->second->Stop();
        // The bus thread may still hold it through the current graph.
        auto source = it->second;
        RetireLater([source] {});
        it = sources_.erase(it);
    }
    ResolveMixDevices();
    PublishGraph();
    Reconcile();
}

std::shared_ptr<Source> Engine::SourceFor(const SourceConfig& config)
{
    const std::string key = config.Key();
    if (auto it = sources_.find(key); it != sources_.end()) {
        return it->second;
    }
    Retire retire = [this](std::function<void()> fn) { RetireLater(std::move(fn)); };
    std::shared_ptr<Source> source;
    if (config.kind == SourceConfig::Kind::App) {
        source = std::make_shared<AppSource>(config.bundleID, config.instance, retire);
    } else if (config.kind == SourceConfig::Kind::System) {
        source = AppSource::System(key, retire);
    } else {
        source = std::make_shared<DeviceSource>(key, config.uid, config.echoCancel,
            MicProcessor::ParseIsolation(config.isolation), retire);
    }
    sources_[key] = source;
    return source;
}

// The driver saves its list inside coreaudiod, so it is only sent when an id, name or
// slot actually changed, not on every volume change.
void Engine::PushMixesToDriver()
{
    NSMutableArray* list = [NSMutableArray array];
    std::string key;
    for (const auto& mix : config_.mixes) {
        [list addObject:@{
            @"id" : @(mix.id.c_str()),
            @"name" : @(mix.name.c_str()),
            @"slot" : @(mix.slot),
        }];
        key += mix.id + '\n' + mix.name + '\n' + std::to_string(mix.slot) + '\n';
    }
    if (key == pushedMixes_) {
        return;
    }
    AudioObjectID plugin =
        hal::Translate(kAudioHardwarePropertyTranslateBundleIDToPlugIn, kDriverBundleID);
    if (plugin == kAudioObjectUnknown) {
        return;
    }
    CFPropertyListRef value = (__bridge CFPropertyListRef)list;
    auto address = hal::Address(kMixListProperty);
    if (AudioObjectSetPropertyData(plugin, &address, 0, nullptr, sizeof(value), &value) ==
        noErr) {
        pushedMixes_ = key;
    }
}

void Engine::RemoveMixListener(MixDevice& entry)
{
    if (entry.listener) {
        for (AudioObjectPropertySelector selector : MixDeviceProperties()) {
            auto address = hal::Address(selector);
            AudioObjectRemovePropertyListenerBlock(entry.device, &address, queue_, entry.listener);
        }
        entry.listener = nullptr;
    }
}

// Whether the mix is read, and by which apps. A helper process (a browser's audio
// service) is named after the app that owns it.
void Engine::ReadMixDevice(MixDevice& entry)
{
    entry.running = false;
    entry.users.clear();
    entry.userOwners.clear();
    if (entry.device == kAudioObjectUnknown) {
        return;
    }
    UInt32 running = 0;
    hal::Get(entry.device, kAudioDevicePropertyDeviceIsRunningSomewhere, running);
    entry.running = running;
    // An older driver has no such property.
    auto address = hal::Address(kClientsProperty);
    CFPropertyListRef clients = nullptr;
    if (!AudioObjectHasProperty(entry.device, &address) ||
        !hal::Get(entry.device, kClientsProperty, clients) || !clients) {
        return;
    }
    if (CFGetTypeID(clients) == CFArrayGetTypeID()) {
        NSArray* list = (__bridge NSArray*)clients;
        for (NSDictionary* client in list) {
            if (![client isKindOfClass:NSDictionary.class]) {
                continue;
            }
            const int pid = [client[@"pid"] intValue];
            if (pid == getpid()) {
                continue;
            }
            const int owner = pid > 0 ? OwnerPID(pid) : 0;
            if (owner && std::find(entry.userOwners.begin(), entry.userOwners.end(), owner) ==
                    entry.userOwners.end()) {
                entry.userOwners.push_back(owner);
            }
            std::string name = owner ? AppName(owner) : "";
            if (name.empty()) {
                NSString* bundleID = client[@"bundleID"];
                name = [bundleID isKindOfClass:NSString.class] ? bundleID.UTF8String : "";
            }
            if (!name.empty() &&
                std::find(entry.users.begin(), entry.users.end(), name) == entry.users.end()) {
                entry.users.push_back(name);
            }
        }
    }
    CFRelease(clients);
}

void Engine::ResolveMixDevices()
{
    std::set<std::string> ids;
    for (const auto& mix : config_.mixes) {
        ids.insert(mix.id);
        MixDevice& entry = mixDevices_[mix.id];
        AudioObjectID device = hal::DeviceForUID(MixUID(mix.id));
        if (device != entry.device) {
            RemoveMixListener(entry);
            entry.device = device;
            if (device != kAudioObjectUnknown) {
                const std::string id = mix.id;
                auto alive = alive_;
                entry.listener = ^(UInt32, const AudioObjectPropertyAddress*) {
                    if (!alive->load()) {
                        return;
                    }
                    auto it = mixDevices_.find(id);
                    if (it != mixDevices_.end()) {
                        ReadMixDevice(it->second);
                        UpdateSystemExclusions();
                        Reconcile();
                    }
                };
                for (AudioObjectPropertySelector selector : MixDeviceProperties()) {
                    auto address = hal::Address(selector);
                    AudioObjectAddPropertyListenerBlock(device, &address, queue_, entry.listener);
                }
            }
        }
        ReadMixDevice(entry);
    }
    for (auto it = mixDevices_.begin(); it != mixDevices_.end();) {
        if (ids.count(it->first)) {
            ++it;
            continue;
        }
        RemoveMixListener(it->second);
        it = mixDevices_.erase(it);
    }
    UpdateSystemExclusions();
}

// Each mix's system audio leaves out the apps reading that mix, before it starts and
// whenever they change.
void Engine::UpdateSystemExclusions()
{
    for (const auto& mix : config_.mixes) {
        auto device = mixDevices_.find(mix.id);
        const std::vector<int> owners =
            device != mixDevices_.end() ? device->second.userOwners : std::vector<int>{};
        for (const auto& source : mix.sources) {
            if (source.kind != SourceConfig::Kind::System) {
                continue;
            }
            auto it = sources_.find(source.Key());
            if (it == sources_.end()) {
                continue;
            }
            auto system = std::static_pointer_cast<AppSource>(it->second);
            system->SetExcludedOwners(owners);
            if (system->Live()) {
                system->RefreshProcesses();
            }
        }
    }
}

void Engine::Reconcile()
{
    std::set<std::string> needed;
    for (const auto& mix : config_.mixes) {
        auto it = mixDevices_.find(mix.id);
        const bool read = it != mixDevices_.end() && it->second.running;
        if (!read && checking_ != mix.id) {
            continue;
        }
        for (const auto& source : mix.sources) {
            needed.insert(source.Key());
        }
    }
    needed_ = needed;
    if (needed.empty() && checking_.empty()) {
        for (auto& [key, source] : sources_) {
            source->Stop();
        }
        StopBus();
        PublishSnapshot();
        return;
    }
    StartBus();
    if (busRunning_) {
        for (auto& [key, source] : sources_) {
            if (needed.count(key)) {
                if (!source->Live()) {
                    source->Start(busRate_, busFrames_);
                }
            } else if (source->Live()) {
                source->Stop();
            }
        }
    }
    PublishSnapshot();
}

void Engine::StartBus()
{
    if (busRunning_) {
        return;
    }
    bus_ = hal::DeviceForUID(kBusUID);
    if (bus_ == kAudioObjectUnknown) {
        return;
    }
    // Blend's own device, so the buffer size affects nobody else.
    hal::Set<UInt32>(bus_, kAudioDevicePropertyBufferFrameSize, 256);
    busRate_ = hal::NominalRate(bus_);
    busFrames_ = std::min(hal::BufferFrames(bus_), kMaxFrames);
    if (AudioDeviceCreateIOProcID(bus_, BusProc, this, &busProc_) != noErr) {
        busProc_ = nullptr;
        return;
    }
    if (AudioDeviceStart(bus_, busProc_) != noErr) {
        AudioDeviceDestroyIOProcID(bus_, busProc_);
        busProc_ = nullptr;
        return;
    }
    busRunning_ = true;
    sweep_->Start();
}

void Engine::StopBus()
{
    if (busProc_) {
        AudioDeviceStop(bus_, busProc_);
        AudioDeviceDestroyIOProcID(bus_, busProc_);
        busProc_ = nullptr;
    }
    busRunning_ = false;
    sweep_->Stop();
    Sweep();
}

void Engine::PublishGraph()
{
    auto graph = new Graph;
    std::map<std::string, uint32_t> index;
    for (const auto& [key, source] : sources_) {
        if (graph->sources.size() >= kMaxSources) {
            break;
        }
        index[key] = uint32_t(graph->sources.size());
        graph->sources.push_back(source);
    }
    // Ramps continue from the gains the bus thread last used, so a slider never clicks.
    std::map<std::pair<std::string, std::string>, float> previous;
    if (Graph* old = graph_.load(std::memory_order_acquire)) {
        for (const auto& mix : old->mixes) {
            for (size_t i = 0; i < mix.sources.size(); i++) {
                previous[{mix.id, old->sources[mix.sources[i]]->Key()}] =
                    mix.current[i].load(std::memory_order_relaxed);
            }
        }
    }
    for (const auto& mix : config_.mixes) {
        MixPlan plan;
        plan.id = mix.id;
        plan.slot = mix.slot;
        plan.gain = mix.muted ? 0 : DbToGain(mix.gainDb);
        plan.split = mix.split;
        plan.state = mixStates_[mix.id];
        for (size_t position = 0; position < mix.sources.size(); position++) {
            const auto& source = mix.sources[position];
            auto it = index.find(source.Key());
            if (it == index.end()) {
                continue;
            }
            plan.sources.push_back(it->second);
            plan.routes.push_back(!mix.split ? Route::Both
                    : position == 0             ? Route::Left
                                                : Route::Right);
            plan.targets.push_back(source.muted ? 0 : DbToGain(source.gainDb));
        }
        plan.current = std::make_unique<std::atomic<float>[]>(plan.sources.size());
        for (size_t i = 0; i < plan.sources.size(); i++) {
            auto it = previous.find({mix.id, graph->sources[plan.sources[i]]->Key()});
            plan.current[i].store(it != previous.end() ? it->second : 0.0f);
        }
        graph->mixes.push_back(std::move(plan));
    }
    if (Graph* old = graph_.exchange(graph, std::memory_order_acq_rel)) {
        RetireLater([old] { delete old; });
    }
}

void Engine::PublishSnapshot()
{
    Snapshot next;
    for (const auto& mix : config_.mixes) {
        Snapshot::Mix entry;
        entry.id = mix.id;
        if (auto it = mixDevices_.find(mix.id); it != mixDevices_.end()) {
            entry.deviceReady = it->second.device != kAudioObjectUnknown;
            entry.running = it->second.running;
            entry.users = it->second.users;
        }
        if (auto it = mixStates_.find(mix.id); it != mixStates_.end()) {
            entry.state = it->second;
        }
        for (const auto& source : mix.sources) {
            auto it = sources_.find(source.Key());
            entry.sources.push_back(it != sources_.end() ? it->second : nullptr);
        }
        next.mixes.push_back(std::move(entry));
    }
    next.probes = probes_;
    {
        std::lock_guard lock(snapshotMutex_);
        snapshot_ = std::move(next);
    }
    Notify();
}

void Engine::SetObserver(dispatch_block_t changed)
{
    dispatch_async(queue_, ^{
        if (!shuttingDown_) {
            observer_ = changed;
        }
    });
}

// The flag clears before the observer runs, so a change during its read is delivered again.
void Engine::Notify()
{
    if (!observer_ || notifyPending_->exchange(true)) {
        return;
    }
    auto pending = notifyPending_;
    dispatch_block_t observer = observer_;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending->store(false);
        observer();
    });
}

void Engine::RetireLater(std::function<void()> fn)
{
    if (!busRunning_) {
        fn();
        return;
    }
    retiring_.emplace_back(cycles_.load(std::memory_order_acquire) + 2, std::move(fn));
}

void Engine::Sweep()
{
    const uint64_t cycles = cycles_.load(std::memory_order_acquire);
    std::vector<std::function<void()>> ready;
    for (auto it = retiring_.begin(); it != retiring_.end();) {
        if (!busRunning_ || cycles >= it->first) {
            ready.push_back(std::move(it->second));
            it = retiring_.erase(it);
        } else {
            ++it;
        }
    }
    for (auto& fn : ready) {
        fn();
    }
}

// A device that disconnected and came back (a new object for the same UID) or changed
// rate (AirPods switching to their call mode) needs its capture rebuilt.
void Engine::RestartStaleSources()
{
    bool restarted = false;
    for (auto& [key, source] : sources_) {
        if (source->Live() && source->NeedsRestart()) {
            source->Stop();
            restarted = true;
        }
    }
    if (restarted) {
        Reconcile();
    }
}

// A source that could not start (a device mid-reconnect, an app tap the HAL refused) is
// tried again every two seconds while a mix needs it.
void Engine::RetryFailedSources()
{
    if (!busRunning_) {
        return;
    }
    for (const auto& key : needed_) {
        auto it = sources_.find(key);
        if (it != sources_.end() && !it->second->Live()) {
            Reconcile();
            return;
        }
    }
}

// After coreaudiod restarts every object ID is stale: drop all of them and rebuild from
// the configuration.
void Engine::Recover()
{
    monitorSlot_ = -1;
    monitor_->Stop();
    if (busProc_) {
        AudioDeviceStop(bus_, busProc_);
        AudioDeviceDestroyIOProcID(bus_, busProc_);
        busProc_ = nullptr;
    }
    busRunning_ = false;
    sweep_->Stop();
    bus_ = kAudioObjectUnknown;
    for (auto& [key, source] : sources_) {
        source->Stop();
    }
    for (auto& probe : probes_) {
        probe->Stop();
    }
    for (auto& [id, mix] : mixDevices_) {
        RemoveMixListener(mix);
    }
    mixDevices_.clear();
    Sweep();
    pushedMixes_.clear();
    PushMixesToDriver();
    ResolveMixDevices();
    Reconcile();
    for (auto& probe : probes_) {
        probe->Start(48000, 256);
    }
    if (!checking_.empty()) {
        for (const auto& mix : config_.mixes) {
            if (mix.id == checking_ && monitorSlot_ < 0 && busRunning_) {
                // A live check resumes on whatever output exists now.
                if (monitor_->Start(busRate_, busFrames_)) {
                    monitorSlot_ = int(mix.slot);
                }
            }
        }
    }
}

void Engine::AddSystemListeners()
{
    auto alive = alive_;
    auto devices = hal::Address(kAudioHardwarePropertyDevices);
    devicesListener_ = ^(UInt32, const AudioObjectPropertyAddress*) {
        if (!alive->load()) {
            return;
        }
        ResolveMixDevices();
        RestartStaleSources();
        Reconcile();
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devices, queue_,
        devicesListener_);

    // App capture is clocked by the default output, so it follows output changes; so does
    // a live check.
    auto output = hal::Address(kAudioHardwarePropertyDefaultOutputDevice);
    outputListener_ = ^(UInt32, const AudioObjectPropertyAddress*) {
        if (!alive->load()) {
            return;
        }
        for (auto& [key, source] : sources_) {
            if (dynamic_cast<AppSource*>(source.get()) && source->Live()) {
                source->Stop();
            }
        }
        Reconcile();
        if (monitorSlot_ >= 0) {
            const int slot = monitorSlot_;
            monitorSlot_ = -1;
            monitor_->Stop();
            if (monitor_->Start(busRate_, busFrames_)) {
                monitorSlot_ = slot;
            }
        }
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &output, queue_,
        outputListener_);

    auto processes = hal::Address(kAudioHardwarePropertyProcessObjectList);
    processListener_ = ^(UInt32, const AudioObjectPropertyAddress*) {
        if (!alive->load()) {
            return;
        }
        for (auto& [key, source] : sources_) {
            if (auto app = dynamic_cast<AppSource*>(source.get()); app && app->Live()) {
                app->RefreshProcesses();
            }
        }
        for (auto& probe : probes_) {
            probe->RefreshProcesses();
        }
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &processes, queue_,
        processListener_);

    auto restarted = hal::Address(kAudioHardwarePropertyServiceRestarted);
    restartListener_ = ^(UInt32, const AudioObjectPropertyAddress*) {
        if (alive->load()) {
            Recover();
        }
    };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &restarted, queue_,
        restartListener_);
}

void Engine::RemoveSystemListeners()
{
    const std::pair<AudioObjectPropertySelector, AudioObjectPropertyListenerBlock> listeners[] = {
        {kAudioHardwarePropertyDevices, devicesListener_},
        {kAudioHardwarePropertyDefaultOutputDevice, outputListener_},
        {kAudioHardwarePropertyProcessObjectList, processListener_},
        {kAudioHardwarePropertyServiceRestarted, restartListener_},
    };
    for (const auto& [selector, listener] : listeners) {
        auto address = hal::Address(selector);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, queue_,
            listener);
    }
}

OSStatus Engine::BusProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
    const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*, void* context)
{
    static_cast<Engine*>(context)->Render(output);
    return noErr;
}

void Engine::Render(AudioBufferList* output)
{
    if (output->mNumberBuffers < 1) {
        return;
    }
    AudioBuffer& buffer = output->mBuffers[0];
    const uint32_t channels = buffer.mNumberChannels;
    const uint32_t frames =
        std::min<uint32_t>(buffer.mDataByteSize / (sizeof(float) * channels), kMaxFrames);
    auto out = static_cast<float*>(buffer.mData);
    std::memset(out, 0, buffer.mDataByteSize);

    Graph* graph = graph_.load(std::memory_order_acquire);
    if (graph && channels >= kBusChannels) {
        for (size_t s = 0; s < graph->sources.size(); s++) {
            graph->sources[s]->Pull(&scratch_[s * kMaxFrames * 2], frames);
        }
        for (auto& mix : graph->mixes) {
            float* acc = mixBuffer_.data();
            std::memset(acc, 0, sizeof(float) * frames * 2);
            for (size_t e = 0; e < mix.sources.size(); e++) {
                const float* src = &scratch_[mix.sources[e] * kMaxFrames * 2];
                const float from = mix.current[e].load(std::memory_order_relaxed);
                const float to = mix.targets[e];
                AddSource(acc, src, frames, from, to, mix.gain, mix.routes[e]);
                mix.current[e].store(to, std::memory_order_relaxed);
            }
            // ~100 ms release. The split layout limits each side on its own.
            MixState& state = *mix.state;
            const float release = 1.0f - std::exp(-1.0f / (0.1f * float(busRate_)));
            const float blockPeak = Limit(acc, frames, !mix.split, kLimit, release, state.limiter);
            float* slot = out + mix.slot * 2;
            for (uint32_t i = 0; i < frames; i++) {
                slot[i * channels] = acc[i * 2];
                slot[i * channels + 1] = acc[i * 2 + 1];
            }
            state.peak.store(std::max(state.peak.load(std::memory_order_relaxed), blockPeak),
                std::memory_order_relaxed);
            const uint64_t at = state.written.load(std::memory_order_relaxed);
            for (uint32_t i = 0; i < frames; i++) {
                const size_t h = size_t((at + i) % kHistoryFrames) * 2;
                state.history[h] = acc[i * 2];
                state.history[h + 1] = acc[i * 2 + 1];
            }
            state.written.store(at + frames, std::memory_order_release);
            if (monitorSlot_.load(std::memory_order_relaxed) == int(mix.slot)) {
                monitor_->Feed(acc, frames);
            }
        }
    }
    cycles_.fetch_add(1, std::memory_order_release);
}

void Engine::StartCheck(const std::string& mixID, bool live)
{
    __block std::string id = mixID;
    dispatch_async(queue_, ^{
        if (shuttingDown_) {
            return;
        }
        StopCheckOnQueue();
        auto state = mixStates_.find(id);
        if (state == mixStates_.end()) {
            return;
        }
        // A check only ever plays what was said after it started.
        state->second->checkFrom.store(state->second->written.load());
        checking_ = id;
        Reconcile();
        if (!live || !busRunning_) {
            return;
        }
        for (const auto& mix : config_.mixes) {
            if (mix.id == id && monitor_->Start(busRate_, busFrames_)) {
                monitorSlot_ = int(mix.slot);
            }
        }
    });
}

void Engine::StopCheck()
{
    dispatch_async(queue_, ^{
        if (!shuttingDown_) {
            StopCheckOnQueue();
            Reconcile();
        }
    });
}

void Engine::StopCheckOnQueue()
{
    monitorSlot_ = -1;
    monitor_->Stop();
    checking_.clear();
}

size_t Engine::CopyCheck(const std::string& mixID, float* stereo, size_t maxFrames)
{
    std::shared_ptr<MixState> state;
    {
        std::lock_guard lock(snapshotMutex_);
        for (const auto& mix : snapshot_.mixes) {
            if (mix.id == mixID) {
                state = mix.state;
            }
        }
    }
    if (!state) {
        return 0;
    }
    const uint64_t end = state->written.load(std::memory_order_acquire);
    uint64_t from = state->checkFrom.load(std::memory_order_acquire);
    from = std::max<uint64_t>(from, end > kHistoryFrames ? end - kHistoryFrames : 0);
    const size_t n = size_t(std::min<uint64_t>(end - from, maxFrames));
    for (size_t i = 0; i < n; i++) {
        const size_t h = size_t((from + i) % kHistoryFrames) * 2;
        stereo[i * 2] = state->history[h];
        stereo[i * 2 + 1] = state->history[h + 1];
    }
    return n;
}

bool Engine::SetProbes(const std::string& json, std::string& error)
{
    std::vector<std::pair<std::string, std::optional<std::string>>> wanted;
    try {
        for (const auto& item : nlohmann::json::parse(json)) {
            std::optional<std::string> instance;
            if (item.contains("instance") && item["instance"].is_string()) {
                instance = item["instance"].get<std::string>();
            }
            wanted.emplace_back(item.at("bundleID").get<std::string>(), instance);
        }
    } catch (const std::exception& e) {
        error = e.what();
        return false;
    }
    __block auto moved = std::move(wanted);
    dispatch_async(queue_, ^{
        if (shuttingDown_) {
            return;
        }
        for (auto& probe : probes_) {
            probe->Stop();
        }
        probes_.clear();
        Retire retire = [this](std::function<void()> fn) { RetireLater(std::move(fn)); };
        for (auto& [bundleID, instance] : moved) {
            auto probe = std::make_shared<AppSource>(bundleID, instance, retire);
            probe->Start(48000, 256);
            probes_.push_back(probe);
        }
        PublishSnapshot();
    });
    return true;
}

std::vector<float> Engine::ProbeLevels()
{
    std::vector<std::shared_ptr<AppSource>> probes;
    {
        std::lock_guard lock(snapshotMutex_);
        probes = snapshot_.probes;
    }
    std::vector<float> levels;
    for (auto& probe : probes) {
        levels.push_back(probe->TakeProducedPeak());
    }
    return levels;
}

void Engine::MuteProbe(size_t index, bool muted)
{
    dispatch_async(queue_, ^{
        if (!shuttingDown_ && index < probes_.size()) {
            probes_[index]->SetMuted(muted);
        }
    });
}

std::vector<Engine::MixStatus> Engine::Status()
{
    Snapshot snapshot;
    {
        std::lock_guard lock(snapshotMutex_);
        snapshot = snapshot_;
    }
    // A source shared by several mixes reports one peak to all of them.
    std::map<Source*, float> peaks;
    std::vector<MixStatus> result;
    for (const auto& mix : snapshot.mixes) {
        MixStatus status;
        status.id = mix.id;
        status.deviceReady = mix.deviceReady;
        status.running = mix.running;
        status.users = mix.users;
        if (mix.state) {
            status.peak = mix.state->peak.exchange(0, std::memory_order_relaxed);
        }
        for (const auto& source : mix.sources) {
            status.sourceLive.push_back(source && source->Live());
            if (!source) {
                status.sourcePeaks.push_back(0);
                continue;
            }
            auto it = peaks.find(source.get());
            if (it == peaks.end()) {
                it = peaks.emplace(source.get(), source->TakePeak()).first;
            }
            status.sourcePeaks.push_back(it->second);
        }
        result.push_back(std::move(status));
    }
    return result;
}

std::string Engine::Diagnostics()
{
    __block std::string text;
    dispatch_sync(queue_, ^{
        std::ostringstream out;
        out << "bus " << (busRunning_ ? "running" : "stopped") << " rate " << busRate_
            << " frames " << busFrames_ << " cycles " << cycles_.load() << " sweep "
            << (sweep_->Running() ? "on" : "off") << " sweeps " << sweeps_ << "\n";
        for (const auto& [id, mix] : mixDevices_) {
            const bool split = std::any_of(config_.mixes.begin(), config_.mixes.end(),
                [&](const MixConfig& m) { return m.id == id && m.split; });
            out << "mix " << id << " device " << mix.device << (split ? " split" : "")
                << (mix.running ? " running" : "") << (checking_ == id ? " checking" : "");
            for (const auto& user : mix.users) {
                out << " used-by=\"" << user << "\"";
            }
            out << "\n";
        }
        if (monitorSlot_ >= 0) {
            auto stats = monitor_->GetStats();
            out << "monitor slot " << monitorSlot_.load() << " correction "
                << (stats.correction - 1) * 1e6 << "ppm underruns " << stats.underruns
                << " skips " << stats.skips << " overflows " << stats.overflows << "\n";
        }
        for (const auto& [key, source] : sources_) {
            auto stats = source->GetStats();
            out << "source " << key << (source->Live() ? " live" : " idle") << " rate "
                << stats.sourceRate << " correction " << (stats.correction - 1) * 1e6
                << "ppm underruns " << stats.underruns << " skips " << stats.skips
                << " overflows " << stats.overflows << source->Detail() << "\n";
        }
        text = out.str();
    });
    return text;
}

} // namespace blend
