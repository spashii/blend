#pragma once

// The Blend engine: owns the sources, publishes the mix graph to the bus thread, and
// writes every mix into its slot on the driver's bus. Sources run only while some app is
// reading a mix that uses them, or while that mix is being checked, so the microphone and
// app-capture indicators mean real use.
//
// Threads: every change runs on a private serial queue, because HAL calls there can be
// slow. Callers never wait for that queue: Apply and the check and probe calls return at
// once, and Status, CopyCheck and ProbeLevels read a snapshot the queue publishes.
//
// Nothing runs on a timer while no mix is read or checked: the sweep runs only with the
// bus, and SetObserver tells the app when the snapshot changes, so it need not poll.

#include "Config.hpp"
#include "MixMath.hpp"
#include "RepeatingTimer.hpp"
#include "Sources.hpp"

#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace blend {

class Engine
{
public:
    Engine();
    ~Engine();

    // Replaces the whole configuration: driver mix devices, sources and gains. Parses
    // here and applies in the background.
    bool Apply(const std::string& json, std::string& error);

    struct MixStatus
    {
        std::string id;
        bool deviceReady = false;
        bool running = false;           // some other app is reading it
        std::vector<std::string> users; // names of the apps reading it
        float peak = 0;                 // since the previous call
        std::vector<float> sourcePeaks; // per source, in configuration order
        std::vector<bool> sourceLive;   // per source: capturing right now
    };
    std::vector<MixStatus> Status();

    // Called on the main queue after the snapshot Status reads changes: a mix starts or
    // stops being read or checked, its readers or device change, a source starts or stops.
    // Between those only the levels move, and only while a mix is read or checked. Changes
    // that land before the main queue runs are delivered once.
    void SetObserver(dispatch_block_t changed);

    // Human-readable state for tests and bug reports. Waits for the engine queue.
    std::string Diagnostics();

    // Runs one mix so it can be checked. With live, it also plays to the default output.
    // CopyCheck returns what the mix carried since the check started.
    void StartCheck(const std::string& mixID, bool live);
    void StopCheck();
    size_t CopyCheck(const std::string& mixID, float* stereo, size_t maxFrames);

    // Meters app copies for the source picker without mixing them: a JSON array of
    // {"bundleID", "instance"}. An empty array stops them.
    bool SetProbes(const std::string& json, std::string& error);
    std::vector<float> ProbeLevels();
    // Silences one probed copy's own output while muted, so a person hears which it is.
    void MuteProbe(size_t index, bool muted);

private:
    struct MixState
    {
        MixState();
        std::atomic<float> peak{0};
        LimiterState limiter; // bus thread only
        // Recent output, written by the bus thread; `written` counts frames ever written.
        std::vector<float> history;
        std::atomic<uint64_t> written{0};
        std::atomic<uint64_t> checkFrom{0};
    };

    struct MixPlan
    {
        std::string id;
        uint32_t slot = 0;
        float gain = 1;
        bool split = false;                            // see MixMath.hpp
        std::vector<uint32_t> sources;                 // index into Graph::sources
        std::vector<Route> routes;                     // per entry
        std::vector<float> targets;                    // linear gain per entry
        std::unique_ptr<std::atomic<float>[]> current; // ramped gain per entry
        std::shared_ptr<MixState> state;
    };

    struct Graph
    {
        std::vector<std::shared_ptr<Source>> sources;
        std::vector<MixPlan> mixes;
    };

    struct MixDevice
    {
        AudioObjectID device = kAudioObjectUnknown;
        bool running = false;
        std::vector<std::string> users;
        std::vector<int> userOwners; // the app copies reading it, by owner pid
        AudioObjectPropertyListenerBlock listener = nullptr;
    };

    // What callers read without waiting for the queue.
    struct Snapshot
    {
        struct Mix
        {
            std::string id;
            bool deviceReady = false;
            bool running = false;
            std::vector<std::string> users;
            std::shared_ptr<MixState> state;
            std::vector<std::shared_ptr<Source>> sources;
        };
        std::vector<Mix> mixes;
        std::vector<std::shared_ptr<AppSource>> probes;
    };

    // Queue only.
    void ApplyOnQueue(Config config);
    void PushMixesToDriver();
    void ResolveMixDevices();
    void Reconcile();
    void StartBus();
    void StopBus();
    void PublishGraph();
    void PublishSnapshot();
    void Notify();
    void RetireLater(std::function<void()> fn);
    void Sweep();
    void Recover();
    void RestartStaleSources();
    void StopCheckOnQueue();
    std::shared_ptr<Source> SourceFor(const SourceConfig& config);
    void AddSystemListeners();
    void RemoveSystemListeners();
    void RemoveMixListener(MixDevice& entry);
    static void ReadMixDevice(MixDevice& entry);
    void RetryFailedSources();
    void UpdateSystemExclusions();

    // Bus thread.
    static OSStatus BusProc(AudioObjectID, const AudioTimeStamp*, const AudioBufferList*,
        const AudioTimeStamp*, AudioBufferList* output, const AudioTimeStamp*, void* context);
    void Render(AudioBufferList* output);

    dispatch_queue_t queue_;
    // Retires old graphs, restarts stale sources and retries failed ones, all of which
    // concern a running bus, so it runs only between StartBus and StopBus.
    std::unique_ptr<RepeatingTimer> sweep_;
    dispatch_block_t observer_ = nullptr;
    // Outlives the engine, since a delivery already queued on the main queue holds it.
    std::shared_ptr<std::atomic<bool>> notifyPending_ = std::make_shared<std::atomic<bool>>(false);
    bool shuttingDown_ = false;
    // HAL listener blocks can be delivered after removal; they hold this token and check it
    // before touching the engine, which may be gone by then.
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
    Config config_;
    std::string pushedMixes_;
    std::map<std::string, std::shared_ptr<Source>> sources_;
    std::map<std::string, MixDevice> mixDevices_;
    std::map<std::string, std::shared_ptr<MixState>> mixStates_;
    std::vector<std::shared_ptr<AppSource>> probes_;
    std::string checking_;
    std::set<std::string> needed_; // sources some read or checked mix uses
    unsigned sweeps_ = 0;
    std::unique_ptr<MonitorOutput> monitor_;
    std::atomic<int> monitorSlot_{-1};

    std::mutex snapshotMutex_;
    Snapshot snapshot_;

    std::atomic<Graph*> graph_{nullptr};
    std::atomic<uint64_t> cycles_{0};
    std::vector<std::pair<uint64_t, std::function<void()>>> retiring_;

    AudioObjectID bus_ = kAudioObjectUnknown;
    AudioDeviceIOProcID busProc_ = nullptr;
    std::atomic<bool> busRunning_{false};
    double busRate_ = 48000;
    uint32_t busFrames_ = 256;
    std::vector<float> scratch_;
    std::vector<float> mixBuffer_;

    AudioObjectPropertyListenerBlock devicesListener_ = nullptr;
    AudioObjectPropertyListenerBlock outputListener_ = nullptr;
    AudioObjectPropertyListenerBlock processListener_ = nullptr;
    AudioObjectPropertyListenerBlock restartListener_ = nullptr;
};

} // namespace blend
