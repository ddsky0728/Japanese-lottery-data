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
# いつ動くか（launchd）:
#   - 抽せん日の 21:00 / 22:00、毎朝 08:00
#   - ログインした直後（RunAtLoad）。電源を切っていた間の予定は launchd が
#     実行し直さないため、起動時にここで取りこぼしを拾う
#
# 動作:
#   0. ほかの更新処理と重ならないよう待ち、ネットワークに繋がるのを待つ
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

# ---- 同時実行の防止 ---------------------------------------------------------
# ログイン直後の自動実行と、同じ頃に手で叩いた loto-update が重なると、
# 両方が同じ回を取り込んで commit・push を奪い合う（10/3 00:07 起動 → 00:09 手動、
# のように実際に起こりうる）。後から来た方は先の処理が終わるのを待ってから続ける。
# 先に取り込まれていれば、後の方は「更新なし」で終わる。
#
# 鍵は .git の中に置く（launchd と端末とで同じ場所になるように）。
# 持ち主が消えた鍵（強制終了・電源断の名残）は回収する。古い鍵で自動更新が
# 止まり続けるのがいちばん困るため、PID の使い回しまで見分ける。
# 一方、持ち主が生きていれば経過時間では奪わない。MacBook はスリープ中に
# プロセスごと止まるので、目覚めた持ち主と二重に動いてしまうため。
# 持ち主の各処理にはすべて時間制限があり、永久に居座ることはない。
LOCKDIR="$REPO/.git/loto-update.lock"
LOCK_WAIT_MAX="${LOTO_LOCK_WAIT_MAX:-600}"   # 先の処理を待つ上限（秒）

# 鍵の持ち主がもういなければ真
lock_is_stale() {
  local pid started created
  pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    # mkdir 直後で PID をまだ書いていないだけかもしれない。1 分は待つ
    [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]
    return
  fi
  # 鍵を取ろうとしている自分の PID が書かれている = 前回の起動で強制終了した名残。
  # ログイン直後の実行は起動ごとにほぼ同じ PID になるので、実際に起こりうる
  [ "$pid" = "$$" ] && return 0
  # kill -0 は別ユーザー（sudo で動かした回など）のプロセスだと EPERM で失敗し、
  # 生きているのに「いない」と判定してしまう。ps で存在だけを見る
  ps -p "$pid" >/dev/null 2>&1 || return 0                                      # 持ち主がいない
  ps -p "$pid" -o command= 2>/dev/null | grep -q "local_update.sh" || return 0  # 別のプログラムが PID を再利用
  # 同じスクリプトでも、鍵ができたあとに起動したものは持ち主ではない（再起動後の再利用）
  started="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | sed 's/ *$//')"
  started="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$started" +%s 2>/dev/null || echo 0)"
  created="$(stat -f %m "$LOCKDIR" 2>/dev/null || echo 0)"
  [ "$started" -gt "$created" ] && return 0
  return 1
}

acquire_lock() {
  local waited=0 seen err
  while ! err="$(LC_ALL=C mkdir "$LOCKDIR" 2>&1)"; do
    # 「既にある」以外の失敗（ディスクがいっぱい・権限など）は待っても直らない。
    # 「別の処理が実行中」と誤って案内しないよう、原因をそのまま知らせて終わる
    case "$err" in
      *"File exists"*) ;;
      *) log "鍵を作れません: $err"; return 1 ;;
    esac
    if lock_is_stale; then
      seen="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
      # 回収する直前にもう一度確かめる（ほかのプロセスが先に回収・取得していないか）
      if lock_is_stale && [ "$(cat "$LOCKDIR/pid" 2>/dev/null || true)" = "$seen" ]; then
        # 消せない鍵（sudo で動かした回の名残など）は、待っても消えない。
        # 空回りしてログを埋めないよう、一度だけ知らせて終わる
        if ! rm -rf "$LOCKDIR" 2>/dev/null; then
          log "前回の処理が残した鍵を消せません。手動で削除してください: $(ls -ld "$LOCKDIR" 2>&1)"
          return 1
        fi
        log "前回の処理が残した鍵を回収しました"
      fi
      continue
    fi
    [ "$waited" -eq 0 ] && log "別の更新処理が実行中です。終わるのを待ちます（最大 $((LOCK_WAIT_MAX / 60)) 分）"
    if [ "$waited" -ge "$LOCK_WAIT_MAX" ]; then
      log "待っても終わらないため中止します（次回の実行で拾います）"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo $$ > "$LOCKDIR/pid"
  # 自分の鍵のときだけ消す。回収されたあとに目覚めた古い持ち主が、
  # 新しい持ち主の鍵を消してしまわないように
  trap '[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKDIR"' EXIT
}
acquire_lock || exit 1

