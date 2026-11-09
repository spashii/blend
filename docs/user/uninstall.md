# Uninstall Blend Mic

In **Settings → General**, click **Uninstall Blend Mic…**. It removes the driver, your mixes, settings and caches, then moves Blend Mic to the Trash. Your mixes disappear from every app, and sound stops for a moment while the Mac's audio restarts.

With Homebrew:

```sh
brew uninstall --zap --cask blend
```

## By hand

```sh
sudo rm -rf /Library/Audio/Plug-Ins/HAL/BlendDriver.driver
sudo killall coreaudiod AirPlayXPCHelper
rm -rf ~/Library/Application\ Support/Blend
```

Then move Blend Mic to the Trash.

## Login Items

If **Open at login** was on, macOS keeps a disabled Blend Mic entry in **System Settings → General → Login Items & Extensions**. No app can delete it. It does nothing once the app is gone.
