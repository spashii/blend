#pragma once

// Meters app copies without capturing them for anything else, for a picker that shows which
// app is playing. Each probe is a process tap whose peak level is read on demand.

#include "ProcessTap.hpp"

#include <dispatch/dispatch.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace blend {

class Probes
{
public:
    struct Target
    {
        std::string bundleID;
        std::optional<std::string> instance;
    };

    // Taps are named "<label>: <bundle id>", which other apps' audio lists show.
    explicit Probes(std::string label);
    ~Probes();

    Probes(const Probes&) = delete;
    Probes& operator=(const Probes&) = delete;

    // Replaces the probed copies. An empty list stops metering. Blocks until the taps run;
    // one that cannot start reads as silence and is tried again when the process list
    // changes.
    void Set(std::vector<Target> targets);
    // Any thread: peak since the previous call for each probe, in the order given, 0 to 1.
    std::vector<float> Levels();
    // Silences one probed copy's own output while muted is true.
    void SetMuted(size_t index, bool muted);

private:
    struct Probe;

    void Refresh();

    const std::string label_;
    dispatch_queue_t queue_;
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<void> listener_;
    // Control queue.
    std::vector<std::shared_ptr<Probe>> probes_;
    std::mutex mutex_;
    // What Levels reads; replaced whole under the mutex.
    std::vector<std::shared_ptr<Probe>> published_;
};

} // namespace blend
