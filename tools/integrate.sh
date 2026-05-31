#!/usr/bin/env bash
# tools/integrate.sh
#
# staged-sources/ScreenStore/ の中身を Xcode 自動生成の ScreenStore/ に統合するスクリプト。
# Xcode で File > New > Project から ScreenStore プロジェクトを作成した直後に 1 回だけ実行する。
#
# 何をするか:
#   1. staged-sources/ScreenStore/*.swift を ScreenStore/ にコピー (上書きあり)
#   2. staged-sources/ScreenStore/{Views,Models,Services,Utils}/ を ScreenStore/ にコピー
#   3. staged-sources/ScreenStore/Config/ScreenStore.entitlements を ScreenStore/ にコピー
#   4. 既存の ContentView.swift/ScreenStoreApp.swift を上書きすることに注意
#
# 統合後は Xcode で「Add Files to ScreenStore...」してフォルダ群を target に追加する必要あり。
# 詳細は SETUP.md を参照。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="${REPO_ROOT}/staged-sources/ScreenStore"
DEST_ROOT="${REPO_ROOT}/ScreenStore"

echo "==> ScreenStore staging integrator"
echo "    repo:   ${REPO_ROOT}"
echo "    src:    ${SRC_ROOT}"
echo "    dest:   ${DEST_ROOT}"

if [[ ! -d "${SRC_ROOT}" ]]; then
    echo "ERROR: staged-sources/ScreenStore/ が見つかりません: ${SRC_ROOT}" >&2
    exit 1
fi

if [[ ! -d "${DEST_ROOT}" ]]; then
    echo "ERROR: ScreenStore/ が見つかりません。先に Xcode でプロジェクトを作成してください: ${DEST_ROOT}" >&2
    echo "       手順は SETUP.md を参照。" >&2
    exit 1
fi

if [[ ! -e "${REPO_ROOT}/ScreenStore.xcodeproj" ]]; then
    echo "WARN: ScreenStore.xcodeproj が見つかりません。Xcode プロジェクトが正しく作成されているか確認してください。" >&2
fi

echo
echo "==> Swift ソースを上書きコピー"
cp -v "${SRC_ROOT}/ScreenStoreApp.swift" "${DEST_ROOT}/ScreenStoreApp.swift"
cp -v "${SRC_ROOT}/ContentView.swift"    "${DEST_ROOT}/ContentView.swift"

echo
echo "==> サブフォルダをコピー"
for sub in Models Views Services Utils; do
    if [[ -d "${SRC_ROOT}/${sub}" ]]; then
        mkdir -p "${DEST_ROOT}/${sub}"
        cp -Rv "${SRC_ROOT}/${sub}/." "${DEST_ROOT}/${sub}/"
    fi
done

echo
echo "==> Entitlements をコピー (既存があれば上書き)"
if [[ -f "${SRC_ROOT}/Config/ScreenStore.entitlements" ]]; then
    cp -v "${SRC_ROOT}/Config/ScreenStore.entitlements" "${DEST_ROOT}/ScreenStore.entitlements"
fi

cat <<'EOF'

==> 統合完了。

次の手順:
  1. Xcode で ScreenStore.xcodeproj を開く
  2. Project navigator の ScreenStore グループに、Finder からフォルダを追加:
       - ScreenStore/Models
       - ScreenStore/Views
       - ScreenStore/Services
       - ScreenStore/Utils
     ダイアログでは "Create groups" / "Add to targets: ScreenStore" を選ぶ
     (Copy items if needed のチェックは外す)
  3. Target > Signing & Capabilities で App Sandbox の capability を削除
  4. Target > Build Settings の "Code Signing Entitlements" が
     "ScreenStore/ScreenStore.entitlements" を指していることを確認
  5. Target > General で Minimum Deployments を macOS 14.0 に設定
  6. Target > Info に NSScreenCaptureUsageDescription を追加
       (内容は staged-sources/ScreenStore/Config/Info.plist.fragment.xml 参照)
  7. Cmd+R でビルド & 実行

詳細は SETUP.md を参照。
EOF
