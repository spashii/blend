#pragma once

// A repeating timer on a serial queue whose dispatch source exists only between Start and
// Stop, so a stopped timer schedules nothing and wakes nothing. Start, Stop and Running
// must be called on that queue; the tick may call Start and Stop itself. Objective-C++
// with ARC only, since the queue, the source and the tick are dispatch objects.

#include <dispatch/dispatch.h>

#include <cstdint>

namespace blend {

class RepeatingTimer
{
public:
    RepeatingTimer(dispatch_queue_t queue, uint64_t intervalNs, uint64_t leewayNs,
        dispatch_block_t tick)
        : queue_(queue)
        , interval_(intervalNs)
        , leeway_(leewayNs)
        , tick_(tick)
    {
    }

    ~RepeatingTimer() { Stop(); }

    RepeatingTimer(const RepeatingTimer&) = delete;
    RepeatingTimer& operator=(const RepeatingTimer&) = delete;

    void Start()
    {
        if (source_) {
            return;
        }
        source_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
        dispatch_source_set_timer(source_, dispatch_time(DISPATCH_TIME_NOW, int64_t(interval_)),
            interval_, leeway_);
        dispatch_source_set_event_handler(source_, tick_);
        dispatch_resume(source_);
    }

    // On the queue, no tick can be delivered after this returns. The tick block stays
    // alive here, so a tick that stops its own timer runs to its end.
    void Stop()
    {
        if (source_) {
            dispatch_source_cancel(source_);
            source_ = nullptr;
        }
    }

    bool Running() const { return source_ != nullptr; }

private:
    dispatch_queue_t queue_;
    uint64_t interval_;
    uint64_t leeway_;
    dispatch_block_t tick_;
    dispatch_source_t source_ = nullptr;
};

} // namespace blend
