#!/bin/zsh
# Builds Lumen.app with the Command Line Tools toolchain (no Xcode project needed).
set -e
cd "${0:A:h}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SDK=$DEVELOPER_DIR/SDKs/MacOSX26.sdk
APP=build/Lumen.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
$DEVELOPER_DIR/usr/bin/swiftc -O -parse-as-library -swift-version 5 -sdk $SDK \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI -framework MetalKit -framework IOKit -framework ServiceManagement \
  -import-objc-header Sources/Bridge.h -framework ScreenCaptureKit -framework CoreImage -framework ColorSync \
  Sources/*.swift -o $APP/Contents/MacOS/Lumen
cp Info.plist $APP/Contents/Info.plist
[ -f AppIcon.icns ] && cp AppIcon.icns $APP/Contents/Resources/
cp -R Resources/Fonts $APP/Contents/Resources/
codesign --force --sign - --identifier io.lumen.app $APP
echo "Built $APP"

# Standalone CLI (same sources, never launches the menu-bar UI)
$DEVELOPER_DIR/usr/bin/swiftc -O -parse-as-library -swift-version 5 -sdk $SDK -D LUMEN_CLI \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework SwiftUI -framework MetalKit -framework IOKit -framework ServiceManagement \
  -import-objc-header Sources/Bridge.h -framework ScreenCaptureKit -framework CoreImage -framework ColorSync \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
  Sources/*.swift -o build/lumen
codesign --force --sign - --identifier io.lumen.cli build/lumen
echo "Built build/lumen"
