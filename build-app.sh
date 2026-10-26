#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Desktop/AutoCursor.app"
LOCAL_APP="$(pwd)/AutoCursor.app"
STAGE_DIR="$(mktemp -d)"
STAGE="$STAGE_DIR/AutoCursor.app"
swift build -c release

if [ -d "$LOCAL_APP" ]; then
  rm -rf "$LOCAL_APP"
fi
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/autocursor "$STAGE/Contents/MacOS/autocursor"

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$STAGE/Contents/MacOS/autocursor" --export-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>AutoCursor</string>
	<key>CFBundleExecutable</key>
	<string>autocursor</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.autocursor</string>
	<key>CFBundleName</key>
	<string>AutoCursor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
rm -rf "$STAGE_DIR"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
