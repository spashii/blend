# Spike results

Measured on the MacBook Air M5, macOS 26.6.2, 3 to 4 Nov 2026. Each entry says what was run, what came out, and what it changed in the design.

## S1 Driver lifecycle: passed, after two driver changes

Run: `lab loop`, `lab stress`, `lab remove-live`, and killing the bus writer while another process records (`spikes/lab`).

- The bus-to-mix loopback is exact: 240,000 frames with zero discontinuities, and the mix reads each frame at the sample time it was written for (offset 0 in the same process). With the writer in another process the offset was a constant 512 frames (10.7 ms); not yet explained.
- Mixes appear live without restarting anything, renames show up while recording, UIDs and names survive a coreaudiod restart, and a killed writer gives silence within one buffer.
- **Bursts of device changes wedge coreaudiod.** About 25 add and remove cycles within one second hung it; SIGTERM no longer worked and only `kill -9` recovered it. At two changes a second, 100 cycles ran clean. The driver now coalesces changes (latest list wins, at most one device list change per 250 ms); the burst test then passed 100 cycles with no glitches and no silence on the recorded mix. New mixes appear about 320 ms after they are asked for.
- **Removing a device while an app records from it wedges coreaudiod**, the failure roc-vad reported. The driver now silences the mix at once, marks it dead, and removes it only after its IO stops (polled every 250 ms). Rerun: the reader got silence immediately, nothing hung, and the device disappeared 55 ms after the reader stopped. The reading app still saw `IsAlive = 1` a second later, so apps are not told to switch; the UI has to say "still used by …".
- Not run: reboot, sample rate changes.

## S3 App capture: passed for Firefox, Brave and QuickTime

Run: `lab procs`, `lab tap` with real playback.

- Firefox plays from one of its own `org.mozilla.firefox` processes; Brave from `com.brave.Browser.helper` (matches by bundle prefix and by responsible process); WebKit GPU processes report their host app as responsible (seen for Raycast and Ollama).
- Capture is isolated per app (tapping Slack while Firefox played gave pure silence) and level-exact (a -12.2 dBFS tone read -12.2 dBFS).
- A tap follows apps that start playing later: QuickTime and Brave were picked up within a second by updating the live tap's process list, with no restart and no gap in IO.
- The System Audio Recording permission was granted without a visible step; the first tap started in 0.1 s.
- Not run: Safari itself, Zoom, Discord, Teams.

## S4 Echo cancellation, far end only: passed

Run: `spikes/echo/session.sh` played speech then music at 25, 50 and 100% through the built-in speakers (system volume 69%) while `lab record-echo` captured the built-in mic and a global tap in one aggregate; `spikes/echo/aec` ran WebRTC AEC3 2.1 offline; `spikes/echo/score.py` scored it.

- The raw mic transcript contained the far-end sentence at all three volumes. After AEC3, none of the far-end words survived. A voice in the room ("How come?") survived in both.
- Echo removed once converged: about 20 to 25 dB with AEC3 alone, where the room noise floor limits the measure; 31 to 41 dB with WebRTC noise suppression added. Residual -50 to -54 dBFS, or -59 to -71 dBFS with suppression.
- Weak spots: the first 3 seconds while the filter adapts (5 dB), and quiet music (8 dB).
- AEC3 estimated the reference 4 ms ahead of the mic. Mic and tap in one aggregate are aligned well enough that Chrome's 170 ms extra capture delay is not needed.
- Not run: double talk and near-end-only takes, which need someone speaking.

## S6 Sound isolation: cheap, slower than expected, harmful for transcription with background voices

Run: four synthetic voices mixed with pink noise, babble, music and typing at 0 and 6 dB SNR (`spikes/isolation/make_mixes.py`), processed offline by `isolate`, transcribed by local Whisper large-v3.

- Cost about 1% of one core (render time / audio time 0.009 to 0.011).
- Latency 56.4 ms for the standard model and 92.5 ms for High Quality Voice, against the 33 and 50 ms estimated from the model configs.
- Word error rate, raw / standard 100% / high quality 100% / high quality 50%:
  - babble at 0 dB: 6.9 / 23.5 / 64.8 / 6.9
  - babble at 6 dB: 2.9 / 5.1 / 9.1 / 2.9
  - pink, music, keyboard: within 2 points of raw for all settings.
- Whisper alone is robust to these noises. Full-strength isolation garbles speech when other voices are as loud as the target, and High Quality is worse there.
- Design change: the Transcribe template defaults isolation off; the Call template uses standard isolation, since it is 36 ms faster than High Quality and less destructive with voices behind you.
- Caveat: synthetic voices; the SI-SDR column of `evaluate.py` is broken and was not used.

## Source identity: which copy of an app a source captures

Run: `spikes/identity/scenario.sh` starts two throwaway Firefox profiles playing 440 and 660 Hz, two Brave copies with their own data folders playing 550 and 330 Hz (plus a second profile inside one of them), and two plain TextEdit copies; `lab inventory` records every app copy and audio process with its launch arguments (`spikes/identity/data/inventory-1.json, with personal entries removed`); `engine/tests/IdentityTests.cpp` replays the rule over that record; `spikes/identity/proof.sh` and `spectrum.py` check real capture.

- What macOS exposes for any app is enough. Copies of one app differ by the folders they were launched with: Firefox's `--profile DIR`, Chromium's `--user-data-dir=DIR`. Documents, URLs and switches do not. The rule has no app names in it.
- Firefox: all 6 copies got distinct identities, including a copy launched with no folder (Firefox's default). Brave: both copies distinct; a second profile opened inside one copy joins that copy's process tree and cannot be split. TextEdit: two plain copies share one identity, because nothing distinguishes them.
- Audio is played by the copy itself (Firefox) or by a helper under it (Brave's audio service); the owner is found by walking up the parent chain, then the responsible process. Every test tone traced to the right copy.
- macOS still lists apps it terminated automatically to save memory; those are skipped by checking the process is alive.
- Proof: a mix bound to copy A carried 440 Hz at its exact level with every other tone at least 135 dB down; a control mix bound to copy B carried 660 Hz with the others at least 170 dB down; after A was killed and relaunched with the same arguments, the source found it again with the same result. An earlier run failed the control at 52 dB: the cause was Firefox restarting a 4 s `<audio loop>` with a phase jump, which smears energy around 660 Hz; each side of the jump measured -128 dB or lower. The tones are now 30 s and the checker splits at jumps.
- Not yet run: the same inventory and proof on a second Mac, and Zoom, Discord and Teams.
