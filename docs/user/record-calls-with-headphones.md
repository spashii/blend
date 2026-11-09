# Record online calls

A recorder that reads a mix of your microphone and System audio gets both sides of an online call: your voice and everyone else. The call app itself keeps its usual microphone.

## Set it up

1. Click **+** in the menu bar panel. Pick your microphone and turn on **System audio**.
2. In the recorder, pick the new mix as its microphone.
3. In the call app, leave your normal microphone selected. Do not pick the mix there.

The mix carries sound only while Blend Mic is running. Turn on **Open at login** in **Settings → General** so a recording never comes out silent.

Tell the other side you're recording; consent rules depend on where they are.

## Split mode for recorders

A new mix of a microphone and System audio starts with **Split by channel** on: your voice on the left channel, the call on the right. A recorder that keeps channels apart can then tell who said what. Change it in **Settings → (your mix) → Sources → Split by channel**. The switch only appears when a mix has exactly two sources.

Apps that read only one channel hear only the first source of a split mix. That is why the call app should not read this mix.

## Why the call app keeps its own microphone

System audio leaves out every app that reads the mix, so a call never hears itself. If the call app read this mix too, it would be left out of System audio, and the other side would be missing from your recording.

## Headphones or speakers

With headphones, the microphone hears only you. You can turn **Echo cancellation** off for that microphone and save about 44 ms of delay.

On speakers, the microphone also picks up the call. Echo cancellation, on by default for built-in, USB and Bluetooth microphones, removes it so the call does not land on your channel too. See [Echo cancellation and voice isolation](./echo-cancellation-and-voice-isolation.md).
