#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_ROOT="$PROJECT_ROOT/dist"
SERIOUS_APP="$OUTPUT_ROOT/答题悬浮计时器.app"
MODULE_CACHE="${TMPDIR:-/private/tmp}/floating-quiz-timer-swift-cache"

build_app_bundle() {
  local app_path="$1"
  mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
}

rm -rf "$SERIOUS_APP"
mkdir -p "$OUTPUT_ROOT" "$MODULE_CACHE"

build_app_bundle "$SERIOUS_APP"
xcrun swiftc \
  -target arm64-apple-macos13.0 \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  "$PROJECT_ROOT/serious/Sources/main.swift" \
  -o "$SERIOUS_APP/Contents/MacOS/FloatingQuizTimer"
cp "$PROJECT_ROOT/serious/Info.plist" "$SERIOUS_APP/Contents/Info.plist"
cp "$PROJECT_ROOT/serious/Resources/AppIcon.icns" "$SERIOUS_APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --deep --sign - "$SERIOUS_APP"

/usr/bin/codesign --verify --deep --strict "$SERIOUS_APP"

print "构建完成：$OUTPUT_ROOT"
