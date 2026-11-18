#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")" && pwd)"
TASK_TARGET="$HOME/Applications/FlipWall.app"
TASK_STAGE="$HOME/Applications/.FlipWall-staging.app"
TASK_BACKUP="$HOME/Applications/.FlipWall-previous.app"
TASK_AGENT="$HOME/Library/LaunchAgents/com.local.flipwall.plist"
TASK_LOGS="$HOME/Library/Logs/FlipWall"
TASK_UID="$(id -u)"
TASK_SAVER_SOURCE="$TASK_ROOT/ScreenSaver/FlipWall.saver"
if [[ ! -x "$TASK_ROOT/FlipWall.app/Contents/MacOS/FlipWall" ]]; then
  printf 'Missing FlipWall.app. Run build.sh first.\n' >&2; exit 1
fi
launchctl bootout "gui/$TASK_UID/com.local.flipwall" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$TASK_LOGS"
if [[ -d "$TASK_STAGE" ]]; then rm -r "$TASK_STAGE"; fi
ditto "$TASK_ROOT/FlipWall.app" "$TASK_STAGE"
codesign --verify --deep --strict "$TASK_STAGE"
if [[ -d "$TASK_BACKUP" ]]; then rm -r "$TASK_BACKUP"; fi
if [[ -d "$TASK_TARGET" ]]; then mv "$TASK_TARGET" "$TASK_BACKUP"; fi
mv "$TASK_STAGE" "$TASK_TARGET"
python3 - "$TASK_TARGET" "$TASK_AGENT" "$TASK_LOGS" <<'PY'
import plistlib,sys,pathlib
app,agent,logs=sys.argv[1:]
value={'Label':'com.local.flipwall','ProgramArguments':[app+'/Contents/MacOS/FlipWall'],
       'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':15,
       'LimitLoadToSessionType':'Aqua','ProcessType':'Interactive',
       'StandardOutPath':logs+'/stdout.log','StandardErrorPath':logs+'/stderr.log'}
pathlib.Path(agent).write_bytes(plistlib.dumps(value))
PY
launchctl bootstrap "gui/$TASK_UID" "$TASK_AGENT"
if [[ -d "$TASK_SAVER_SOURCE" ]]; then
  TASK_SAVERS="$HOME/Library/Screen Savers"
  mkdir -p "$TASK_SAVERS"
  TASK_SAVER_STAGE="$(mktemp -d "$TASK_SAVERS/.FlipWall-stage.XXXXXX")"
  trap 'rm -r "$TASK_SAVER_STAGE"' EXIT
  ditto "$TASK_SAVER_SOURCE" "$TASK_SAVER_STAGE/FlipWall.saver"
  codesign --verify --strict "$TASK_SAVER_STAGE/FlipWall.saver"
  python3 - "$TASK_SAVER_STAGE/FlipWall.saver" "$TASK_SAVERS/FlipWall.saver" <<'PY'
import ctypes, os, sys
staged, installed = sys.argv[1:]
if os.path.lexists(installed):
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    if rename(os.fsencode(staged), os.fsencode(installed), 2) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), installed)
else:
    os.rename(staged, installed)
PY
fi
printf 'FlipWall 已启动，并设为登录启动。菜单栏可暂停或退出。\n'
printf '如 macOS 提示后台项目，请在系统设置中允许 FlipWall。\n'
