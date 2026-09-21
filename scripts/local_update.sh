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

# 3) 公開
if "$GIT" diff --quiet -- loto/; then
  log "更新なし"
  log "=== 終了 ==="
  exit 0
fi

SUMMARY="$("$PYTHON" scripts/verify.py --summary)"
"$GIT" add loto/ || { log "git add に失敗"; exit 1; }
"$GIT" commit -m "抽せんデータ自動更新（${SUMMARY}）" || { log "commit に失敗"; exit 1; }
"$GIT" push || { log "push に失敗。あとで手動で push してください。"; exit 1; }

log "公開しました: ${SUMMARY}"
log "=== 終了 ==="
