#!/bin/bash
set -euo pipefail
TASK_UID="$(id -u)"
launchctl bootout "gui/$TASK_UID/com.local.flipwall" 2>/dev/null || true
if [[ -x "$HOME/Applications/FlipWall.app/Contents/MacOS/FlipWall" ]]; then
  "$HOME/Applications/FlipWall.app/Contents/MacOS/FlipWall" --restore-desktop-wallpaper
fi
rm -f "$HOME/Library/LaunchAgents/com.local.flipwall.plist"
if [[ -d "$HOME/Applications/FlipWall.app" ]]; then
  rm -r "$HOME/Applications/FlipWall.app"
fi
printf 'FlipWall 后台启动项与已安装应用已移除。\n'
printf '素材缓存与设置保留在 ~/Library/Application Support/FlipWall。\n'
