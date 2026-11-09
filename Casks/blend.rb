cask "blend" do
  version "0.6.2"
  sha256 "2eb2189007251df15e824320a66996f5a99b620a3839f9f36465a420fe85470d"

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
