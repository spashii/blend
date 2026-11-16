#pragma once

// Running app copies and the audio processes they own, built on Identity.hpp's rule.

#include <string>
#include <vector>

namespace blend {

struct AppCopy
{
    std::string bundleID;
    std::string name;
    int pid = 0;
    std::string identity; // see InstanceIdentity; empty for a plain launch
    bool playing = false; // some process it owns is producing sound right now
    bool listening = false; // some process it owns is using a microphone right now
};

// Regular apps (the ones in the Dock) whose process is alive.
std::vector<AppCopy> RunningCopies();

// The copy that owns a process, or 0.
int OwnerPID(int pid);

// The copy identity of an app process; reads its launch arguments.
std::string CopyIdentity(int pid);

// The pids of the running copies of an app.
std::vector<int> CopiesOf(const std::string& bundleID);

// The apps a capture of everything the Mac plays leaves out besides its own process: Blend
// Mic, whose output carries its mixes, which hold the microphone.
const std::vector<std::string>& SystemAudioExclusions();
// The running copies of those apps, by pid.
std::vector<int> SystemAudioExcludedOwners();

// Bundle ID of a regular app process, or empty.
std::string AppBundleID(int pid);

// The name a person knows a regular app process by, or empty.
std::string AppName(int pid);

} // namespace blend
