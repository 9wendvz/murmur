#!/bin/zsh
# Builds Diary.app with the Xcode Command Line Tools (no Xcode needed).
set -e
cd "$(dirname "$0")"

APP="Diary.app"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

# Some Command Line Tools installs ship two identical SwiftBridging modulemaps,
# which breaks every import. Hide the stale one with a VFS overlay.
CLT_SWIFT_INC="/Library/Developer/CommandLineTools/usr/include/swift"
OVERLAY_ARGS=()
if [[ -f "$CLT_SWIFT_INC/module.modulemap" && -f "$CLT_SWIFT_INC/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "file", "name": "$CLT_SWIFT_INC/module.modulemap",
    "external-contents": "$(pwd)/build/empty.modulemap" } ] }
YAML
  OVERLAY_ARGS=(-vfsoverlay build/overlay.yaml -Xcc -ivfsoverlay -Xcc build/overlay.yaml)
fi

# UNIVERSAL=1 ./build.sh builds for both Apple silicon and Intel Macs (for releases).
ARCHS=(arm64)
[[ -n "$UNIVERSAL" ]] && ARCHS=(arm64 x86_64)
SLICES=()
for arch in "${ARCHS[@]}"; do
  /usr/bin/swiftc -O -swift-version 5 "${OVERLAY_ARGS[@]}" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target $arch-apple-macos14.0 \
    Sources/*.swift -o "build/Diary-$arch"
  SLICES+=("build/Diary-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/Diary"

# App icon, drawn by the app itself
"$APP/Contents/MacOS/Diary" --render-icon build/Diary.iconset
iconutil -c icns build/Diary.iconset -o "$APP/Contents/Resources/Diary.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Diary</string>
  <key>CFBundleDisplayName</key><string>Diary</string>
  <key>CFBundleIdentifier</key><string>local.diary.app</string>
  <key>CFBundleExecutable</key><string>Diary</string>
  <key>CFBundleIconFile</key><string>Diary</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Diary records voice memos and video sound for your entries.</string>
  <key>NSCameraUsageDescription</key><string>Diary takes photos and videos to attach to your entries.</string>
  <key>NSHumanReadableCopyright</key><string>my little mood diary</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
rm -rf build
echo "Built $(pwd)/$APP"
