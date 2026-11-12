#include "Probes.hpp"

#include "HAL.hpp"

#include <algorithm>
#include <cmath>

namespace blend {

struct Probes::Probe : FrameSink
{
    Probe(Target target, const std::string& label)
        : tap(TapTarget{target.bundleID, target.instance, false}, label)
    {
    }
    ~Probe() { tap.Stop(); }

    // IO thread: a running maximum that the reader resets.
    void Raw(const AudioBufferList* input, routing::ChannelSpan span) override
    {
        float peak = 0;
        for (uint32_t index = span.first; span.count == 0 || index < span.first + span.count;
             index++) {
            const routing::Channel channel = routing::ChannelAt(input, index);
            if (!channel) {
                break;
            }
            for (uint32_t i = 0, n = routing::Frames(input); i < n; i++) {
                peak = std::max(peak, std::fabs(channel[i]));
            }
        }
        float seen = level.load(std::memory_order_relaxed);
        while (peak > seen &&
               !level.compare_exchange_weak(seen, peak, std::memory_order_relaxed)) {
        }
    }

    ProcessTap tap;
    std::atomic<float> level{0};
};

namespace {

struct Listener
{
    dispatch_queue_t queue;
    AudioObjectPropertyListenerBlock block;
    ~Listener()
    {
        auto address = hal::Address(kAudioHardwarePropertyProcessObjectList);
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, queue, block);
    }
};

} // namespace

Probes::Probes(std::string label)
    : label_(std::move(label))
{
    queue_ = dispatch_queue_create(("app.blend.kit." + label_ + ".probes").c_str(),
        DISPATCH_QUEUE_SERIAL);
}

Probes::~Probes()
{
    dispatch_sync(queue_, ^{
        alive_->store(false);
        listener_.reset();
        probes_.clear();
    });
    {
        std::lock_guard lock(mutex_);
        published_.clear();
    }
}

void Probes::Set(std::vector<Target> targets)
{
    __block auto wanted = std::move(targets);
    dispatch_sync(queue_, ^{
        probes_.clear();
        for (auto& target : wanted) {
            auto probe = std::make_shared<Probe>(target, label_);
            probe->tap.Start(*probe);
            probes_.push_back(probe);
        }
        {
            std::lock_guard lock(mutex_);
            published_ = probes_;
        }
        if (probes_.empty()) {
            listener_.reset();
        } else if (!listener_) {
            auto alive = alive_;
            auto listener = std::make_shared<Listener>();
            listener->queue = queue_;
            listener->block = ^(UInt32, const AudioObjectPropertyAddress*) {
                if (alive->load()) {
                    Refresh();
                }
            };
            auto address = hal::Address(kAudioHardwarePropertyProcessObjectList);
            AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, queue_,
                listener->block);
            listener_ = listener;
        }
    });
}

// A copy that starts playing after it was added has new processes for its tap to cover, and
// one whose tap failed gets another try.
void Probes::Refresh()
{
    for (auto& probe : probes_) {
        if (probe->tap.Running()) {
            probe->tap.RefreshProcesses();
        } else {
            probe->tap.Start(*probe);
        }
    }
}

std::vector<float> Probes::Levels()
{
    std::vector<std::shared_ptr<Probe>> probes;
    {
        std::lock_guard lock(mutex_);
        probes = published_;
    }
    std::vector<float> levels;
    for (auto& probe : probes) {
        levels.push_back(probe->level.exchange(0, std::memory_order_relaxed));
    }
    return levels;
}

void Probes::SetMuted(size_t index, bool muted)
{
    dispatch_async(queue_, ^{
        if (index < probes_.size()) {
            probes_[index]->tap.SetMuted(muted);
        }
    });
}

} // namespace blend
