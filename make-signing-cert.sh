#!/bin/bash
# Creates the self-signed "AeroFuzz Local Signing" identity in its own keychain (aerofuzz.keychain).
# Untrusted is fine: it only has to be stable, so macOS remembers the Screen Recording grant.
# A separate keychain with a known password lets build.sh sign without any password prompt.
set -euo pipefail
KC=~/Library/Keychains/aerofuzz.keychain-db
PW=aerofuzz
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; cd "$T"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=AeroFuzz Local Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:$PW
[[ -f $KC ]] || security create-keychain -p $PW $KC
security set-keychain-settings $KC                      # no auto-lock
security unlock-keychain -p $PW $KC
security import id.p12 -k $KC -P $PW -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW $KC >/dev/null
# Add to the search list so codesign can find it.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') $KC
