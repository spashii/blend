# Developing Blend

## Setup

You need a Mac with Apple silicon, macOS 15 or later, Xcode 16 or later, and [Homebrew](https://brew.sh).

```sh
brew bundle            # cmake, ninja, meson, xcodegen
tools/dev-identity.sh  # optional: a stable signing identity for development builds
```

Without `tools/dev-identity.sh`, builds are signed ad hoc, and macOS asks for the microphone and app audio permissions again after every build.

## Build and run

```sh
tools/build.sh
open build/app/Build/Products/Debug/Blend.app
```

`tools/build.sh` builds the driver and the engine with CMake, generates the Xcode project from `app/project.yml` with XcodeGen, and builds the app with the driver inside it. Install the driver from Blend's Setup page.

To install the driver without a password prompt on every change, run `sudo tools/dev-setup.sh` once. It installs a small root-owned helper and a sudoers rule for it, after which `tools/build.sh --install-driver` installs the freshly built driver and restarts coreaudiod. The tradeoff: any process running as you can then install that build folder's driver as root. `sudo tools/dev-teardown.sh` removes the helper, the rule, the driver and the development keychain.

## Tests

```sh
ctest --test-dir build --output-on-failure
```

- `engine/tests/DspTests.cpp`: the ring buffer, resampler quality, drift control, and recovery from backlog and stalls.
- `engine/tests/IdentityTests.cpp`: the rule that tells app copies apart, against recorded inventories in `spikes/identity/data/`.
- `engine/tests/ProcessingTests.mm`: echo cancellation and voice isolation on synthetic signals, through the calls the capture thread makes.

The pure C++ parts (the ring, the resampler, the source reader and the identity rule) also build and run on Linux.

`spikes/lab` builds Blend Lab, a command line tool for driver and capture tests that runs as an app so macOS attributes permissions to it. Run it through `spikes/lab/lab.sh`:

- `devices`, `mixes`, `mixes-set JSON`: list devices, read or set the driver's mix list.
- `record UID SECONDS [OUT.wav]`: record a device and report gaps.
- `loop`, `stress ITERATIONS [PAUSE_MS]`, `remove-live`: driver lifecycle tests.
- `engine CONFIG SECONDS [OUT.wav]`: run the engine with a configuration file and record the mix.

The other folders in `spikes/` hold the measurement scripts behind [SPIKES.md](SPIKES.md).

## Debugging

- Driver log: `log stream --predicate 'subsystem == "app.blend.driver"'`.
- If coreaudiod stops answering (every app's sound stops, System Settings shows no devices, or coreaudiod sits near 100% CPU): `sudo killall -9 coreaudiod AirPlayXPCHelper`, or `sudo /usr/local/libexec/blend-dev-driver restart`. Restarting coreaudiod alone, again and again, is what makes it stop answering: the AirPlay helper registers with each new coreaudiod twice as often as with the last. A Mac restart always clears it.

## Releases

```sh
tools/release.sh
```

It builds a Release configuration, runs the tests, and writes `build/release/Blend-VERSION.dmg`. Without a Developer ID the image is signed ad hoc, and people opening it need to approve it in System Settings once.

To sign and notarize, set up a Developer ID once per Mac:

1. Make a private key and certificate request: `openssl req -new -newkey rsa:2048 -nodes -keyout developer-id.key -out developer-id.csr -subj "/CN=Developer ID"`.
2. At developer.apple.com, under Certificates, create a "Developer ID Application" certificate (G2 Sub-CA) from the request, and download it. Only the team's Account Holder can.
3. `tools/release-identity.sh developer-id.key developerID_application.cer` puts both in a keychain of their own, which scripts and SSH sessions can unlock.
4. Make an app-specific password at account.apple.com, then run `tools/release-identity.sh --notary` in Terminal to save it as the notarytool profile.

From then on `tools/release.sh` signs with that identity and notarizes and staples both the app and the image. `BLEND_SIGN_ID` and `BLEND_NOTARY_PROFILE` use an identity and profile from your login keychain instead. Keep a password-protected copy of the private key somewhere safe: a Developer ID team can have only five certificates.

The version comes from `VERSION`. To publish, tag the commit and attach the image:

```sh
gh release create v$(<VERSION) build/release/Blend-$(<VERSION).dmg build/release/Blend-$(<VERSION).dmg.sha256
```

The website is `site/`, published to GitHub Pages by `.github/workflows/pages.yml` when it changes on main.
