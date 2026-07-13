#!/bin/bash
# 常に /Applications/ScreenStore.app を起動する（Xcode の Debug ビルドと取り違えないため）
set -euo pipefail
APP="/Applications/ScreenStore.app"
BIN="$APP/Contents/MacOS/ScreenStore"
if [ ! -x "$BIN" ]; then
  echo "未インストールです。先に: ./tools/install.sh"
  exit 1
fi
pkill -x ScreenStore 2>/dev/null || true
sleep 0.5
echo "起動: $APP"
echo "更新日時: $(stat -f '%Sm' "$BIN")"
open -a "$APP"
