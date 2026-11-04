#!/bin/zsh
# Creates a self-signed code signing identity, "Blend Dev", in its own keychain, so
# development builds keep a stable signature and macOS keeps their privacy permissions
# across rebuilds. Run once as yourself: tools/dev-identity.sh
# Undo: security delete-keychain ~/Library/Keychains/blend-dev.keychain-db
set -euo pipefail
kc=$HOME/Library/Keychains/blend-dev.keychain-db
if [[ -f $kc ]]; then
  echo "Already there: $kc"
  security find-identity -p codesigning $kc
  exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf $dir' EXIT
cd $dir
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=Blend Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out blend.p12 -inkey key.pem -in cert.pem \
  -passout pass:blend-dev -name "Blend Dev"
security create-keychain -p blend-dev $kc
security set-keychain-settings $kc
security unlock-keychain -p blend-dev $kc
security import blend.p12 -k $kc -P blend-dev -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k blend-dev $kc >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') $kc
security find-identity -p codesigning $kc
