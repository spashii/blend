# How Blend works

Blend has three parts:

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
- The app sets the list of mixes, `[{id, name, slot}]`, through a custom property (`'bmxs'`) on the plug-in object. The driver saves the list in coreaudiod's storage, so mixes exist at boot with the same IDs (`app.blend.mix.<id>`), and apps keep their selection while Blend is closed. They get silence then.
- Frames the engine did not write read as silence. A stopped or crashed engine gives silence within one buffer, never a loop of stale audio.
- Device list changes are coalesced to at most one per 250 ms, because bursts of adds and removes hung coreaudiod in testing.
- A deleted mix that an app still reads is silenced at once, refuses new IO, and is removed from the device list only after its IO stops. Removing a device during IO also hung coreaudiod.
- Saving the list goes through coreaudiod, so a save waits a second after the last change, runs on its own queue, and happens only when the list changed.
- Each mix device lists the clients running IO on it in a custom property (`'BLus'`). The engine turns their process IDs into app names for "Used by".

## Engine

- A source is an input device, captured with an IOProc on that device; an app, captured with a Core Audio process tap of every process the app owns; or system audio, a global tap that excludes Blend and every app copy reading that mix (from the driver's client list), updated as readers come and go. A tap sits in a private aggregate device clocked by the default output.
- Each source writes into a lock-free ring at its own clock and rate. The bus thread reads every ring through a variable-ratio polyphase resampler (32 taps, 256 phases, Kaiser window), steered by a proportional controller on the ring's fill level with a 2 second time constant, clamped to ±0.5%. This is the approach of PipeWire and JACK's `alsa_in`.
- The mixing graph (sources, and the gains of each mix) is swapped with one atomic pointer, and the old graph is freed after the bus thread has moved past it. The bus thread never allocates or locks. Gain changes ramp over one buffer, so sliders never click.
- Every mix ends in a peak limiter at -1 dBFS. A mix of two sources can be split: the first source, folded to mono, goes to the left channel only and the second to the right only, and the limiter then works on each channel on its own (`engine/src/MixMath.hpp`). Blend describes every mix for other apps in `devices.json` ([MIXES-FOR-APPS.md](MIXES-FOR-APPS.md)).
- A source runs only while an app reads a mix that uses it, or while a mix is being checked. The orange microphone dot and the purple app audio dot in the menu bar mean real use.
- While no app reads a mix and no mix is being checked, nothing in Blend runs on a timer, whether or not its windows are open. The engine's 100 ms sweep runs only with the bus, and the app reads the engine's status every 100 ms only while levels can move. Otherwise it reads when a view opens and when the engine reports a change, such as a mix device's "running somewhere" property.
- After coreaudiod restarts, the engine rebuilds everything from the configuration. A device that reconnects or changes rate (AirPods switching to their call mode) is captured again, and a source that fails to start is retried every 2 seconds.
- Each mix keeps its last 6 seconds in memory for checking on speakers: Blend records 5 seconds and then plays them back, because listening live through speakers would feed back into the microphone. On headphones it plays the mix live.

## Microphone processing

- A microphone source can have echo cancellation and voice isolation, each set per source. Two mixes that use the same microphone with the same settings share one capture and one processing chain (`engine/src/MicProcessor.hpp`).
- Echo cancellation is WebRTC's AEC3 from the [freedesktop.org package](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing), the same canceller Chrome uses. Its reference is a tap of everything the Mac plays except Blend itself, captured in one private aggregate device together with the microphone, so both arrive in the same IO cycle. Blend is left out because its own output carries the mixes, which contain the microphone.
- Voice isolation is Apple's AUSoundIsolation audio unit, run after echo cancellation, with the standard or the High Quality Voice model.
- Both run on the microphone's capture thread in 10 ms blocks. If a stage fails (a sample rate AEC3 refuses, say), it is skipped and the microphone goes on unprocessed rather than silent.

## Telling copies of an app apart

One app is many processes. Browsers play sound from a helper process, and WebKit from its GPU process. A process is attributed to the app copy that owns it by walking up its parent processes, then by asking macOS which process is responsible for it.

Copies of one app are told apart by the folders they were launched with, such as Firefox's `--profile DIR` or Chromium's `--user-data-dir=DIR`. Documents, URLs and switches are ignored. The rule names no apps (`engine/src/Identity.hpp`), and `engine/tests/IdentityTests.cpp` checks it against recorded process inventories.

Limits: a browser copy is captured whole, every tab together. Two profiles opened inside one running Chromium copy share its processes and cannot be split.

## App

- Each mix is a JSON file in `~/Library/Application Support/Blend/Mixes`, with a schema version and a `.bak` of the previous version.
- Every change sends the whole configuration to the engine as JSON (`engine/src/Config.hpp`), and the engine works out what changed.
- Blend.app carries the driver in `Contents/PlugIns`. Setup copies it into `/Library/Audio/Plug-Ins/HAL` after an administrator prompt, then restarts coreaudiod so it loads.

## Choices and what was ruled out

- **An own driver rather than BlackHole.** BlackHole has a fixed set of devices, needs Audio MIDI Setup to combine sources, and is GPL-3.
- **An audio server plug-in rather than DriverKit.** Apple's guidance is that virtual devices should be audio server plug-ins.
- **Process taps rather than ScreenCaptureKit.** Taps capture one app's audio and need only the System Audio Recording permission, not Screen Recording.
- **One capture loop per source rather than one aggregate device.** AirPods drop to 24 kHz when their microphone opens, which would break an aggregate for every source at once.
- **Not Apple's voice processing unit for echo cancellation.** It ducks other audio and has cut other call apps off the microphone.
- **Not muting a call app and replaying its audio for echo cancellation.** The call app's own processing then ducks the replay, and its own echo canceller breaks.

## Measured behaviour

- Latency from a microphone into a mix to the mix's device: 29.9 ms median (29.5 to 30.1 ms from the 10th to the 90th percentile) with echo cancellation off, and 74.1 ms median with it on, so echo cancellation adds about 44 ms. Measured on Blend Mic 0.5.0 in a macOS 26 virtual machine: a click train played into BlackHole 2ch used as the mix's microphone, BlackHole and the mix recorded at the same time and cross-correlated, over 61 clicks. A hardware microphone's own converter latency is not included.
- Changing the microphone's sample rate during a mix leaves a silent gap of 100 to 125 ms at each change, with no crackle and no stuck device.

## Open questions

- Call apps run their own noise suppression on the microphone they get, and it may treat music in a mix as noise.
- No multi-hour soak with several clocks at once (a USB microphone, the built-in microphone and app taps) has been run yet.

[SPIKES.md](SPIKES.md) has the measurements behind these choices.
