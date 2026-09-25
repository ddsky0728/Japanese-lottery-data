#!/bin/bash
# 抽せんデータの自動更新（この Mac で定期実行する）。
#
# なぜ Mac で動かすのか:
#   取得先は Cloudflare でデータセンターのIPを遮断しており、
#   GitHub Actions のランナーからは HTTP 403 が返る。家庭用回線なら通るため、
#   収集はこの Mac が担当し、結果だけを GitHub に公開する。
#   Actions 側のワークフローは補助として残してある。
#
# なぜ ~/Downloads に置かないのか:
#   macOS は ~/Downloads・~/Desktop・~/Documents を保護しており、
#   launchd から起動したプロセスは読み書きできない
#   （Operation not permitted になる）。保護対象外の場所に置く必要がある。
#
# 動作:
#   1. 未反映の回を取り込む（このリポジトリの loto/ だけを更新する）
#   2. 配信データを検証（壊れていれば公開しない）
#   3. 変更があれば commit して push
#
# 手動実行:
#   bash scripts/local_update.sh
#
# ログ: ~/Library/Logs/loto-update.log（launchd 経由のとき）

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${LOTO_PYTHON:-/usr/bin/python3}"
GIT=/usr/bin/git

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== 開始 (${REPO}) ==="
cd "$REPO" || exit 1

# 認証が通らないときに端末の入力待ちで止まらないようにする。
# 転送が 60 秒間ほぼ止まったら打ち切る（9/22 に push が 1 時間止まったため）。
export GIT_TERMINAL_PROMPT=0
GITNET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)

# 0) GitHub 側の最新に合わせる。Actions 側で先に取り込まれていれば重複しない。
"$GIT" "${GITNET[@]}" pull -q --ff-only 2>/dev/null \
  || log "注意: GitHub 側と履歴が分かれています。push で失敗する場合は手動で確認してください。"

# 1) 取り込み。遮断や通信断なら 0 で返るので、ここでは止まらない。
log "取り込みを実行"
"$PYTHON" scripts/auto_update.py || {
  log "解釈できない回がありました。手動で確認してください。"
  exit 1
}

# 2) 検証。ここを通らないものは公開しない。
log "配信データを検証"
"$PYTHON" scripts/verify.py || {
  log "検証に失敗しました。公開しません。"
  exit 1
}

# 3) 新しく取り込んだ回があれば commit する
if ! "$GIT" diff --quiet -- loto/; then
  SUMMARY="$("$PYTHON" scripts/verify.py --summary)"
  "$GIT" add loto/ || { log "git add に失敗"; exit 1; }
  "$GIT" commit -q -m "抽せんデータ自動更新（${SUMMARY}）" || { log "commit に失敗"; exit 1; }
  log "commit しました: ${SUMMARY}"
fi

# 4) まだ公開していない commit があれば push する。
#    「新しい取り込みがあるときだけ push」だと、一度 push に失敗した commit が
#    二度と送られず取り残される（9/24 に実際に起きた）。
#    そこで取り込みの有無に関係なく、未公開の commit が残っていれば毎回送り直す。
AHEAD="$("$GIT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
if [ "$AHEAD" = "0" ]; then
  log "更新なし"
  log "=== 終了 ==="
  exit 0
fi

log "未公開の commit が ${AHEAD} 件あります。push します"
if OUT="$("$GIT" "${GITNET[@]}" push 2>&1)"; then
  log "公開しました: $("$PYTHON" scripts/verify.py --summary)"
  log "=== 終了 ==="
  exit 0
fi

echo "$OUT"
if echo "$OUT" | grep -qiE "Invalid username or token|Authentication failed|could not read Username"; then
  log "push に失敗: GitHub の認証が通りません（トークンの期限切れ・無効化の可能性）。"
  log "  → ターミナルで一度 git push し、新しいトークンを入力してください。"
  log "  → 認証が直れば、次回の実行で未公開分はまとめて送られます。"
else
  log "push に失敗。次回の実行で送り直します。"
fi
exit 1
