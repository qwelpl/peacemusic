#!/bin/bash
# Builds build/Peace.app. Pass --run to launch it afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

app="build/Peace.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PeaceMusic" "$app/Contents/MacOS/PeaceMusic"
cp Resources/Info.plist "$app/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# macOS remembers permissions like system audio access by signature. An ad-hoc signature
# changes with every build, so each build would be asked again. A local certificate,
# made once, keeps the signature the same.
identity="Peace Local Signing"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$identity" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 &&
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:peace >/dev/null 2>&1 &&
    security import "$tmp/id.p12" -P peace -T /usr/bin/codesign >/dev/null 2>&1 || true
    rm -rf "$tmp"
fi
codesign --force --sign "$identity" "$app" 2>/dev/null || codesign --force --sign - "$app"

echo "Built $app"
if [ "${1:-}" = "--run" ]; then
    open "$app"
fi
