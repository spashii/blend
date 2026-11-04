#!/bin/zsh
# Reverts what Blend's development setup and spikes add to a Mac. Run once in Terminal:
#   sudo tools/dev-teardown.sh
# Keeps Xcode selected and its licence accepted, since other projects need that.
set -uo pipefail

if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
  echo "Run with sudo from your own account: sudo $0" >&2
  exit 1
fi

home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
repo=${0:A:h:h}
as_user() { sudo -u "$SUDO_USER" -H "$@"; }

# Driver, then restart the audio server so the devices disappear.
rm -rf /Library/Audio/Plug-Ins/HAL/BlendDriver.driver
sh "$repo/app/Blend/restart-audio.sh"

# Privacy grants given to the test app.
as_user tccutil reset Microphone app.blend.lab 2>/dev/null
as_user tccutil reset AudioCapture app.blend.lab 2>/dev/null

# Signing keychain made for development builds.
kc="$home/Library/Keychains/blend-dev.keychain-db"
if [[ -f "$kc" ]]; then
  as_user security delete-keychain "$kc"
fi

# Apps installed only for testing; listed in this file as they are added.
for cask in $(cat "$repo/tools/.test-casks" 2>/dev/null); do
  as_user /opt/homebrew/bin/brew uninstall --cask "$cask"
done

# The passwordless helper goes last.
rm -f /etc/sudoers.d/blend-dev /usr/local/libexec/blend-dev-driver

echo "Reverted. Build tools from the Brewfile stay; remove them with brew uninstall if unwanted."
