#include "Apps.hpp"

#include "HAL.hpp"
#include "Identity.hpp"

#import <AppKit/AppKit.h>

#include <dlfcn.h>
#include <libproc.h>
#include <signal.h>
#include <sys/sysctl.h>

#include <cerrno>
#include <cstring>

namespace blend {

namespace {

std::vector<std::string> LaunchArguments(int pid)
{
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int)) {
        return {};
    }
    std::vector<char> buffer(size);
    if (sysctl(mib, 3, buffer.data(), &size, nullptr, 0) != 0) {
        return {};
    }
    int argc = 0;
    std::memcpy(&argc, buffer.data(), sizeof(argc));
    size_t at = sizeof(argc);
    while (at < size && buffer[at]) { // executable path
        at++;
    }
    while (at < size && !buffer[at]) {
        at++;
    }
    std::vector<std::string> args;
    while (int(args.size()) < argc && at < size) {
        std::string arg(&buffer[at]);
        at += arg.size() + 1;
        args.push_back(std::move(arg));
    }
    return args;
}

int ParentPID(int pid)
{
    proc_bsdinfo info = {};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) <= 0) {
        return 1;
    }
    return int(info.pbi_ppid);
}

// Private but long-standing: the app macOS holds responsible for a helper, such as a
// WebKit GPU process. Chromium relies on the same call.
int ResponsiblePID(int pid)
{
    using Fn = pid_t (*)(pid_t);
    static auto fn = reinterpret_cast<Fn>(
        dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"));
    return fn ? int(fn(pid_t(pid))) : -1;
}

bool Alive(int pid)
{
    return kill(pid, 0) == 0 || errno == EPERM;
}

NSRunningApplication* RegularApp(int pid)
{
    NSRunningApplication* app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid_t(pid)];
    return app.activationPolicy == NSApplicationActivationPolicyRegular ? app : nil;
}

std::string Identity(int pid, NSRunningApplication* app)
{
    const std::string bundlePath = app.bundleURL.path ? app.bundleURL.path.UTF8String : "";
    return InstanceIdentity(LaunchArguments(pid),
        [](const std::string& path) {
            BOOL isDirectory = NO;
            return [NSFileManager.defaultManager fileExistsAtPath:@(path.c_str())
                                                      isDirectory:&isDirectory] &&
                   isDirectory;
        },
        bundlePath);
}

} // namespace

int OwnerPID(int pid)
{
    return OwnerOf(pid, [](int p) { return RegularApp(p) != nil; }, ParentPID, ResponsiblePID);
}

std::string CopyIdentity(int pid)
{
    return Identity(pid, RegularApp(pid));
}

std::string AppBundleID(int pid)
{
    NSRunningApplication* app = RegularApp(pid);
    return app.bundleIdentifier ? app.bundleIdentifier.UTF8String : "";
}

std::string AppName(int pid)
{
    NSRunningApplication* app = RegularApp(pid);
    return app.localizedName ? app.localizedName.UTF8String : "";
}

std::vector<AppCopy> RunningCopies()
{
    std::vector<AppCopy> copies;
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications) {
        const int pid = app.processIdentifier;
        // macOS keeps listing apps it terminated automatically to save memory.
        if (app.activationPolicy != NSApplicationActivationPolicyRegular || !app.bundleIdentifier ||
            !Alive(pid)) {
            continue;
        }
        AppCopy copy;
        copy.bundleID = app.bundleIdentifier.UTF8String;
        copy.name = app.localizedName ? app.localizedName.UTF8String : copy.bundleID;
        copy.pid = pid;
        copy.identity = Identity(pid, app);
        copies.push_back(std::move(copy));
    }
    for (AudioObjectID object : hal::GetArray<AudioObjectID>(kAudioObjectSystemObject,
             kAudioHardwarePropertyProcessObjectList)) {
        UInt32 output = 0;
        UInt32 input = 0;
        hal::Get(object, kAudioProcessPropertyIsRunningOutput, output);
        hal::Get(object, kAudioProcessPropertyIsRunningInput, input);
        if (!output && !input) {
            continue;
        }
        pid_t pid = -1;
        hal::Get(object, kAudioProcessPropertyPID, pid);
        const int owner = pid > 0 ? OwnerPID(pid) : 0;
        for (auto& copy : copies) {
            if (copy.pid == owner) {
                copy.playing = copy.playing || output;
                copy.listening = copy.listening || input;
            }
        }
    }
    return copies;
}

} // namespace blend
