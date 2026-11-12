# How Blend Mic works

Blend Mic has three parts:

- **Driver** (`driver/`, C++ on [libASPL](https://github.com/gavv/libASPL)): an audio server plug-in that runs inside macOS's audio server, coreaudiod.
- **Engine** (`engine/`, C++20 and Objective-C++): runs inside the app. It captures the sources, brings them onto one clock, mixes them, and writes each mix to the driver.
- **App** (`app/`, Swift 6 and SwiftUI): the menu bar panel and the settings window. It owns the mixes and sends them to the engine.

```
microphone ───────────────┐
other input device ───────┼─► engine ─► bus device (hidden) ─► one microphone per mix ─► other apps
app audio (process tap) ──┘
```

## Driver

- One hidden, output-only **bus** device with 32 channels, so 16 stereo slots, and one visible, input-only device per mix. Every device runs on one clock taken from the host clock at 48 kHz, so a mix reads exactly the frames the engine wrote for the same sample time. Nothing drifts and nothing is resampled inside the driver.
- The app sets the list of mixes, `[{id, name, slot}]`, through a custom property (`'bmxs'`) on the plug-in object. The driver saves the list in coreaudiod's storage, so mixes exist at boot with the same IDs (`app.blend.mix.<id>`), and apps keep their selection while the app is closed. They get silence then.
- Frames the engine did not write read as silence. A stopped or crashed engine gives silence within one buffer, never a loop of stale audio.
- Device list changes are coalesced to at most one per 250 ms. Bursts of adds and removes hang coreaudiod so that only `kill -9` recovers it.
- A deleted mix that an app still reads is silenced at once, refuses new IO, and is removed from the device list only after its IO stops. Removing a device during IO also hangs coreaudiod.
- Saving the list goes through coreaudiod, so a save waits a second after the last change, runs on its own queue, and happens only when the list changed.
- Each mix device lists the clients running IO on it in a custom property (`'BLus'`). The engine turns their process IDs into app names for "Used by".

## Engine

- A source is an input device, captured with an IOProc on that device; an app, captured with a Core Audio process tap of every process the app owns; or system audio, a global tap that excludes Blend Mic and every app copy reading that mix (from the driver's client list), updated as readers come and go. A tap sits in a private aggregate device clocked by the default output. The aggregate lists that device's own input channels before the tap's, so with a headset as the default output the tap is not channels 0 and 1; the engine counts the device's inputs and falls back to the last channels, counting the mismatch in diagnostics, when the buffers disagree.
- Each source writes into a lock-free ring at its own clock and rate. The bus thread reads every ring through a variable-ratio polyphase resampler (32 taps, 256 phases, Kaiser window), steered by a proportional controller on the ring's fill level with a 2 second time constant, clamped to ±0.5%. This is the approach of PipeWire and JACK's `alsa_in`.
- The mixing graph is swapped with one atomic pointer, and the old graph is freed after the bus thread has moved past it. The bus thread never allocates or locks. Gain changes ramp over one buffer, so sliders never click.
- Every mix ends in a peak limiter at -1 dBFS. A split mix puts the first source, folded to mono, on the left channel only and the second on the right only, and limits each channel on its own, so a loud call cannot pull the voice down ([`engine/src/MixMath.hpp`](../../engine/src/MixMath.hpp)). Other apps read the layout from `devices.json` ([mixes-for-apps.md](./mixes-for-apps.md)).
- A source runs only while an app reads a mix that uses it, or while a mix is being checked. The orange microphone dot and the purple app audio dot in the menu bar must mean real use.
- While no app reads a mix and no mix is being checked, nothing runs on a timer, whether or not a window is open, so an idle Blend Mic wakes the CPU for nothing. The app reads the engine's status on a timer only while levels can move, and otherwise when a view opens or the engine reports a change. `engine/tests/TimerTests.mm` and `app/BlendTests` hold this.
- After coreaudiod restarts, the engine rebuilds everything from the configuration. A device that reconnects or changes rate (AirPods switching to their call mode) is captured again, and a source that fails to start is retried every 2 seconds.
- Each mix keeps its last 6 seconds in memory for checking on speakers. Listening live through speakers would feed back into the microphone, so a check there records 5 seconds and plays them back.

## Microphone processing

- Echo cancellation and voice isolation are set per microphone source. Two mixes that use the same microphone with the same settings share one capture and one processing chain ([`engine/src/MicProcessor.hpp`](../../engine/src/MicProcessor.hpp)).
- Echo cancellation is WebRTC's AEC3 from the [freedesktop.org package](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing), the same canceller Chrome uses. Its reference is a tap of everything the Mac plays except Blend Mic itself, captured in one private aggregate device together with the microphone, so both arrive in the same IO cycle. Blend Mic is left out because its own output carries the mixes, which contain the microphone.
- A new source starts with echo cancellation on only for a microphone on a physical transport (built in, USB, Bluetooth and the like). A virtual or aggregate input such as BlackHole often carries what the Mac plays on purpose, and the canceller would erase it.
- Voice isolation is Apple's AUSoundIsolation audio unit, run after echo cancellation, with the standard or the High Quality Voice model. It starts off because it adds delay and harms speech when other voices are as loud as the speaker.
- Both run on the microphone's capture thread in 10 ms blocks. If a stage fails (a sample rate AEC3 refuses, say), it is skipped and the microphone goes on unprocessed rather than silent.

## BlendKit

BlendKit is the engine's capture code as a library, so another app can record an online call without Blend's driver. Blend Mic and Dictate depend on the same code, and it ships with Blend's releases.

- **Capture and mixing are separate.** The engine mixes: sources write into rings that the driver's bus clock reads. BlendKit only captures. `BKCallCapture` ([`engine/include/BlendKit.h`](../../engine/include/BlendKit.h)) opens the microphone and a tap of the call app's processes in one private aggregate device, so both arrive in the same IO cycle on one clock. It converts them to a fixed output rate and delivers 2-channel frames, Me and Call, on an ordinary queue. The host's callback never runs on an audio thread. Echo cancellation uses the call as its far end and cleans the microphone only.
- **Two APIs over one library.** The C interface (`BKCallCapture`, `BKProbes`, `BKVersion`) is the source of truth. The `BlendKit` Swift package ([`kit/Sources/BlendKit`](../../kit/Sources/BlendKit)) wraps it as `CallCapture`, `LevelProbes` and `AudioApps`. `BlendEngine.h`, the mixing interface, is in the same archive and unchanged.
- **Packaging.** CMake merges the engine and WebRTC into one static `libBlendKitCore.a`, wrapped as `BlendKitCore.xcframework`. Static, so it sits inside the host's own binary and signature. `kit/Package.swift` is the development package, which points at the local XCFramework. The `Package.swift` at the repository root is what other repositories resolve: it points the same targets at the XCFramework zip on the GitHub release, and `tools/release.sh` rewrites it with the zip's checksum. It is only valid at release tags and at the commit that pins the latest release. BlendKitCore has no product of its own, because SwiftPM would write a library over the XCFramework's; hosts reach it through `BlendKit`.
- **Versioning.** The version is Blend's `VERSION`, and the tag is `vX.Y.Z`. A change to the C interface or the Swift API needs a minor release. `BlendKit.version` reports the version the archive was built from.
- **How Dictate pins it.** Dictate depends on `https://github.com/spashii/blend` with `exact:` the release version. Its Xcode project and `Package.resolved` are generated, and a range could resolve differently when it releases. Raising the pin is a Dictate commit that follows a Blend release. Dictate's third-party notices list `BlendKit.thirdPartyComponents`, and a Dictate test fails when one is missing.

## Telling copies of an app apart

One app is many processes. Browsers play sound from a helper process, and WebKit from its GPU process. A process is attributed to the app copy that owns it by walking up its parent processes, then by asking macOS which process is responsible for it.

Copies of one app are told apart by the folders they were launched with, such as Firefox's `--profile DIR` or Chromium's `--user-data-dir=DIR`. Documents, URLs and switches are ignored. The rule names no apps ([`engine/src/Identity.hpp`](../../engine/src/Identity.hpp)), and `engine/tests/IdentityTests.cpp` checks it against recorded process inventories.

A browser copy is captured whole, every tab together. Two profiles opened inside one running Chromium copy share its processes and cannot be split.

## App

- Each mix is a JSON file in `~/Library/Application Support/Blend/Mixes`, with a schema version and a `.bak` of the previous version.
- Every change sends the whole configuration to the engine as JSON ([`engine/src/Config.hpp`](../../engine/src/Config.hpp)), and the engine works out what changed. Neither side keeps a diff protocol in sync.
- Blend.app carries the driver in `Contents/PlugIns`. Setup copies it into `/Library/Audio/Plug-Ins/HAL` after an administrator prompt, then restarts coreaudiod so it loads.

## Choices and what was ruled out

- **An own driver rather than BlackHole.** BlackHole has a fixed set of devices, needs Audio MIDI Setup to combine sources, and is GPL-3.
- **An audio server plug-in rather than DriverKit.** Apple's guidance is that virtual devices should be audio server plug-ins.
- **Process taps rather than ScreenCaptureKit.** Taps capture one app's audio and need only the System Audio Recording permission, not Screen Recording.
- **One capture loop per source rather than one aggregate device.** AirPods drop to 24 kHz when their microphone opens, which would break an aggregate for every source at once.
- **Not Apple's voice processing unit for echo cancellation.** It ducks other audio and has cut other call apps off the microphone.
- **Not muting a call app and replaying its audio for echo cancellation.** The call app's own processing then ducks the replay, and its own echo canceller breaks.

## Open questions

- Call apps run their own noise suppression on the microphone they get, and it may treat music in a mix as noise.
- No multi-hour soak with several clocks at once (a USB microphone, the built-in microphone and app taps) has been run yet.

Latency, the sample rate gap and the tests behind these choices are in [measurements.md](./measurements.md).
