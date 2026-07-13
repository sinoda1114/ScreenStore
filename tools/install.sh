#!/bin/bash
# ScreenStore を /Applications/ScreenStore.app に Release 配置するスクリプト。
#
# やること:
#   1. xcodebuild で Release 構成をビルド
#   2. /Applications/ScreenStore.app に上書きコピー
#   3. LaunchServices に再登録
#   4. 必要な場合だけ画面収録の TCC をリセット
#   5. SCShareableContent.current を呼んで TCC db に登録
#
# 使い方:
#   ./tools/install.sh
#   RESET_TCC=1 ./tools/install.sh   # 画面収録の許可状態を作り直したい場合のみ

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ScreenStore.app"
INSTALL_DIR="/Applications"
BUNDLE_ID="com.sinoda.ScreenStore"

cd "$REPO_DIR"

echo "==> [1/5] Release ビルド"
# 古い build.db が悪さをすることがあるので derivedDataPath は毎回 /tmp 側にまっさらに作る
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$(mktemp -d /tmp/screenstore-release-derived.XXXXXX)}"
rm -rf "$DERIVED_DATA_PATH"
mkdir -p "$DERIVED_DATA_PATH"

# xcodebuild は post-build 段階で軽微な I/O エラーを返すことがあるが、その時点で .app は
# 既に作られていることが多い。終了コードではなく成果物の存在で成否を判定する。
xcodebuild \
  -project ScreenStore.xcodeproj \
  -scheme ScreenStore \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build \
  >/tmp/screenstore-release-build.log 2>&1 || true

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME"
if [ ! -d "$BUILT_APP" ]; then
  echo "    Release ビルドに失敗。ログ末尾:"
  tail -20 /tmp/screenstore-release-build.log
  exit 1
fi

echo "==> [2/5] $INSTALL_DIR/$APP_NAME に配置"
# 走っていれば終わらせる
pkill -x ScreenStore 2>/dev/null || true
sleep 1
# 既存があれば削除
if [ -d "$INSTALL_DIR/$APP_NAME" ]; then
  rm -rf "$INSTALL_DIR/$APP_NAME"
fi
cp -R "$BUILT_APP" "$INSTALL_DIR/$APP_NAME"
TARGET="$INSTALL_DIR/$APP_NAME"

echo "==> [3/5] LaunchServices に再登録 + Dock キャッシュ更新"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  -f "$TARGET" >/dev/null 2>&1 || true
killall iconservicesagent 2>/dev/null || true
killall Dock 2>/dev/null || true

if [ "${RESET_TCC:-0}" = "1" ]; then
  echo "==> [4/5] TCC (画面収録) をリセット"
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
else
  echo "==> [4/5] TCC (画面収録) は維持"
fi

echo "==> [5/5] cdhash で TCC に再登録"
"$TARGET/Contents/MacOS/ScreenStore" --register-tcc >/dev/null 2>&1 &
REGPID=$!
sleep 4
ps -p $REGPID >/dev/null 2>&1 && kill $REGPID 2>/dev/null || true

echo
echo "完了:"
echo "  実体: $TARGET"
echo "  cdhash: $(codesign -dvvv "$TARGET" 2>&1 | grep '^CDHash=' | cut -d= -f2)"
echo
echo "次の操作（ビルド後の画面収録許可の作り直し）:"
echo "  1. 直後に開いたシステム設定 > 画面収録とシステムオーディオ録音 で ScreenStore を選び、下の「−」で削除"
echo "  2. 下の「＋」から /Applications/ScreenStore.app を追加"
echo "  3. ScreenStore のトグルが ON になっていることを確認"
echo "  4. ScreenStore を再起動"
echo
echo "補足:"
echo "  - トグル OFF → ON だけでは直らないことがあります"
echo "  - 次回以降、TCC 自体を初期化したい場合だけ RESET_TCC=1 を付けてください"

# ユーザーが追加し直しやすいよう、設定ペインと app 実体の両方を開く
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" >/dev/null 2>&1 || true
open -R "$TARGET" >/dev/null 2>&1 || true
