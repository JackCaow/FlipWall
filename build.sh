#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_APP="$TASK_ROOT/FlipWall.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -D FLIPWALL_DESKTOP \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework WebKit \
  "$TASK_ROOT/Sources/main.swift" "$TASK_ROOT/Sources/FeedUpdater.swift" \
  "$TASK_ROOT/Sources/LockScreenWallpaper.swift" "$TASK_ROOT/Shared/SaverGallery.swift" \
  -o "$TASK_APP/Contents/MacOS/FlipWall"
rm -r "$TASK_APP/Contents/Resources"
mkdir -p "$TASK_APP/Contents/Resources"
cp -R "$TASK_ROOT/Resources/." "$TASK_APP/Contents/Resources/"
cp "$TASK_ROOT/Info.plist" "$TASK_APP/Contents/Info.plist"
codesign --force --sign - "$TASK_APP"
printf 'Built: %s\n' "$TASK_APP"
