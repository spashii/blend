cask "blend" do
  version "0.6.1"
  sha256 "f13493f8803bfee1fa93fea5088760bb39e76781f889ee1ab77e7caead0b9083"

  url "https://apps.idea2prod.in/blend/download/#{version}"
  name "Blend Mic"
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
