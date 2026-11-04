#include "Config.hpp"

#include <nlohmann/json.hpp>

#include <set>

namespace blend {

bool ParseConfig(const std::string& text, Config& config, std::string& error)
{
    try {
        auto json = nlohmann::json::parse(text);
        Config parsed;
        std::set<uint32_t> slots;
        for (const auto& m : json.at("mixes")) {
            MixConfig mix;
            mix.id = m.at("id").get<std::string>();
            mix.name = m.value("name", mix.id);
            mix.slot = m.at("slot").get<uint32_t>();
            mix.gainDb = m.value("gainDb", 0.0f);
            mix.muted = m.value("muted", false);
            if (mix.slot >= 16 || !slots.insert(mix.slot).second) {
                error = "mix " + mix.id + " has a bad or duplicate slot";
                return false;
            }
            for (const auto& s : m.value("sources", nlohmann::json::array())) {
                SourceConfig source;
                source.id = s.at("id").get<std::string>();
                const std::string kind = s.at("kind").get<std::string>();
                if (kind == "device") {
                    source.kind = SourceConfig::Kind::Device;
                    source.uid = s.at("uid").get<std::string>();
                    // A Blend mic inside a mix would feed the bus back into itself.
                    if (source.uid.rfind("app.blend.", 0) == 0) {
                        continue;
                    }
                } else if (kind == "system") {
                    source.kind = SourceConfig::Kind::System;
                    source.mixID = mix.id;
                } else if (kind == "app") {
                    source.kind = SourceConfig::Kind::App;
                    source.bundleID = s.at("bundleID").get<std::string>();
                    if (s.contains("instance") && s["instance"].is_string()) {
                        source.instance = s["instance"].get<std::string>();
                    }
                } else {
                    error = "source " + source.id + " has unknown kind " + kind;
                    return false;
                }
                source.gainDb = s.value("gainDb", 0.0f);
                source.muted = s.value("muted", false);
                if (s.contains("processing")) {
                    const auto& p = s["processing"];
                    source.echoCancel = p.value("echoCancel", false);
                    source.isolation = p.value("isolation", std::string("off"));
                }
                mix.sources.push_back(std::move(source));
            }
            mix.split = m.value("split", false) && mix.sources.size() == 2;
            parsed.mixes.push_back(std::move(mix));
        }
        config = std::move(parsed);
        return true;
    } catch (const std::exception& e) {
        error = e.what();
        return false;
    }
}

} // namespace blend
