cask "blend" do
  version "0.3.0"
  sha256 "1299fc970a98b1fa9c705892e78bf15e2881a6eff2ccfe7263fd3516b5ab77dd"

  url "https://github.com/spashii/blend/releases/download/v#{version}/Blend-#{version}.dmg"
  name "Blend"
  desc "Mixes your microphone and app audio into virtual microphones"
  homepage "https://spashii.github.io/blend/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Blend.app"

  # The audio driver is installed by the app, so it is removed here, and the audio service
  # restarts with the AirPlay helper so the mixes disappear (see app/Blend/restart-audio.sh).
  uninstall quit:   "app.blend.Blend",
            script: {
              executable: "/bin/sh",
              args:       ["-c", "rm -rf /Library/Audio/Plug-Ins/HAL/BlendDriver.driver && killall coreaudiod AirPlayXPCHelper; true"],
              sudo:       true,
            }

  zap trash: [
    "~/Library/Application Support/Blend",
    "~/Library/Preferences/app.blend.Blend.plist",
  ]
end
