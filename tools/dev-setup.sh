#!/bin/zsh
# One-time development setup for Blend on a Mac. Run once in Terminal:
#   sudo tools/dev-setup.sh
#
# It points the command line tools at Xcode, accepts the Xcode licence, and
# installs a small root-owned helper plus a sudoers rule so the development
# driver can be installed and coreaudiod restarted without a password.
# Tradeoff: any process running as this user can then install an audio
# server plug-in from this checkout's build folder. Undo with:
#   sudo rm /etc/sudoers.d/blend-dev /usr/local/libexec/blend-dev-driver
set -euo pipefail

if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
  echo "Run with sudo from your own account: sudo $0" >&2
  exit 1
fi

repo=${0:A:h:h}

xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -license accept
xcodebuild -runFirstLaunch

install -d -o root -g wheel -m 755 /usr/local/libexec
helper=/usr/local/libexec/blend-dev-driver
{
  cat <<EOF
#!/bin/sh
# Installs or removes the Blend development driver, then restarts coreaudiod.
set -eu
src="$repo/build/driver/BlendDriver.driver"
dst=/Library/Audio/Plug-Ins/HAL/BlendDriver.driver
case "\${1:-}" in
  install)
    [ -d "\$src" ] || { echo "missing \$src" >&2; exit 1; }
    rm -rf "\$dst"
    ditto "\$src" "\$dst"
    chown -R root:wheel "\$dst"
    xattr -cr "\$dst" ;;
  remove) rm -rf "\$dst" ;;
  restart) ;;
  *) echo "usage: blend-dev-driver install|remove|restart" >&2; exit 2 ;;
esac
EOF
  # The same restart the app does, copied in so the helper never runs a file you can edit.
  cat "$repo/app/Blend/restart-audio.sh"
} > "$helper"
chown root:wheel "$helper"
chmod 755 "$helper"

rule=/etc/sudoers.d/blend-dev
echo "$SUDO_USER ALL=(root) NOPASSWD: $helper" > "$rule.tmp"
chmod 440 "$rule.tmp"
visudo -cf "$rule.tmp"
mv "$rule.tmp" "$rule"

echo "Done. Xcode: $(xcodebuild -version | head -1). Helper: $helper"
