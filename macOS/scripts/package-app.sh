#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Todo"
APP_BUNDLE="$MACOS_DIR/build/$APP_NAME.app"
BUILD_ROOT="${TODO_SCRATCH_PATH:-$MACOS_DIR/.build}"
CONFIGURATION="${TODO_CONFIGURATION:-debug}"
SIGNING_IDENTITY="${TODO_CODESIGN_IDENTITY:--}"

# The default is ad-hoc signing: no Apple Developer ID, certificate, or paid
# developer membership is required. A named identity may be supplied for local
# development, but release artifacts are produced by package-release.sh with '-'.

swift build --package-path "$MACOS_DIR" --scratch-path "$BUILD_ROOT" -c "$CONFIGURATION"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_ROOT/$CONFIGURATION/TodoDesktop" "$APP_BUNDLE/Contents/MacOS/TodoDesktop"
cp -R "$BUILD_ROOT/$CONFIGURATION/TodoDesktop_TodoDesktop.bundle" "$APP_BUNDLE/Contents/Resources/"
cp "$BUILD_ROOT/$CONFIGURATION/TodoDesktop_TodoDesktop.bundle/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/Todo.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>TodoDesktop</string>
  <key>CFBundleIdentifier</key><string>com.todo.desktop</string>
  <key>CFBundleName</key><string>Todo</string>
  <key>CFBundleIconFile</key><string>Todo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# SwiftPM 生成的可执行文件默认使用 ad-hoc 签名。给完整 app bundle
# 重新签名并验证；ad-hoc 签名不代表 Developer ID 信任或 Apple 公证。
codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier com.todo.desktop "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "Created $APP_BUNDLE"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Signing: ad-hoc (no Apple Developer ID; not notarized)"
else
  echo "Signing identity: $SIGNING_IDENTITY"
fi
