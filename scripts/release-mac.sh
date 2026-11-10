#!/bin/sh
# Builds the Mac app for release: archive, sign with Developer ID, have Apple
# notarise it, staple the ticket and wrap the result in a disk image.
#
#   scripts/release-mac.sh [output directory]
#
# Signing and notarisation go through the Apple ID that Xcode is signed in
# with, for the team in Config/Signing.xcconfig. Nothing is uploaded anywhere
# but Apple's notary service; publishing the disk image is a separate step.
set -eu

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.xcconfig | head -1)
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig first." >&2; exit 1; }
VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' Config/Base.xcconfig)

echo "Archiving OpenScreens $VERSION…"
xcodebuild archive \
    -project OpenScreens.xcodeproj -scheme OpenScreens -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -allowProvisioningUpdates -quiet

cat > "$WORK/upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
</dict>
</plist>
PLIST

echo "Sending to Apple's notary service…"
xcodebuild -exportArchive \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -exportOptionsPlist "$WORK/upload.plist" -exportPath "$WORK/upload" \
    -allowProvisioningUpdates

echo "Waiting for the notarised app…"
tries=0
until xcodebuild -exportNotarizedApp \
        -archivePath "$WORK/OpenScreens.xcarchive" -exportPath "$WORK/notarized" \
        -allowProvisioningUpdates >"$WORK/notarized.log" 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then
        cat "$WORK/notarized.log" >&2
        echo "Notarisation did not finish in half an hour." >&2
        exit 1
    fi
    sleep 30
done

APP="$WORK/notarized/OpenScreens.app"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "Building the disk image…"
mkdir -p "$OUT" "$WORK/dmg"
cp -R "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
DMG="$OUT/OpenScreens-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "OpenScreens" -srcfolder "$WORK/dmg" -fs APFS -format ULFO -quiet "$DMG"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Done: $DMG"
cat "$DMG.sha256"
