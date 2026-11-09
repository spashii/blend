# Troubleshooting

When a source in use is not working, the Blend Mic icon in the menu bar shows a badge, and the panel names the source and the problem.

## A mix is silent

- **Blend Mic must be running.** Apps keep the mix as their microphone while Blend Mic is closed, but it carries only silence. Turn on **Open at login** in **Settings → General**.
- **The driver.** **Settings → General → Setup** shows whether the audio driver is installed. After an update that changes the driver, it asks to update it.
- **Permissions.** Microphones in a mix need the microphone permission, and apps or System audio need the permission for audio from other apps. **Settings → General → Setup** links to each one in System Settings.
- **A microphone gives no sound.** Blend Mic says "No sound. Check that it isn't muted." Check its mute switch or its input level in System Settings.
- **The mix or a source is muted** in the menu bar panel.

## An app hears itself

Blend Mic warns "(app) is also using this mix, so it hears itself" when an app is a source in a mix and has also picked that mix as its microphone. Remove the app from the mix, or pick another microphone in that app. System audio never causes this: it leaves out every app reading the mix.

## A source was disconnected

A microphone that is unplugged shows "Not connected", and an app that quit shows "Not open". Blend Mic picks the source up again when it comes back, without touching the mix. A microphone that changes its sample rate, as AirPods do when their microphone opens, leaves a gap of about a tenth of a second.

## The purple dot

macOS shows a purple dot in the menu bar while an app's audio is captured. Blend Mic causes it only while a mix that captures an app or System audio is in use or being checked, and while echo cancellation runs for a microphone in use. The orange dot means a microphone is in use, under the same rule.

Still stuck? Choose **Report an Issue…** in the menu bar panel. It opens a GitHub issue with the app and macOS versions filled in.
