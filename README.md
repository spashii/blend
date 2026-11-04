# Blend

Build your own microphone on your Mac.

Blend is a free, open source menu bar app for macOS that makes virtual microphones. In each one, called a mix, you choose what goes in (your microphones and the sound of other apps) and set a volume for each, like a volume mixer for your microphone. Any app that lets you pick a microphone can pick a mix: Discord, a call recorder, OBS, a website in your browser. Setup is one page, and a new mix asks only for a name and a microphone.

- **Music in a voice chat.** Your microphone and a music player, with the music turned down, picked as the input in Discord.
- **A recorder that hears the whole call.** Your microphone and the call app, picked as the input of a recording app.
- **A video or a demo in a call or a stream.** Your microphone and a browser or any other app, picked in a call app or OBS.
- **One mix for each app.** Several mixes can be in use at once, so Discord can use one while a recorder uses another.

## Features

- Up to 16 mixes, each a microphone with its own name. Several can be in use at once, in different apps.
- Sources: microphones and other input devices, and the sound of any app. When several copies of an app run, such as two Firefox profiles, each copy can be added on its own.
- Volume, mute and a level meter for every source, and mute and a level meter for every mix.
- Echo cancellation (WebRTC AEC3) and Apple's voice isolation, set per microphone.
- A check button: on headphones you hear the mix live; on speakers Blend records five seconds and plays them back.
- Shows which apps are using each mix. Warns when a source in use is disconnected or closed, when a microphone gives no sound, and when an app in a mix has also picked that mix as its microphone, so it would hear itself.
- A limiter at -1 dBFS on every mix, so loud sources don't clip.

## Requirements

A Mac with Apple silicon and macOS 15 or later.

## Install

1. Download `Blend-VERSION.dmg` from [Releases](../../releases), open it, and drag Blend to Applications. Or install it with Homebrew:

   ```sh
   brew tap spashii/blend https://github.com/spashii/blend
   brew trust spashii/blend
   brew install --cask blend
   ```

2. Open Blend. It is signed with a Developer ID and notarized, so macOS only asks whether to open an app downloaded from the internet. Click **Open**.
3. Blend opens to its Setup page. Go through the four steps:
   - **Install the audio driver.** This is what makes mixes appear as microphones. It asks for an administrator password once, and sound pauses for a moment while the Mac's audio restarts.
   - **Allow the microphone.**
   - **Allow audio from other apps.**
   - **Open at login.** Mixes are silent while Blend is closed, so this is worth turning on.

Blend updates itself: on its second launch it asks whether to check for updates automatically, and General has a Check for Updates button. Updates are signed, and Blend installs only ones signed with its own key. To build Blend from source, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Using Blend

1. **Make a mix** with the + button in the menu bar panel or the Blend window: give it a name and pick your microphone, or none.
2. **Pick the mix as the microphone** in the app you want to use it with.
3. **Add sources** in the Blend window. Apps are grouped into communication apps, browsers and other apps, with apps in a call listed first and a live meter on apps playing sound.
4. **Set the volumes** in the menu bar panel by expanding a mix, and **check** it with the headphones button.

Good to know:

- Call apps run their own noise suppression, which can treat music as noise. If music sounds choppy on the other end, turn that down in the call app: in Zoom, turn on "Original sound for musicians"; in Discord, turn off noise suppression.
- A browser is captured whole: every tab in that copy. Browser profiles can be added separately only when each runs as its own copy, as Firefox profiles do. Profiles opened from Chrome's profile menu share one copy and can't be split.
- With headphones you don't need echo cancellation and can turn it off for that microphone.
- Voice isolation adds about 60 ms of delay (90 ms on High quality) and can garble speech when other voices near you are as loud as yours. It starts off for every microphone you add; turn it on for a microphone in its mix.
- While a mix that captures an app is in use, macOS shows a purple dot in the menu bar. Echo cancellation shows it too, because it listens to what the Mac plays in order to remove it.

## Privacy

Blend works entirely on your Mac. It has no analytics and no accounts, and the only thing it fetches from the internet is the list of releases when it checks for updates (with [Sparkle](https://sparkle-project.org), sending nothing about you or your Mac). Your mixes are stored in `~/Library/Application Support/Blend`. Audio passes through memory only, and the recording made to check a mix is discarded after it plays.

Blend uses the microphone and other apps' audio only while an app is using a mix that needs them, while you check a mix, and (to show which apps are making sound) while you are choosing a source.

## Uninstall

In the Blend window, choose General and click **Uninstall Blend**. It removes the driver, your mixes and Blend's settings, then moves Blend to the Trash. With Homebrew, `brew uninstall --zap --cask blend` does the same.

To do it by hand:

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlendDriver.driver
sudo killall coreaudiod AirPlayXPCHelper
rm -rf ~/Library/Application\ Support/Blend
```

Then move Blend to the Trash.

## How it works

Blend installs an audio server plug-in that adds one microphone per mix, plus one hidden device that Blend writes the mixes into, all on one clock. The app captures each source with Core Audio (an input device directly, an app with a process tap), cleans up microphones, brings every source onto the driver's clock with an adaptive resampler, and mixes them. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the details, and [docs/SPIKES.md](docs/SPIKES.md) the measurements behind them.

## License

MIT, see [LICENSE](LICENSE). Blend includes [libASPL](https://github.com/gavv/libASPL), [JSON for Modern C++](https://github.com/nlohmann/json), and [WebRTC audio processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) with [Abseil](https://github.com/abseil/abseil-cpp). Their licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgments

Blend learned from [BlackHole](https://github.com/ExistentialAudio/BlackHole), [Background Music](https://github.com/kyleneideck/BackgroundMusic), [roc-vad](https://github.com/roc-streaming/roc-vad) and [AudioCap](https://github.com/insidegui/AudioCap).
