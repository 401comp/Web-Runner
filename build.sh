#!/bin/bash
# Build & package Web-Runner as a Catalina-compatible .app, .dmg, and ZIP.
#
# IMPORTANT: this app uses Swift async/await, whose runtime
# (libswift_Concurrency.dylib) ships only in macOS 12+. To run on the
# 10.15 deployment target we must bundle the back-deploy copy of that
# dylib and point an rpath at it -- otherwise the app launches and then
# dies the moment it touches async code. That step lives in embed_concurrency().

set -euo pipefail

APP_NAME="Web-Runner"
APP_VERSION="1.1.14"
BUNDLE_ID="com.saltz.webrunner"
EXEC_NAME="WebRunner"            # binary name from Package.swift target
ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"
ZIP="$DIST/${APP_NAME}-${APP_VERSION}-macos.zip"

# Back-deploy concurrency runtime shipped with the command line tools.
BACKDEPLOY_DYLIB="/Library/Developer/CommandLineTools/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib"

# Universal (x86_64+arm64) builds need full Xcode; with only Command Line
# Tools we build for the host arch. Set UNIVERSAL=1 on an Xcode machine.
echo "==> Compiling (release)…"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    ARCH_FLAGS=(--arch x86_64 --arch arm64)
else
    ARCH_FLAGS=()
fi
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --package-path "$ROOT"
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --package-path "$ROOT" --show-bin-path)/$EXEC_NAME"

echo "==> Assembling $APP …"
# Stash the current icon so rm -rf doesn't discard it between builds.
ICON_CACHE="$DIST/AppIcon.icns"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && cp "$APP/Contents/Resources/AppIcon.icns" "$ICON_CACHE" || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"
[ -f "$ICON_CACHE" ] && cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns" || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>         <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleExecutable</key>      <string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>  <string>10.15</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSAppTransportSecurity</key>  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

embed_concurrency() {
    echo "==> Embedding libswift_Concurrency (Catalina back-deploy)…"
    if [ ! -f "$BACKDEPLOY_DYLIB" ]; then
        echo "!! $BACKDEPLOY_DYLIB not found -- app will crash on macOS < 12" >&2
        return 1
    fi
    cp "$BACKDEPLOY_DYLIB" "$APP/Contents/Frameworks/"
    # Point an rpath at the bundled copy. dyld walks rpaths in order and
    # falls through /usr/lib/swift (no concurrency dylib on Catalina) to here.
    if ! otool -l "$APP/Contents/MacOS/$EXEC_NAME" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$EXEC_NAME"
    fi
}
embed_concurrency

echo "==> Signing (ad-hoc)…"
codesign --force -s - "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
codesign --force -s - "$APP"
codesign --verify --deep "$APP" && echo "   signature OK"

echo "==> Building DMG…"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Building ZIP…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Done."
echo "   App: $APP"
echo "   DMG: $DMG"
echo "   ZIP: $ZIP"
