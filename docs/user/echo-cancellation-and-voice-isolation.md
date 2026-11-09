# Echo cancellation and voice isolation

Both are set per microphone, in **Settings → (your mix) → Sources**, under that microphone. A microphone used in two mixes can have different settings in each.

## Echo cancellation

Removes what your speakers play from the microphone, so the other side of an online call does not hear itself.

- It starts on for a physical microphone: built in, USB, Bluetooth and the like.
- It starts off for a virtual or aggregate input such as BlackHole. Those often carry what the Mac plays on purpose, and echo cancellation would erase it.
- It adds about 44 ms of delay.
- With headphones there is no echo to remove, so turn it off.

It listens to what the Mac plays in order to remove it, so it needs the permission for audio from other apps, and macOS shows the purple dot in the menu bar while it runs. Other apps that use the same microphone directly get it unchanged.

## Voice isolation

Apple's voice isolation keeps your voice and removes background sound. Choose **Off**, **Standard** or **High quality**.

- It starts off for every microphone.
- It adds about 56 ms of delay on Standard and 92 ms on High quality.
- It can garble speech when other voices near you are as loud as yours, and High quality is worse there.

If either one fails to start, the microphone goes on without it rather than going silent.
