#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_NAME="PhoneMirror"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
rm -rf "$CONTENTS_DIR/Resources"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/$APP_NAME" "$CONTENTS_DIR/MacOS/$APP_NAME"
chmod +x "$CONTENTS_DIR/MacOS/$APP_NAME"
if [[ ! -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  swift "$PROJECT_DIR/scripts/generate_icon.swift" "$PROJECT_DIR/Resources/AppIcon.icns"
fi
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$CONTENTS_DIR/Resources/THIRD_PARTY_NOTICES.md"
cp "$PROJECT_DIR/third_party/scrcpy-server-v4.0" "$CONTENTS_DIR/Resources/scrcpy-server-v4.0"
cp "$PROJECT_DIR/third_party/SCRCPY-LICENSE" "$CONTENTS_DIR/Resources/SCRCPY-LICENSE"
cp "$PROJECT_DIR/third_party/uitest_agent_v1.2.4.so" "$CONTENTS_DIR/Resources/uitest_agent_v1.2.4.so"
cp "$PROJECT_DIR/third_party/HDCTOOL-LICENSE" "$CONTENTS_DIR/Resources/HDCTOOL-LICENSE"
cp "$PROJECT_DIR/third_party/libscreen_casting.z.so" "$CONTENTS_DIR/Resources/libscreen_casting.z.so"
cp "$PROJECT_DIR/scripts/harmony_cast_bridge.py" "$CONTENTS_DIR/Resources/harmony_cast_bridge.py"
mkdir -p "$CONTENTS_DIR/Resources/runtime-settings-bridge"
javac --add-modules jdk.jdi \
  -d "$CONTENTS_DIR/Resources/runtime-settings-bridge" \
  "$PROJECT_DIR/tools/RuntimeSettingsBridge.java"
ditto "$PROJECT_DIR/third_party/harmony_python" "$CONTENTS_DIR/Resources/harmony_python"
cp "$PROJECT_DIR/third_party/GRPC-LICENSE" "$CONTENTS_DIR/Resources/GRPC-LICENSE"
cp "$PROJECT_DIR/third_party/PROTOBUF-LICENSE" "$CONTENTS_DIR/Resources/PROTOBUF-LICENSE"
sed "s/__EXECUTABLE__/$APP_NAME/g" "$PROJECT_DIR/Resources/Info.plist.template" > "$CONTENTS_DIR/Info.plist"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
