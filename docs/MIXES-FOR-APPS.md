# Finding Blend's mixes from another app

Blend describes every mix in `~/Library/Application Support/Blend/devices.json`, so an app such as a call recorder can find a mix and know what each channel carries without guessing from names. Blend rewrites the file whenever a mix is added, removed, renamed, split or given other sources; volume and mute changes don't touch it. The file is absent until Blend has run once, and when Blend is uninstalled.

```json
{
  "mixes" : [
    {
      "deviceUID" : "app.blend.mix.8c1e2f3a",
      "id" : "8c1e2f3a",
      "name" : "Blend Mic",
      "sources" : [
        {
          "channel" : "left",
          "kind" : "device",
          "name" : "MacBook Air Microphone",
          "uid" : "BuiltInMicrophoneDevice"
        },
        {
          "channel" : "right",
          "kind" : "system",
          "name" : "System audio"
        }
      ],
      "split" : true
    }
  ],
  "version" : 1
}
```

- `deviceUID` is the Core Audio device UID of the mix's microphone (`kAudioDevicePropertyDeviceUID`). It stays the same for the life of the mix, through renames. Every mix device has two input channels at 48 kHz.
- `split` is true only when the mix has exactly two sources and Split by channel is on. Then the first source is on the left channel only and the second on the right only, each limited on its own, and `channel` says which is where. Otherwise every source is on both channels (`"channel": "both"`): record it as one channel.
- `kind` is `device` (a microphone or other input, with its `uid`), `app` (one app's sound, with its `bundleID`) or `system` (everything the Mac plays except Blend and the apps reading this mix).
- `name` is what the person named the source in Blend.
- Only the recorder should read a mix that carries System audio. An app reading the mix is left out of its System audio, so a call app set to use the mix as its microphone would be missing from the call side of the recording. Keep the call app on its usual microphone.
- A mix carries sound only while Blend is running. A reader that finds the device missing or silent should say that Blend isn't open rather than record silence.
- `version` changes only when an existing field changes meaning; new fields can appear at any time.
