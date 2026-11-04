#!/bin/zsh
# Builds the driver, engine and app on a Mac: tools/build.sh [--install-driver]
#
# Signs with the "Blend Dev" identity from tools/dev-identity.sh when it exists, so macOS
# keeps the microphone and app audio permissions across rebuilds; ad hoc otherwise, which
# asks for them again after every build. --install-driver uses the passwordless helper
# from tools/dev-setup.sh; without it, install the driver from Blend's Setup page.
set -euo pipefail
root=${0:A:h:h}
cd $root
version=$(<VERSION)

identity=-
keychain=
kc=~/Library/Keychains/blend-dev.keychain-db
if [[ -f $kc ]]; then
  security unlock-keychain -p blend-dev $kc
  identity="Blend Dev"
  keychain=$kc
fi

cmake -S . -B build -G Ninja -DBLEND_CODESIGN_ID="$identity" -DBLEND_KEYCHAIN="$keychain" >/dev/null
cmake --build build
(cd app && xcodegen generate --quiet)
xcodebuild -project app/Blend.xcodeproj -scheme Blend -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath build/app -quiet \
  MARKETING_VERSION=$version CODE_SIGN_IDENTITY="$identity" \
  ${keychain:+OTHER_CODE_SIGN_FLAGS=--keychain $keychain} build
echo "app: $root/build/app/Build/Products/Debug/Blend.app"
if [[ ${1:-} == --install-driver ]]; then
  sudo -n /usr/local/libexec/blend-dev-driver install
fi
