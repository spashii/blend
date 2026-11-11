// The configuration the app sends: ducking is off unless asked for, and never applies to a
// split mix. Portable; builds and runs on Linux and macOS.

#include "../src/Config.hpp"

#include <cstdio>
#include <string>

namespace {

int failures = 0;

bool Duck(const std::string& mixFields, const std::string& sources)
{
    blend::Config config;
    std::string error;
    const std::string json = R"({"mixes":[{"id":"m","slot":0)" + mixFields
        + R"(,"sources":[)" + sources + "]}]}";
    if (!blend::ParseConfig(json, config, error)) {
        std::printf("FAIL parse: %s\n", error.c_str());
        failures++;
        return false;
    }
    return config.mixes[0].duck;
}

void Expect(bool actual, bool expected, const char* what)
{
    std::printf("%s %s\n", actual == expected ? "ok  " : "FAIL", what);
    failures += actual == expected ? 0 : 1;
}

} // namespace

int main()
{
    const std::string mic = R"({"id":"a","kind":"device","uid":"mic"})";
    const std::string app = R"({"id":"b","kind":"app","bundleID":"x.y"})";
    const std::string system = R"({"id":"c","kind":"system"})";
    Expect(Duck("", mic + "," + app), false, "off by default");
    Expect(Duck(R"(,"duck":true)", mic + "," + app), true, "on when asked");
    Expect(Duck(R"(,"duck":true)", mic + "," + app + "," + system), true, "three sources");
    Expect(Duck(R"(,"duck":true,"split":true)", mic + "," + app), false, "never on a split mix");
    Expect(Duck(R"(,"duck":true,"split":true)", mic + "," + app + "," + system), true,
        "split is ignored with three sources, so ducking stays");
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
