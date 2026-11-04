#pragma once

// Which copy of an app a process belongs to, using only what macOS exposes for any app.
//
// Copies of one app differ by the folders they were launched with: a Firefox profile
// (--profile DIR), a Chromium or Electron data folder (--user-data-dir=DIR). Documents,
// URLs and plain switches do not make a copy distinct and are ignored. Copies launched the
// same way share an identity and are captured together, because nothing tells them apart.

#include <algorithm>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace blend {

// Folders named by args[1...], sorted and joined by newlines; empty for a plain launch.
inline std::string InstanceIdentity(const std::vector<std::string>& args,
    const std::function<bool(const std::string&)>& isDirectory, const std::string& bundlePath = "")
{
    std::vector<std::string> folders;
    for (size_t i = 1; i < args.size(); i++) {
        std::string value = args[i];
        if (value.rfind('-', 0) == 0) {
            const auto equals = value.find('=');
            if (equals == std::string::npos) {
                continue;
            }
            value = value.substr(equals + 1);
        }
        if (value.empty() || value[0] != '/') {
            continue;
        }
        while (value.size() > 1 && value.back() == '/') {
            value.pop_back();
        }
        if (!bundlePath.empty() && value.rfind(bundlePath, 0) == 0) {
            continue;
        }
        if (isDirectory(value)) {
            folders.push_back(value);
        }
    }
    std::sort(folders.begin(), folders.end());
    folders.erase(std::unique(folders.begin(), folders.end()), folders.end());
    std::string identity;
    for (const auto& folder : folders) {
        identity += (identity.empty() ? "" : "\n") + folder;
    }
    return identity;
}

// A short name for an identity: the last folder name, or empty for a plain launch.
inline std::string IdentityLabel(const std::string& identity)
{
    const auto line = identity.substr(0, identity.find('\n'));
    const auto slash = line.find_last_of('/');
    return slash == std::string::npos ? line : line.substr(slash + 1);
}

// The app copy an audio process works for: the process itself, the nearest ancestor that
// is a copy (Chromium's audio service, Firefox content processes), or the process macOS
// holds responsible for it (WebKit's GPU process). Returns 0 when none is a copy.
inline int OwnerOf(int pid, const std::function<bool(int)>& isCopy,
    const std::function<int(int)>& parentOf, const std::function<int(int)>& responsibleOf)
{
    for (int p = pid, depth = 0; p > 1 && depth < 8; p = parentOf(p), depth++) {
        if (isCopy(p)) {
            return p;
        }
    }
    const int responsible = responsibleOf(pid);
    return responsible > 1 && isCopy(responsible) ? responsible : 0;
}

} // namespace blend
