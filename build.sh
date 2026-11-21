#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/AppSweep.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos14.0 Sources/*.swift -o $APP/Contents/MacOS/AppSweep
cp Resources/Info.plist $APP/Contents/
# icon
swift make_icon.swift build/icon.png
ICONSET=build/AppIcon.iconset; mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
codesign --force --deep -s - $APP
echo "Built $APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ditto -c -k --keepParent $APP build/AppSweep-$VERSION.zip
echo "Packaged build/AppSweep-$VERSION.zip"
