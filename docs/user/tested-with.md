# Tested with

What has been checked, how, and what has not. Blend Mic is a week old, so most of this comes from one Mac and one virtual machine.

## Call apps

| App | Result | How |
| --- | --- | --- |
| Zoom | Passed | In a macOS 26 virtual machine without an account: the mix is listed as a microphone, its level moves, and Zoom's microphone test plays the mix back. No call was made. |
| Discord | Passed | Real calls on the owner's Mac, with a mix as the microphone. |
| Google Meet | Passed | Real calls on the owner's Mac, with a mix as the microphone. |
| Microsoft Teams | Not tested | |

With echo cancellation on in a mix, a call app that reads the same microphone directly still gets it unchanged, bit for bit.

App capture was checked with Firefox, Brave and QuickTime: each captured on its own, at its exact level, including apps that start playing after the mix does.

## macOS and Macs

- macOS 26 on an Apple silicon MacBook Air, and in a macOS 26 virtual machine: install, uninstall, and a reboot with a mix in use all passed.
- macOS 15 is the minimum Blend Mic installs on, but it has not been tested.
- Intel Macs: not supported, and not tested.

## Delay

- **29.9 ms** from microphone to mix, median, with echo cancellation off (29.5 to 30.1 ms from the 10th to the 90th percentile).
- **74.1 ms** with echo cancellation on.
- Voice isolation adds about 56 ms on Standard and 92 ms on High quality.

Measured in a macOS 26 virtual machine by playing a click train into BlackHole used as the mix's microphone, recording BlackHole and the mix at the same time, and lining up 61 clicks. A real microphone's own converter delay comes on top.

## When a microphone changes sample rate

AirPods and some other microphones switch sample rate when they start or stop being used for calls. Each change leaves a silence of 75 to 126 ms in the mix, with no crackle, and the mix keeps working.

## Not tested yet

- Microsoft Teams, and other call apps not listed above.
- macOS 15.
- Hours of use with several microphones and apps on different clocks at once.
- Echo cancellation while both sides talk at once.
- Telling apart copies of an app on a second Mac.

The raw measurements are in [docs/internals/measurements.md](../internals/measurements.md).
