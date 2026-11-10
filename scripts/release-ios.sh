#!/bin/sh
# Builds the iPhone and iPad app and uploads it to App Store Connect, where
# it becomes available to TestFlight testers once Apple has processed it.
#
#   scripts/release-ios.sh
#
# Signing and the upload go through the Apple ID that Xcode is signed in
# with, for the team in Config/Signing.xcconfig. The app record has to exist
# in App Store Connect already.
set -eu

cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.xcconfig | head -1)
[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig first." >&2; exit 1; }

echo "Archiving…"
xcodebuild archive \
    -project OpenScreens.xcodeproj -scheme "OpenScreens iOS" -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -allowProvisioningUpdates -quiet

cat > "$WORK/upload.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM</string>
    <key>manageAppVersionAndBuildNumber</key><true/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive \
    -archivePath "$WORK/OpenScreens.xcarchive" \
    -exportOptionsPlist "$WORK/upload.plist" -exportPath "$WORK/upload" \
    -allowProvisioningUpdates

echo "Uploaded. The build appears in TestFlight once Apple has processed it."
