#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="$source_dir/FlipWall.saver"
if [[ $# -gt 0 ]]; then
  test -f "$1/Loop.mp4" && test -f "$1/Poster.jpg"
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 -O -emit-library \
  -framework ScreenSaver -framework AppKit -framework AVFoundation \
  "$source_dir/FlipWallSaverView.swift" "$source_dir/LiveSaverWall.swift" "$source_dir/../Shared/SaverGallery.swift" \
  -o "$bundle/Contents/MacOS/FlipWallSaver"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
rm -f "$bundle/Contents/Resources/Loop.mp4" "$bundle/Contents/Resources/Poster.jpg"
if [[ $# -gt 0 ]]; then
  cp "$1/Loop.mp4" "$1/Poster.jpg" "$bundle/Contents/Resources/"
fi
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
