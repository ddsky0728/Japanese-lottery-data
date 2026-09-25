#!/bin/bash
# 抽せんデータの手動操作。scripts/install.sh がターミナルに次の 2 つを登録する。
#
#   loto-update   今すぐ取り込み・公開し、配信（GitHub Pages）に反映されたか確かめる
#   loto-status   いまの状態を確認する（何も変更しない）
#
# 直接呼ぶ場合:
#   bash scripts/loto.sh update
#   bash scripts/loto.sh status

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGES="https://ddsky0728.github.io/Japanese-lottery-data/loto"
LOG="$HOME/Library/Logs/loto-update.log"
LABEL="com.ddsky0728.loto-update"
PY=/usr/bin/python3
LOTTERIES=(loto6 loto7 miniloto)

# 標準入力の JSON から「最新の回 抽せん日」を返す
latest() {
  "$PY" -c 'import json,sys
try:
    d=json.load(sys.stdin); d.sort(key=lambda x:x["round"])
    print(d[-1]["round"], d[-1]["date"])
except Exception:
    print("取得失敗")'
}

local_latest() { latest < "$REPO/loto/$1_history.json"; }
pages_latest() { curl -s -m 15 "$PAGES/$1_history.json?t=$RANDOM" | latest; }

# 手元と配信中を並べて表示。すべて一致していれば 0 を返す
show_rounds() {
  local all_ok=0 n l p mark
  printf "  %-9s %-16s %-16s\n" "" "手元" "配信中"
  for n in "${LOTTERIES[@]}"; do
    l="$(local_latest "$n")"; p="$(pages_latest "$n")"
    mark=""; [ "$l" != "$p" ] && { mark="  ← 未反映"; all_ok=1; }
    printf "  %-9s %-16s %-16s%s\n" "$n" "$l" "$p" "$mark"
  done
  return $all_ok
}

cmd_status() {
  echo "■ 最新の回"
  show_rounds

  echo
  echo "■ GitHub に未公開の commit"
  git -C "$REPO" fetch -q origin 2>/dev/null
  echo "  $(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?') 件"

  echo
  echo "■ push 先"
  local url; url="$(git -C "$REPO" remote get-url origin)"
  case "$url" in
    git@*) echo "  SSH（配備鍵・期限なし）" ;;
    *)     echo "  HTTPS（トークン・期限あり）" ;;
  esac

  echo
  echo "■ 自動実行（launchd）"
  local line
  if line="$(launchctl list | grep "$LABEL")"; then
    echo "  登録済み — 前回の終了コード: $(echo "$line" | awk '{print $2}')（0 なら正常）"
  else
    echo "  未登録 — bash $REPO/scripts/install.sh を実行してください"
  fi

  echo
  echo "■ 直近のログ"
  if [ -f "$LOG" ]; then tail -n 8 "$LOG" | sed 's/^/  /'; else echo "  （ログなし）"; fi
}

cmd_update() {
  bash "$REPO/scripts/local_update.sh"
  local rc=$?
  echo
  if [ $rc -ne 0 ]; then
    echo "■ 失敗しました。上のメッセージを確認してください。"
    exit $rc
  fi

  # Pages の再構築には 30 秒〜2 分かかる
  echo "■ 配信への反映を確認しています（最大 2 分）"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    show_rounds >/dev/null && break
    sleep 15
  done
  if show_rounds; then
    echo "  → すべて配信に反映されています"
  else
    echo "  → まだ反映されていません。数分後に loto-status で確認してください"
  fi
}

case "${1:-}" in
  update) cmd_update ;;
  status) cmd_status ;;
  *) echo "使い方: loto-update | loto-status"; exit 2 ;;
esac