# git が強制終了・電源断で残したロックファイル（index.lock や refs の *.lock）があると、
# 以後の commit や fetch がすべて失敗し、人が消すまで公開が止まる。
# 鍵を持っている（= このリポジトリでほかの更新処理は動いていない）うえで、次のときだけ消す。
#   - git のプロセスがひとつも動いていない。手作業の git commit がエディタを開いたまま、
#     ファイルを閉じてロックだけ残していることがあるため（git 2.50 で確認）
#   - 10 分以上前のもので、どのプロセスも開いていない
if ! /usr/bin/pgrep -qx git; then
  for f in "$REPO/.git/index.lock" "$REPO/.git/HEAD.lock" "$REPO/.git/packed-refs.lock" \
           "$REPO"/.git/refs/heads/*.lock "$REPO"/.git/refs/remotes/origin/*.lock; do
    [ -e "$f" ] && [ -n "$(find "$f" -mmin +10 2>/dev/null)" ] \
      && ! /usr/sbin/lsof -t "$f" >/dev/null 2>&1 \
      && rm -f "$f" && log "git が残した ${f#"$REPO"/}（10 分以上前）を削除しました"
  done
fi

# 公開するのは main だけ。作業用ブランチや detached HEAD のままだと、取り込んだ回が
# そのブランチに commit され、main には届かないまま「更新なし」で終わってしまう。
BRANCH="$("$GIT" symbolic-ref -q --short HEAD || true)"
UPSTREAM="$("$GIT" rev-parse --abbrev-ref '@{u}' 2>/dev/null)" || UPSTREAM=""
if [ "$BRANCH" != "main" ] || [ "$UPSTREAM" != "origin/main" ]; then
  log "公開用の main ブランチではないため中止します（現在: ${BRANCH:-detached HEAD}、追跡先: ${UPSTREAM:-なし}）。git checkout main で戻してください。"
  exit 1
fi

# ---- ネットワーク待ち -------------------------------------------------------
# ログイン直後（RunAtLoad）は Wi-Fi がまだ繋がっていないことがある。
# 繋がる前に進むと「取得できず」で終わり、電源を切っていた間の取りこぼしを
# 拾い損ねる。GitHub に届くまで最大 3 分待つ。繋がっていれば待たない。
NET_WAIT_MAX="${LOTO_NET_WAIT_MAX:-180}"
NET_CHECK_URL="${LOTO_NET_CHECK_URL:-https://github.com}"
waited=0
until /usr/bin/curl -s -m 5 -o /dev/null "$NET_CHECK_URL"; do
  [ "$waited" -eq 0 ] && log "ネットワークの接続を待っています（最大 $((NET_WAIT_MAX / 60)) 分）"
  if [ "$waited" -ge "$NET_WAIT_MAX" ]; then
    log "ネットワークに繋がらないまま続けます（取得できなければ次回の実行で拾います）"
    break
  fi
  sleep 10
  waited=$((waited + 10))
done
[ "$waited" -gt 0 ] && [ "$waited" -lt "$NET_WAIT_MAX" ] && log "ネットワークに繋がりました"

# 認証が通らないときに端末の入力待ちで止まらないようにする。
# 転送が 60 秒間ほぼ止まったら打ち切る（9/22 に push が 1 時間止まったため）。
export GIT_TERMINAL_PROMPT=0
GITNET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)

# 0) GitHub 側の最新に合わせる。Actions 側で先に取り込まれていれば重複しない。
#
#    Actions のワークフローもこの Mac と同じ 21:00 / 22:00 に動く。
#    まれに Actions 側も取得に成功すると、同じ回を両側で commit して履歴が分かれ、
#    以後この Mac からの push が毎回拒否される。
#    手元だけにある commit が loto/ の取り込み分だけなら、取得元から作り直せるので
#    捨てて GitHub 側に合わせ、このあと取り込み直す。それ以外の変更が混じっていれば
#    人の判断が要るので触らない。
FE="$("$GIT" "${GITNET[@]}" fetch -q origin 2>&1)" \
  || log "注意: GitHub から最新を取得できませんでした（このまま続けます）: $(echo $FE)"
if ! "$GIT" merge -q --ff-only '@{u}' 2>/dev/null; then
  if [ "$("$GIT" rev-list --count 'HEAD..@{u}')" != "0" ] \
     && [ -z "$("$GIT" diff --name-only '@{u}...HEAD' -- . ':!loto')" ]; then
    # --keep: 手元の未 commit の変更があれば消さずに中止する
    if "$GIT" reset -q --keep '@{u}'; then
      log "GitHub 側と履歴が分かれていたため、手元の取り込み分を捨てて GitHub 側に合わせました（このあと取り込み直します）"
    else
      log "注意: GitHub 側に合わせられませんでした（未 commit の変更があります）。手動で確認してください。"
    fi
  else
    log "注意: GitHub 側と履歴が分かれています（loto/ 以外の変更を含むため自動では合わせません）。手動で確認してください。"
  fi
fi

# 1) 取り込み。遮断や通信断なら 0 で返るので、ここでは止まらない。
#    解釈できない回があっても（exit 1）、ほかの宝くじで取り込めた回は公開する。
#    一つの宝くじの問題で三つとも止めないため。最後に exit 1 で知らせる。
log "取り込みを実行"
STRUCTURAL=0
"$PYTHON" scripts/auto_update.py || {
  STRUCTURAL=1
  log "解釈できない回がありました。取り込めたほかの回は公開します。手動で確認してください。"
}

# 2) 検証。ここを通らないものは公開しない。
log "配信データを検証"
"$PYTHON" scripts/verify.py || {
  log "検証に失敗しました。公開しません。"
  exit 1
}

# 3) 新しく取り込んだ回があれば commit する
#
#    最後の砦: 公開中（HEAD）より回が減る・古くなるファイルは公開しない。
#    鍵の外から古いデータで上書きされたときに、配信が過去の回へ戻るのを防ぐ
#    （アプリ側の手動用スクリプトが、古いアプリ同梱データでここを上書きしえた）。
if ! "$GIT" diff --quiet -- loto/; then
  REGRESSED="$(/usr/bin/python3 - "$REPO" "$GIT" <<'PY'
import json, pathlib, subprocess, sys
repo, git = pathlib.Path(sys.argv[1]), sys.argv[2]
for f in sorted((repo / "loto").glob("*_history.json")):
    rel = f"loto/{f.name}"
    try:
        old = json.loads(subprocess.run([git, "-C", str(repo), "show", f"HEAD:{rel}"],
                                        capture_output=True, check=True).stdout)
        new = json.loads(f.read_text(encoding="utf-8"))
        o, n = max(r["round"] for r in old), max(r["round"] for r in new)
    except Exception:
        continue          # HEAD に無い・形式が違う → 判定は verify.py に任せる
    if n < o or len(new) < len(old):
        print(rel)
        print(f"  {rel}: 公開中 第{o}回・{len(old)}件 → 手元 第{n}回・{len(new)}件", file=sys.stderr)
PY
)"
  if [ -n "$REGRESSED" ]; then
    # shellcheck disable=SC2086
    if ! "$GIT" checkout HEAD -- $REGRESSED; then
      log "公開中より古いデータを元に戻せませんでした。公開を中止します: $(echo $REGRESSED)"
      exit 1
    fi
    log "公開中より古いデータになっていたため、公開せずに元へ戻しました: $(echo $REGRESSED)"
    STRUCTURAL=1
  fi
fi
if ! "$GIT" diff --quiet -- loto/; then
  SUMMARY="$("$PYTHON" scripts/verify.py --summary)"
  # 追跡中（= 検証済み）の履歴ファイルだけを載せる。Finder の .DS_Store や
  # 手作業の .orig などが、検証されないまま公開サイトに出ないように
  "$GIT" add -u -- loto/ || { log "git add に失敗"; exit 1; }
  "$GIT" commit -q -m "抽せんデータ自動更新（${SUMMARY}）" || { log "commit に失敗"; exit 1; }
  log "commit しました: ${SUMMARY}"
fi

# 4) まだ公開していない commit があれば push する。
#    「新しい取り込みがあるときだけ push」だと、一度 push に失敗した commit が
#    二度と送られず取り残される（9/24 に実際に起きた）。
#    そこで取り込みの有無に関係なく、未公開の commit が残っていれば毎回送り直す。
AHEAD="$("$GIT" rev-list --count '@{u}..HEAD' 2>/dev/null)" || {
  log "未公開の commit 数を確認できませんでした。公開しません。"
  exit 1
}
if [ "$AHEAD" = "0" ]; then
  log "更新なし"
  log "=== 終了 ==="
  exit "$STRUCTURAL"
fi

log "未公開の commit が ${AHEAD} 件あります。push します"
if OUT="$("$GIT" "${GITNET[@]}" push 2>&1)"; then
  log "公開しました: $("$PYTHON" scripts/verify.py --summary)"
  log "=== 終了 ==="
  exit "$STRUCTURAL"
fi

echo "$OUT"
# 接続そのものの失敗を先に見分ける。git はどちらの場合も最後に
# "Could not read from remote repository" を出すので、認証より先に判定しないと
# 圏外やWi-Fi未接続を「配備鍵の問題」と誤って案内してしまう。
if echo "$OUT" | grep -qiE "Could not resolve host|Connection refused|timed out|Network is unreachable|Network is down|Host is down|No route to host|Can.t assign requested address|not responding|Connection reset|Connection closed by|Broken pipe|kex_exchange_identification|Undefined error"; then
  log "push に失敗: GitHub に接続できませんでした（ネットワーク）。次回の実行で送り直します。"
elif echo "$OUT" | grep -qiE "Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED"; then
  log "push に失敗: GitHub のホスト鍵が ~/.ssh/loto_known_hosts と一致しません。"
  log "  → GitHub 公式の指紋（scripts/install.sh の GITHUB_ED25519_FP）を確かめてください。"
elif echo "$OUT" | grep -qiE "Invalid username or token|Authentication failed|could not read Username|Permission denied \(publickey\)|marked as read only"; then
  log "push に失敗: GitHub の認証が通りません。"
  if "$GIT" remote get-url origin | grep -q '^git@'; then
    log "  → 配備鍵（~/.ssh/loto_deploy）が GitHub の Deploy keys から外れていないか確認してください。"
  else
    log "  → トークンの期限切れ・無効化の可能性。ターミナルで一度 git push し、新しいトークンを入力してください。"
  fi
  log "  → 認証が直れば、次回の実行で未公開分はまとめて送られます。"
else
  log "push に失敗。次回の実行で送り直します。"
fi
exit 1
