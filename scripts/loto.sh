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
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PY=/usr/bin/python3
LOTTERIES=(loto6 loto7 miniloto)

# リポジトリの plist を、この Mac のパスに合わせて書き出す。
# install.sh の登録と、status の「登録内容が最新か」の判定が同じものを使う。
render_plist() {
  sed -e "s#/Users/jeong/loto/Japanese-lottery-data#$REPO#g" \
      -e "s#/Users/jeong/Library/Logs#$HOME/Library/Logs#g" \
      "$REPO/scripts/$LABEL.plist"
}

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
    # launchd が読むのは登録時に写した plist だけ。リポジトリ側を変えても
    # install.sh を実行し直すまで効かないので、食い違いを知らせる
    if ! render_plist | cmp -s - "$LAUNCH_PLIST"; then
      echo "  ⚠ 登録されている設定がリポジトリより古いままです（変更が効いていません）"
      echo "    → bash $REPO/scripts/install.sh を実行してください"
    fi
  else
    echo "  未登録 — bash $REPO/scripts/install.sh を実行してください"
  fi

  echo
  echo "■ 蓋を閉じた自動更新"
  # 電源アダプタ接続時の Power Nap が切れていると、蓋を閉じている間は目を覚まさない
  local pn
  pn="$(/usr/bin/pmset -g custom 2>/dev/null | awk '/^AC Power/{ac=1;next} /^[A-Za-z]/{ac=0} ac&&$1=="powernap"{print $2}')"
  case "$pn" in
    1) echo "  Power Nap（電源アダプタ接続時）: 有効" ;;
    0) echo "  ⚠ Power Nap（電源アダプタ接続時）: 無効 — 蓋を閉じている間は更新されません"
       echo "    → システム設定 → バッテリー → オプション で Power Nap を有効にしてください" ;;
    *) echo "  Power Nap: 確認できませんでした" ;;
  esac
  if /usr/bin/pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; then
    echo "  いまの電源: 電源アダプタ"
  else
    echo "  いまの電源: バッテリー（蓋を閉じるなら電源アダプタにつないでおくのが確実です）"
  fi
  echo "  蓋を閉じた状態での直近の実行:"
  if [ -f "$LOG" ] && grep -q "蓋=閉" "$LOG"; then
    # 「環境: … 蓋=閉」の回を、成功も失敗も途中で止まった回も含めて拾う。
    #   - 次の「=== 開始」か最後に来たら、終了の行が無くてもその回を出す（途中で止まった回）
    #   - 「要確認」は別に持ち、あとの「公開」「更新なし」で消えないようにする
    #   - 結果は短い名前にする（awk の substr はバイト単位で、日本語を途中で切ってしまう）
    awk '
      function flush(t) {
        if (env == "") return
        if (res == "") res = "失敗・中断（終了の記録なし）"
        printf "    %s %s〜%s  %s → %s%s%s\n", day, start, t, env, res, (warn ? "（要確認）" : ""), (sa ? "（スリープ防止に失敗）" : "")
        env = ""
      }
      /=== 開始/ { flush(last); start=substr($2,1,8); day=substr($1,2); env=""; res=""; warn=0; sa=0 }
      /^\[20/ { last=substr($2,1,8) }
      /^stay_awake:/ { sa=1 }
      /環境:/ && /蓋=閉/ { env=$0; sub(/.*環境: /,"",env) }
      env!="" && /公開しました/ { res="公開" }
      env!="" && /更新なし/ { res="更新なし" }
      env!="" && /push に失敗/ { res="push 失敗" }
      env!="" && /検証に失敗/ { res="検証失敗" }
      env!="" && /中止します|鍵を作れません|鍵を消せません/ { res="中止" }
      env!="" && /解釈できない|公開せずに元へ戻しました/ { warn=1 }
      /=== 終了/ {
        if (env != "" && match($0, /exit [0-9]+/) && substr($0, RSTART+5, RLENGTH-5) + 0 != 0) {
          if (res == "") res = "失敗"
          else if (res == "公開" || res == "更新なし") warn = 1
        }
        flush(substr($2,1,8))
      }
      END { flush(last) }
' "$LOG" | tail -n 3
  else
    echo "    まだありません（電源につないで蓋を閉じたまま抽せん日の夜を過ぎると、ここに表示されます）"
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
  plist)  render_plist ;;    # install.sh が使う
  *) echo "使い方: loto-update | loto-status"; exit 2 ;;
esac
