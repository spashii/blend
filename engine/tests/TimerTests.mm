// Checks that Blend runs no timer while nothing is mixed: the sweep timer ticks only between
// Start and Stop, can stop itself from a tick, and an engine with nothing to mix has it off.
// The engine here is never given a configuration, so it never touches the driver or its
// mix list, and is safe to run beside a Blend in use.

#include "../src/RepeatingTimer.hpp"

#include "BlendEngine.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <thread>

namespace {

int failures = 0;
dispatch_queue_t queue;
// Touched only on the queue.
int ticks = 0;
std::unique_ptr<blend::RepeatingTimer> timer;

void Check(bool ok, const char* what, int value)
{
    std::printf("%s %s (%d)\n", ok ? "ok  " : "FAIL", what, value);
    failures += ok ? 0 : 1;
}

void Wait(int ms)
{
    std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

int Ticks()
{
    __block int now = 0;
    dispatch_sync(queue, ^{ now = ticks; });
    return now;
}

bool Running()
{
    __block bool now = false;
    dispatch_sync(queue, ^{ now = timer && timer->Running(); });
    return now;
}

} // namespace

int main()
{
    queue = dispatch_queue_create("app.blend.tests.timer", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(queue, ^{
        timer = std::make_unique<blend::RepeatingTimer>(queue, 50 * NSEC_PER_MSEC,
            5 * NSEC_PER_MSEC, ^{ ticks++; });
    });
    Wait(300);
    Check(Ticks() == 0 && !Running(), "a timer never started never ticks", Ticks());

    dispatch_sync(queue, ^{ timer->Start(); });
    Wait(330);
    const int started = Ticks();
    Check(started >= 3 && started <= 8 && Running(), "a started timer ticks every 50 ms", started);

    dispatch_sync(queue, ^{ timer->Stop(); });
    const int stopped = Ticks();
    Wait(300);
    Check(Ticks() == stopped && !Running(), "a stopped timer ticks no more", Ticks() - stopped);

    dispatch_sync(queue, ^{ timer->Start(); });
    Wait(200);
    Check(Ticks() > stopped, "a timer started again ticks again", Ticks() - stopped);
    dispatch_sync(queue, ^{ timer.reset(); });
    const int destroyed = Ticks();
    Wait(200);
    Check(Ticks() == destroyed, "destroying a running timer stops it", Ticks() - destroyed);

    // The engine stops its sweep from inside a tick when the bus stops there.
    dispatch_sync(queue, ^{
        ticks = 0;
        timer = std::make_unique<blend::RepeatingTimer>(queue, 30 * NSEC_PER_MSEC, 0, ^{
            if (++ticks == 3) {
                timer->Stop();
            }
        });
        timer->Start();
    });
    Wait(400);
    Check(Ticks() == 3 && !Running(), "a tick that stops its timer is the last", Ticks());
    dispatch_sync(queue, ^{ timer.reset(); });

    BlendEngine* engine = BlendEngineCreate();
    Wait(300);
    char* text = BlendEngineDiagnostics(engine);
    const bool quiet = std::strstr(text, "bus stopped") && std::strstr(text, "sweep off sweeps 0");
    Check(quiet, "an engine with nothing to mix runs no sweep", 0);
    if (!quiet) {
        std::printf("%s", text);
    }
    std::free(text);
    BlendEngineDestroy(engine);

    return failures == 0 ? 0 : 1;
}
