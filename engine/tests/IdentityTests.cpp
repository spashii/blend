// Checks the copy identity rule against inventories recorded on real machines
// (spikes/identity/data/*.json, made by `lab inventory`). Directory checks use the facts
// recorded at capture time, so these tests run anywhere.
//
// usage: IdentityTests INVENTORY.json...

#include "../src/Identity.hpp"

#include <nlohmann/json.hpp>

#include <cstdio>
#include <fstream>
#include <map>
#include <set>
#include <string>

namespace {

int failures = 0;

void Check(bool ok, const std::string& what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

std::string Name(const std::string& path)
{
    auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

void TestInventory(const std::string& path)
{
    std::ifstream in(path);
    auto inventory = nlohmann::json::parse(in);

    struct Copy
    {
        std::string bundleID;
        std::string identity;
    };
    std::map<int, Copy> copies;
    std::map<std::string, std::set<std::string>> identities;
    std::map<std::string, int> liveCopies;
    for (const auto& app : inventory["apps"]) {
        if (!app.value("alive", true)) {
            continue; // macOS still lists apps it terminated automatically
        }
        std::set<std::string> dirs;
        for (const auto& d : app["directories"]) {
            dirs.insert(d.get<std::string>());
        }
        auto args = app["args"].get<std::vector<std::string>>();
        auto identity = blend::InstanceIdentity(args,
            [&](const std::string& p) { return dirs.count(p) > 0; },
            app.value("bundlePath", std::string()));
        const auto bundle = app["bundleID"].get<std::string>();
        copies[app["pid"].get<int>()] = {bundle, identity};
        identities[bundle].insert(identity);
        liveCopies[bundle]++;
    }

    // Every copy launched with its own folder is distinct; plain launches share one identity.
    for (const auto& [bundle, set] : identities) {
        if (liveCopies[bundle] < 2) {
            continue;
        }
        std::string labels;
        for (const auto& id : set) {
            labels += " [" + blend::IdentityLabel(id) + "]";
        }
        std::printf("     %s: %d copies, %zu identities:%s\n", bundle.c_str(), liveCopies[bundle],
            set.size(), labels.c_str());
    }
    auto count = [&](const std::string& b) { return identities.count(b) ? identities[b].size() : 0; };
    if (liveCopies.count("org.mozilla.firefox")) {
        Check(count("org.mozilla.firefox") == size_t(liveCopies["org.mozilla.firefox"]),
            "every Firefox copy has its own identity");
    }
    if (liveCopies.count("com.brave.Browser")) {
        Check(count("com.brave.Browser") == size_t(liveCopies["com.brave.Browser"]),
            "every Brave copy has its own identity");
    }
    if (liveCopies["com.apple.TextEdit"] > 1) {
        Check(count("com.apple.TextEdit") == 1, "plain TextEdit copies share one identity");
    }

    // Every playing test tone maps to the copy whose folder starts it.
    std::map<int, int> parent, responsible;
    for (const auto& p : inventory["audio"]) {
        parent[p["pid"].get<int>()] = p["parent"].get<int>();
        responsible[p["pid"].get<int>()] = p["responsible"].get<int>();
    }
    for (const auto& p : inventory["audio"]) {
        if (!p["playing"].get<bool>()) {
            continue;
        }
        const int pid = p["pid"].get<int>();
        const int owner = blend::OwnerOf(pid, [&](int q) { return copies.count(q) > 0; },
            [&](int q) { return parent.count(q) ? parent[q] : 1; },
            [&](int q) { return responsible.count(q) ? responsible[q] : -1; });
        const std::string label = owner ? blend::IdentityLabel(copies[owner].identity) : "";
        std::printf("     playing pid %d (%s) -> copy %d [%s]\n", pid,
            p["bundleID"].get<std::string>().c_str(), owner, label.c_str());
        if (label.rfind("ff-", 0) == 0 || label.rfind("brave-", 0) == 0) {
            Check(true, "test tone process owned by its copy " + label);
        } else if (p["args"].dump().find("/tmp/blend-identity/") != std::string::npos ||
                   p["bundleID"].get<std::string>().find("brave") != std::string::npos) {
            Check(false, "test tone process " + std::to_string(pid) + " owned by a test copy");
        }
    }
}

} // namespace

int main(int argc, char** argv)
{
    // Pure-function cases first.
    auto none = [](const std::string&) { return false; };
    auto all = [](const std::string&) { return true; };
    Check(blend::InstanceIdentity({"/a/firefox", "--profile", "/p/x"}, all) == "/p/x",
        "--profile DIR");
    Check(blend::InstanceIdentity({"/a/brave", "--user-data-dir=/d/y/"}, all) == "/d/y",
        "--flag=DIR, trailing slash dropped");
    Check(blend::InstanceIdentity({"/a/b", "file:///tmp/x.html", "https://x"}, all).empty(),
        "URLs ignored");
    Check(blend::InstanceIdentity({"/a/b", "/tmp/doc.txt"}, none).empty(), "files ignored");
    Check(blend::InstanceIdentity({"/A.app/Contents/MacOS/b", "/A.app/Contents/Resources"}, all,
              "/A.app")
              .empty(),
        "paths inside the app bundle ignored");
    Check(blend::IdentityLabel("/x/w1n8zt4e.Profile 3") == "w1n8zt4e.Profile 3", "label");

    for (int i = 1; i < argc; i++) {
        std::printf("inventory %s\n", Name(argv[i]).c_str());
        TestInventory(argv[i]);
    }
    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
