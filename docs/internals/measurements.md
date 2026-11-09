# Measurements

What was measured, what came out, and the constraint it put on the design. Unless an entry says otherwise, it was measured on a MacBook Air M5 with macOS 26.6.2, 3 to 4 Nov 2026. The scripts are in `spikes/`.

## Latency through a mix

- From a microphone into a mix to the mix's device: 29.9 ms median (29.5 to 30.1 ms from the 10th to the 90th percentile) with echo cancellation off, and 74.1 ms median with it on, so echo cancellation adds about 44 ms.
- Method: Blend Mic 0.5.0 in a macOS 26 virtual machine. A click train was played into BlackHole 2ch, used as the mix's microphone; BlackHole and the mix were recorded at the same time and cross-correlated over 61 clicks. A hardware microphone's own converter latency is not included.
- Changing the microphone's sample rate during a mix leaves a silent gap of 100 to 125 ms at each change, with no crackle and no stuck device.

## Driver lifecycle

Run: `lab loop`, `lab stress`, `lab remove-live`, and killing the bus writer while another process records (`spikes/lab`).

- The bus-to-mix loopback is exact: 240,000 frames with zero discontinuities, and the mix reads each frame at the sample time it was written for (offset 0 in the same process). With the writer in another process the offset was a constant 512 frames (10.7 ms); not yet explained.
- Mixes appear live without restarting anything, renames show up while recording, UIDs and names survive a coreaudiod restart, and a killed writer gives silence within one buffer.
- About 25 add and remove cycles within one second hang coreaudiod; SIGTERM no longer works and only `kill -9` recovers it. At two changes a second, 100 cycles run clean. With the driver coalescing changes (latest list wins, at most one device list change per 250 ms), the burst test passes 100 cycles with no glitches and no silence on the recorded mix. New mixes appear about 320 ms after they are asked for.
- Removing a device while an app records from it hangs coreaudiod, the failure roc-vad reported. With the driver silencing the mix at once and removing it only after its IO stops (polled every 250 ms), the reader gets silence immediately, nothing hangs, and the device disappears 55 ms after the reader stops. The reading app still sees `IsAlive = 1` a second later, so apps are not told to switch; the UI has to say which app still uses it.
- Rebooting with a mix in use passed (macOS 26 virtual machine).

## App capture

Run: `lab procs`, `lab tap` with real playback.

- Firefox plays from one of its own `org.mozilla.firefox` processes; Brave from `com.brave.Browser.helper` (matches by bundle prefix and by responsible process); WebKit GPU processes report their host app as responsible.
- Capture is isolated per app (tapping one silent app while Firefox played gave pure silence) and level-exact (a -12.2 dBFS tone read -12.2 dBFS).
- A tap follows apps that start playing later: QuickTime and Brave were picked up within a second by updating the live tap's process list, with no restart and no gap in IO.
- The System Audio Recording permission was granted without a visible step; the first tap started in 0.1 s.

## Call apps

- Zoom, in a macOS 26 virtual machine without an account: the mix is listed as a microphone, its level moves, and Zoom's microphone test plays the mix back. No call was made.
- Discord and Google Meet: passed in real calls on the owner's MacBook Air with a mix as the microphone, 9 Nov 2026.
- With echo cancellation on in a mix, a call app reading the same microphone directly gets it unchanged, bit for bit (macOS 26 virtual machine).
- Not run: Teams, Safari's own capture.

## Echo cancellation, far end only

Run: `spikes/echo/session.sh` played speech then music at 25, 50 and 100% through the built-in speakers (system volume 69%) while `lab record-echo` captured the built-in mic and a global tap in one aggregate; `spikes/echo/aec` ran WebRTC AEC3 2.1 offline; `spikes/echo/score.py` scored it.

- The raw mic transcript contained the far-end sentence at all three volumes. After AEC3, none of the far-end words survived. A voice in the room survived in both.
- Echo removed once converged: about 20 to 25 dB with AEC3 alone, where the room noise floor limits the measure; 31 to 41 dB with WebRTC noise suppression added. Residual -50 to -54 dBFS, or -59 to -71 dBFS with suppression.
- Weak spots: the first 3 seconds while the filter adapts (5 dB), and quiet music (8 dB).
- AEC3 estimated the reference 4 ms ahead of the mic. Mic and tap in one aggregate are aligned well enough that Chrome's 170 ms extra capture delay is not needed.
- Not run: double talk and near-end-only takes, which need someone speaking.

## Voice isolation

Run: four synthetic voices mixed with pink noise, babble, music and typing at 0 and 6 dB SNR (`spikes/isolation/make_mixes.py`), processed offline by `isolate`, transcribed by local Whisper large-v3.

- Cost about 1% of one core (render time / audio time 0.009 to 0.011).
- Latency 56.4 ms for the standard model and 92.5 ms for High Quality Voice, against the 33 and 50 ms estimated from the model configs.
- Word error rate, raw / standard 100% / high quality 100% / high quality 50%:
  - babble at 0 dB: 6.9 / 23.5 / 64.8 / 6.9
  - babble at 6 dB: 2.9 / 5.1 / 9.1 / 2.9
  - pink, music, keyboard: within 2 points of raw for all settings.
- Full-strength isolation garbles speech when other voices are as loud as the target, and High Quality is worse there. This is why isolation starts off.
- Caveat: synthetic voices; the SI-SDR column of `evaluate.py` is broken and was not used.

## Which copy of an app a source captures

Run: `spikes/identity/scenario.sh` starts two throwaway Firefox profiles playing 440 and 660 Hz, two Brave copies with their own data folders playing 550 and 330 Hz (plus a second profile inside one of them), and two plain TextEdit copies; `lab inventory` records every app copy and audio process with its launch arguments (`spikes/identity/data/inventory-1.json`, with personal entries removed); `engine/tests/IdentityTests.cpp` replays the rule over that record; `spikes/identity/proof.sh` and `spectrum.py` check real capture.

- What macOS exposes for any app is enough. Copies of one app differ by the folders they were launched with: Firefox's `--profile DIR`, Chromium's `--user-data-dir=DIR`. Documents, URLs and switches do not.
- Firefox: all 6 copies got distinct identities, including a copy launched with no folder (Firefox's default). Brave: both copies distinct; a second profile opened inside one copy joins that copy's process tree and cannot be split. TextEdit: two plain copies share one identity, because nothing distinguishes them.
- Audio is played by the copy itself (Firefox) or by a helper under it (Brave's audio service). Every test tone traced to the right copy.
- macOS still lists apps it terminated automatically to save memory; those are skipped by checking the process is alive.
- Proof: a mix bound to copy A carried 440 Hz at its exact level with every other tone at least 135 dB down; a control mix bound to copy B carried 660 Hz with the others at least 170 dB down; after A was killed and relaunched with the same arguments, the source found it again with the same result.
- Trap: Firefox restarts a short `<audio loop>` with a phase jump, which smears energy across the spectrum and fails the control at about 52 dB. The test tones are 30 s long and the checker splits at jumps.
- Not run: the same inventory and proof on a second Mac.
