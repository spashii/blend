# Updates

Blend Mic updates itself. On its second launch it asks whether to check for updates automatically. Change that later with **Check for updates automatically** in **Settings → General**.

To check now, choose **Check for Updates…** in the menu bar panel, or in **Settings → General**.

## When an update installs

With automatic checks on, an update downloads in the background and installs only when no app is using a mix and no mix is being checked. Blend Mic then quits, installs it and opens again, so no one loses sound in the middle of an online call.

Blend Mic installs only updates signed with its own key.

Most updates leave the audio driver alone. When one changes it, **Settings → General → Setup** asks to update the driver, which takes an administrator password and restarts the Mac's audio for a moment.

## Homebrew

Blend Mic updates itself when installed with Homebrew too. To update through Homebrew instead:

```sh
brew upgrade --cask blend
```
