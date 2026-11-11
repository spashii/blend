#pragma once

// The engine's whole desired state, sent by the app as JSON on every change:
//
// {"mixes": [{"id": "8c1e", "name": "Call", "slot": 0, "gainDb": 0, "muted": false,
//   "split": false, "duck": false,
//   "sources": [{"id": "s1", "kind": "device", "uid": "BuiltInMicrophoneDevice",
//                "gainDb": 0, "muted": false,
//                "processing": {"echoCancel": true, "isolation": "standard"}},
//               {"id": "s2", "kind": "app", "bundleID": "com.spotify.client",
//                "gainDb": -14, "muted": false},
//               {"id": "s3", "kind": "app", "bundleID": "org.mozilla.firefox",
//                "instance": "/Users/me/Library/Application Support/Firefox/Profiles/x"},
//               {"id": "s4", "kind": "system"}]}]}
//
// A "system" source is everything the Mac plays except Blend and the apps reading that
// mix. "split" applies only to a mix with exactly two sources: the first goes to the left
// channel only and the second to the right only (MixMath.hpp).

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace blend {

struct SourceConfig
{
    enum class Kind { Device, App, System };
    std::string id;
    Kind kind = Kind::Device;
    // For a system source: the mix whose readers it leaves out, so each mix has its own.
    std::string mixID;
    std::string uid;
    std::string bundleID;
    // One copy of an app, by its identity (Identity.hpp); unset means every copy.
    std::optional<std::string> instance;
    float gainDb = 0;
    bool muted = false;
    bool echoCancel = false;
    std::string isolation = "off";

    // Sources with the same key share one capture and one processing chain.
    std::string Key() const
    {
        if (kind == Kind::Device) {
            std::string key = "device:" + uid;
            if (echoCancel) {
                key += "+echo-cancel";
            }
            if (isolation == "standard" || isolation == "high") {
                key += "+isolation-" + isolation;
            }
            return key;
        }
        if (kind == Kind::System) {
            return "system:" + mixID;
        }
        return instance ? "app:" + bundleID + "#" + *instance : "app:" + bundleID;
    }
};

struct MixConfig
{
    std::string id;
    std::string name;
    uint32_t slot = 0;
    float gainDb = 0;
    bool muted = false;
    // Set only when the mix also has exactly two sources.
    bool split = false;
    // Lower the other sources while a physical microphone in the mix is talking (MixMath.hpp). Never
    // set on a split mix, which a recorder wants at full level.
    bool duck = false;
    std::vector<SourceConfig> sources;
};

struct Config
{
    std::vector<MixConfig> mixes;
};

bool ParseConfig(const std::string& json, Config& config, std::string& error);

} // namespace blend
