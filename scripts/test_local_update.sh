#!/bin/bash
# local_update.sh・auto_update.py・loto.sh・アプリ側の手動用スクリプトの総合テスト。
# 実リポジトリには一切触れず、一時ディレクトリに作った bare リポジトリ + clone で確かめる。
#
#   bash ~/loto/Japanese-lottery-data/scripts/test_local_update.sh
#
# 取り込み（auto_update.py / verify.py）は差し替えのダミーで動かすので、取得元には接続しない。
# GitHub Pages への読み取りだけは loto.sh status のテストで行う。
set -u
# 作業ディレクトリへ移る前に求める（相対パスで起動されても正しく解決するように）
DATA_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # このリポジトリの scripts/
APP_SRC="${LOTO_APP_REPO:-$HOME/Downloads/Loto7Picker_1}/scripts"   # アプリ側（無ければその検査は飛ばす）

T="$(mktemp -d "${TMPDIR:-/tmp}/loto-test.XXXXXX")" || exit 1
cleanup() { chflags -R nouchg "$T" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
cd "$T" || exit 1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOTO_NET_CHECK_URL=file:///dev/null LOTO_LOCK_WAIT_MAX=600
OK=0; NG=0; SKIP=0
check() { if [ "$2" = "$3" ]; then echo "    ✓ $1"; OK=$((OK+1)); else echo "    ✗ $1 (期待 '$3' 実際 '$2')"; NG=$((NG+1)); fi; }

# --- 取り込み役のダミー（auto_update.py / verify.py の代わり） ---
cat > "$T/fakepy" <<'P'
#!/bin/bash
case "$1" in
  *auto_update.py)
    case "${FAKE_MODE:-none}" in
      sleep) sleep "${FAKE_SLEEP:-0}" ;;
      add6|add6_fail)
        /usr/bin/python3 -c 'import json;p="loto/loto6_history.json";d=json.load(open(p));d.append({"round":d[-1]["round"]+1,"date":"2026/10/5"});open(p,"w").write(json.dumps(d))'
        [ "$FAKE_MODE" = add6_fail ] && exit 1 ;;
      regress7)
        /usr/bin/python3 -c 'import json;p="loto/loto7_history.json";d=json.load(open(p));open(p,"w").write(json.dumps(d[:-1]))' ;;
      regress7_lock)
        /usr/bin/python3 -c 'import json;p="loto/loto7_history.json";d=json.load(open(p));open(p,"w").write(json.dumps(d[:-1]))'
        chflags uchg loto/loto7_history.json ;;
      fail) exit 1 ;;
    esac ;;
  *verify.py) [ "${2:-}" = "--summary" ] && echo "SUMMARY" ;;
esac
exit 0
P
chmod +x "$T/fakepy"; export LOTO_PYTHON="$T/fakepy"

# 実データと同じ形の JSON（loto6 2142 / loto7 697 / miniloto 1406 で終わる）
mkdata() {
  mkdir -p "$1/loto"
  /usr/bin/python3 - "$1/loto" <<'P'
import json, sys
for n, last in (("loto6", 2142), ("loto7", 697), ("miniloto", 1406)):
    d = [{"round": r, "date": "2026/9/1"} for r in range(last - 4, last + 1)]
    open(f"{sys.argv[1]}/{n}_history.json", "w").write(json.dumps(d))
P
}
# 配信リポジトリ（bare + clone）を作り直す
newrepo() {
  chflags -R nouchg "$T/data" 2>/dev/null; rm -rf "$T/origin.git" "$T/data"
  git init -q --bare -b main "$T/origin.git"
  git clone -q "$T/origin.git" "$T/data" 2>/dev/null
  mkdir -p "$T/data/scripts"
  cp "$DATA_SRC/local_update.sh" "$DATA_SRC/loto.sh" "$DATA_SRC/stay_awake.py" "$DATA_SRC/com.ddsky0728.loto-update.plist" "$T/data/scripts/"
  mkdata "$T/data"
  git -C "$T/data" add -A; git -C "$T/data" commit -qm init; git -C "$T/data" push -q origin main
}
S() { bash "$T/data/scripts/local_update.sh" "$@"; }
L="$T/data/.git/loto-update.lock"
latest() { /usr/bin/python3 -c "import json;print(max(r['round'] for r in json.load(open('$1'))))"; }
origin_latest() { git -C "$T/origin.git" show "main:loto/$1_history.json" | /usr/bin/python3 -c 'import json,sys;print(max(r["round"] for r in json.load(sys.stdin)))'; }

echo "■ 1 年末年始の休止（実際の auto_update.py と実データ）"
/usr/bin/python3 - "$DATA_SRC" "$T/ye.result" <<'P'
import sys, json, datetime, pathlib
src = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(src))
import auto_update as A
J = A.JST
def at(y, m, d, h=23): return datetime.datetime(y, m, d, h, 0, tzinfo=J)
def first(lot, rnd, date, now):
    p = A.pending_draws(lot, [{"round": rnd, "date": date}], now); return p[0] if p else None
cases = [
 ("ロト6 12/28(月) → 12/31(木)夜: 待ちなし", A.pending_draws("loto6", [{"round": 2167, "date": "2026/12/28"}], at(2026, 12, 31)), []),
 ("ロト6 12/28 → 次は 1/4(月)", first("loto6", 2167, "2026/12/28", at(2027, 1, 4)), (2168, "2027/1/4")),
 ("ロト7 12/25(金) → 1/1(金)夜: 待ちなし", A.pending_draws("loto7", [{"round": 709, "date": "2026/12/25"}], at(2027, 1, 1)), []),
 ("ロト7 12/25 → 次は 1/8(金)", first("loto7", 709, "2026/12/25", at(2027, 1, 8)), (710, "2027/1/8")),
 ("ミニロト 12/29(火) → 次は 1/5(火)", first("miniloto", 1419, "2026/12/29", at(2027, 1, 5)), (1420, "2027/1/5")),
 ("ふだんの金曜はそのまま（697 → 698 10/9）", first("loto7", 697, "2026/10/2", at(2026, 10, 9)), (698, "2026/10/9")),
]
bad = 0
for name, got, exp in cases:
    ok = got == exp; bad += not ok
    print(f"    {'✓' if ok else '✗'} {name}" + ("" if ok else f"  実際 {got}"))
miss = []
for lot in ("loto6", "loto7", "miniloto"):
    d = sorted(json.load(open(src.parent / "loto" / f"{lot}_history.json")), key=lambda r: r["round"])
    for a, b in zip(d, d[1:]):
        y, m, dd = map(int, a["date"].split("/"))
        if datetime.date(y, m, dd) < datetime.date(2012, 1, 1): continue
        y, m, dd = map(int, b["date"].split("/"))
        if first(lot, a["round"], a["date"], at(y, m, dd)) != (b["round"], f"{y}/{m}/{dd}"):   # 記録の一部は 0 埋め
            miss.append(f"{lot} {b['round']} {b['date']}")
ok = miss == ["loto6 1446 2020/1/9"]
print(f"    {'✓' if ok else '✗'} 2012 年以降の実記録を再生: 不一致 {len(miss)} 件 {miss}")
open(sys.argv[2], "w").write(str(bad + (0 if ok else 1)))
P
check "年末年始の検査がすべて通る" "$(cat "$T/ye.result")" 0

echo "■ 2 同時実行 → 後の方が待ってから進む"
newrepo
FAKE_MODE=sleep FAKE_SLEEP=6 S > a.log 2>&1 & A=$!; sleep 1
S > b.log 2>&1; RB=$?; wait $A; RA=$?
check "先の実行 exit 0" "$RA" 0; check "後の実行 exit 0" "$RB" 0
check "後の実行が待った" "$(grep -c '別の更新処理が実行中' b.log)" 1
check "終わったら鍵なし" "$([ -e "$L" ] && echo 残 || echo 無)" 無

echo "■ 3 死んだ PID・別プログラムの PID・自分の PID の鍵 → 回収"
/bin/sleep 0 & D=$!; wait $D; mkdir "$L"; echo $D > "$L/pid"; S > c.log 2>&1
check "死んだ PID を回収" "$(grep -c '鍵を回収しました' c.log)" 1
/bin/sleep 30 & Z=$!; mkdir "$L"; echo $Z > "$L/pid"; S > d.log 2>&1
check "別プログラムの PID を回収" "$(grep -c '鍵を回収しました' d.log)" 1; kill $Z 2>/dev/null; wait $Z 2>/dev/null
mkdir "$L"; LOTO_LOCK_WAIT_MAX=10 bash -c 'echo $$ > "'"$L"'/pid"; exec bash "'"$T"'/data/scripts/local_update.sh"' > e.log 2>&1; RE=$?
check "自分の PID の鍵を待たずに回収" "$(grep -c '鍵を回収しました' e.log)/$(grep -c '実行中' e.log)/$RE" "1/0/0"

echo "■ 4 生きている local_update.sh の鍵は奪わない（スリープで止まっている持ち主を守る）"
bash -c 'sleep 60; :' local_update.sh & H=$!; sleep 0.5
mkdir "$L"; echo $H > "$L/pid"
HS="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$(LC_ALL=C ps -p $H -o lstart= | sed 's/ *$//')" +%Y%m%d%H%M.%S)"
touch -t "$HS" "$L"; sleep 2
LOTO_LOCK_WAIT_MAX=5 S > f.log 2>&1; RF=$?
check "回収しない" "$(grep -c '鍵を回収しました' f.log)" 0
check "待ったうえで次回へ回す (exit 1)" "$RF" 1
check "持ち主の鍵はそのまま" "$(cat "$L/pid" 2>/dev/null)" "$H"
kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf "$L"

echo "■ 5 鍵ができた後に起動した local_update.sh の PID → 回収（再起動後の使い回し）"
mkdir "$L"
bash -c 'sleep 60; :' local_update.sh & H=$!; sleep 0.5; echo $H > "$L/pid"; touch -t "$(date -v-5M +%Y%m%d%H%M)" "$L"
S > g.log 2>&1
check "回収" "$(grep -c '鍵を回収しました' g.log)" 1
kill $H 2>/dev/null; wait $H 2>/dev/null

echo "■ 6 PID の無い鍵: できたばかり → 待つ / 2 分前 → 回収"
mkdir "$L"; LOTO_LOCK_WAIT_MAX=5 S > h.log 2>&1
check "できたばかりは回収しない" "$(grep -c '鍵を回収しました' h.log)" 0
touch -t "$(date -v-2M +%Y%m%d%H%M)" "$L"; S > i.log 2>&1
check "2 分前のものは回収" "$(grep -c '鍵を回収しました' i.log)" 1

echo "■ 7 終わるときに他人の鍵は消さない"
FAKE_MODE=sleep FAKE_SLEEP=3 S > j.log 2>&1 & A=$!; sleep 1
echo 999999 > "$L/pid"
wait $A
check "別の持ち主の鍵が残る" "$([ -d "$L" ] && echo 有 || echo 無)" 有
rm -rf "$L"
FAKE_MODE=fail S > k.log 2>&1; RK=$?
check "異常終了でも自分の鍵は外す" "$([ -e "$L" ] && echo 残 || echo 無)/$RK" "無/1"

echo "■ 8 .git/index.lock の名残"
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$T/data/.git/index.lock"
FAKE_MODE=add6 S > l.log 2>&1; RL=$?
check "20 分前の index.lock を消して公開" "$(grep -c 'index.lock' l.log)/$(grep -c '公開しました' l.log)/$RL" "1/1/0"
touch "$T/data/.git/index.lock"; S > m.log 2>&1
check "できたばかりの index.lock は触らない" "$([ -e "$T/data/.git/index.lock" ] && echo 有)" 有
rm -f "$T/data/.git/index.lock"

echo "■ 9 一つの宝くじが解釈できなくても、ほかは公開する"
newrepo
FAKE_MODE=add6_fail S > n.log 2>&1; RN=$?
check "ロト6 の新しい回が GitHub に届く" "$(origin_latest loto6)" 2143
check "それでも exit 1 で知らせる" "$RN" 1

echo "■ 10 公開中より古いデータは公開しない"
newrepo
FAKE_MODE=regress7 S > o.log 2>&1; RO=$?
check "GitHub のロト7 は 697 のまま" "$(origin_latest loto7)" 697
check "手元も 697 に戻す" "$(latest "$T/data/loto/loto7_history.json")" 697
check "commit しない + exit 1" "$(git -C "$T/data" rev-list --count origin/main..HEAD)/$RO" "0/1"
check "ログに理由" "$(grep -c '公開中より古いデータ' o.log)" 1

if [ -f "$APP_SRC/local_update.sh" ]; then
echo "■ 11 アプリ側の手動用: 配信側に触れず、アプリ側だけを揃える"
newrepo
rm -rf "$T/app"; mkdir -p "$T/app/scripts" "$T/app/Loto7Picker/Data" "$T/app/docs/loto"
cp "$APP_SRC/local_update.sh" "$T/app/scripts/"
/usr/bin/python3 - "$T/app" <<'P'
import json, sys
for sub in ("Loto7Picker/Data", "docs/loto"):
    for n, last in (("loto6", 2140), ("loto7", 695), ("miniloto", 1405)):   # アプリ側は古い
        open(f"{sys.argv[1]}/{sub}/{n}_history.json", "w").write(json.dumps([{"round": last, "date": "2026/9/1"}]))
P
BEFORE=$(shasum "$T/data/loto/"*.json | shasum)
LOTO_APP_REPO="$T/app" LOTO_DATA_REPO="$T/data" bash "$T/app/scripts/local_update.sh" > p.log 2>&1; RP=$?
check "exit 0" "$RP" 0
check "配信データはそのまま" "$(shasum "$T/data/loto/"*.json | shasum)" "$BEFORE"
check "アプリ同梱のロト7 → 697" "$(latest "$T/app/Loto7Picker/Data/loto7_history.json")" 697
check "docs のロト7 → 697" "$(latest "$T/app/docs/loto/loto7_history.json")" 697
check "権限 644" "$(stat -f %Lp "$T/app/Loto7Picker/Data/loto7_history.json")" 644
check "一時ファイルが残らない" "$(ls -A "$T/app/Loto7Picker/Data" | grep -c '^\.')" 0
else echo "■ 11 （アプリ側が無いので省略）"; SKIP=$((SKIP+1)); fi

echo "■ 12 push 失敗の原因を見分ける（基本）"
newrepo
printf '#!/bin/bash\necho "ssh: connect to host github.com port 22: Connection refused" >&2\nexit 255\n' > "$T/ssh_refused"
printf '#!/bin/bash\necho "git@github.com: Permission denied (publickey)." >&2\nexit 255\n' > "$T/ssh_denied"
chmod +x "$T/ssh_refused" "$T/ssh_denied"
git -C "$T/data" remote set-url origin git@github.com:x/y.git
git -C "$T/data" config core.sshCommand "$T/ssh_refused"
FAKE_MODE=add6 S > q.log 2>&1
check "接続拒否 → ネットワークと案内" "$(grep -c '接続できませんでした（ネットワーク）' q.log)/$(grep -c '認証が通りません' q.log)" "1/0"
git -C "$T/data" config core.sshCommand "$T/ssh_denied"
S > r.log 2>&1
check "公開鍵の拒否 → 認証と案内" "$(grep -c '認証が通りません' r.log)/$(grep -c 'ネットワーク）' r.log)" "1/0"

echo "■ 13 Actions と履歴が分かれたときの自己修復"
H13="$T/heal"; mkdir -p "$H13"
(
  cd "$H13" || exit 1
  export LOTO_PYTHON=/usr/bin/true
  setup() { rm -rf origin.git mac act seed; git init -q --bare -b main origin.git; git clone -q origin.git seed 2>/dev/null
            mkdir -p seed/loto seed/scripts; echo "[1]" > seed/loto/loto7_history.json; cp "$DATA_SRC/local_update.sh" seed/scripts/
            echo x=1 > seed/scripts/other.sh; git -C seed add -A; git -C seed commit -qm init; git -C seed push -q origin main; rm -rf seed
            git clone -q origin.git mac; git clone -q origin.git act; }
  r() { bash mac/scripts/local_update.sh >/dev/null 2>&1; }
  setup; echo '[1,2,"a"]' > act/loto/loto7_history.json; git -C act commit -qam a; git -C act push -q
         echo '[1,2,"m"]' > mac/loto/loto7_history.json; git -C mac commit -qam m; r
  [ "$(git -C mac rev-parse HEAD)" = "$(git -C mac rev-parse origin/main)" ] && echo S1:ok || echo S1:ng
  setup; echo '[1,2]' > act/loto/loto7_history.json; git -C act commit -qam a; git -C act push -q
         echo x=2 > mac/scripts/other.sh; git -C mac commit -qam s; B=$(git -C mac rev-parse HEAD); r
  [ "$(git -C mac rev-parse HEAD)" = "$B" ] && echo S2:ok || echo S2:ng
  setup; echo '[1,2]' > mac/loto/loto7_history.json; git -C mac commit -qam m; r
  [ "$(git -C origin.git rev-parse main)" = "$(git -C mac rev-parse HEAD)" ] && echo S3:ok || echo S3:ng
  setup; echo '[1,2]' > act/loto/loto7_history.json; git -C act commit -qam a; git -C act push -q; r
  [ "$(git -C mac rev-parse HEAD)" = "$(git -C origin.git rev-parse main)" ] && echo S4:ok || echo S4:ng
) > s.log 2>&1
check "取り込み分だけ捨てる / 他の変更は触らない / 先行は送る / 遅れは追いつく" "$(grep -c ':ok' s.log)" 4

echo "■ 14 消せない鍵 → 空回りせずすぐ止まる"
newrepo
/bin/sleep 0 & D=$!; wait $D; mkdir "$L"; echo $D > "$L/pid"; chmod 555 "$L"
SECONDS=0; LOTO_LOCK_WAIT_MAX=20 S > t14.log 2>&1; R14=$?; E14=$SECONDS
check "5 秒以内に終わる" "$([ $E14 -lt 5 ] && echo y || echo "n(${E14}s)")" y
check "exit 1 + 手で消すよう案内" "$R14/$(grep -c '消せません' t14.log)" "1/1"
check "ログは数行だけ" "$([ "$(wc -l < t14.log)" -lt 12 ] && echo y || echo "n($(wc -l < t14.log))")" y
chmod 755 "$L"; rm -rf "$L"

echo "■ 15 鍵を作れない → 原因をそのまま案内"
chmod 555 "$T/data/.git"
SECONDS=0; S > t15.log 2>&1; R15=$?; E15=$SECONDS
chmod 755 "$T/data/.git"
check "すぐ終わり、原因を表示" "$R15/$(grep -c '鍵を作れません.*Permission denied' t15.log)/$([ $E15 -lt 5 ] && echo fast)" "1/1/fast"
check "「実行中」と誤って案内しない" "$(grep -c '実行中' t15.log)" 0

echo "■ 16 git が動いていれば古い index.lock も触らない"
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$T/data/.git/index.lock"
(sleep 6 | /usr/bin/git hash-object --stdin >/dev/null) & G=$!; sleep 1
S > t16.log 2>&1; wait $G
check "index.lock を残す" "$([ -e "$T/data/.git/index.lock" ] && echo 有)" 有
rm -f "$T/data/.git/index.lock"

echo "■ 17 ブランチのロックファイルの名残も片付ける"
newrepo
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$T/data/.git/refs/heads/main.lock"
FAKE_MODE=add6 S > t17.log 2>&1; R17=$?
check "main.lock を消して公開" "$(grep -c 'refs/heads/main.lock' t17.log)/$(grep -c '公開しました' t17.log)/$R17" "1/1/0"

echo "■ 18 main 以外では止める"
newrepo
git -C "$T/data" checkout -qb work
FAKE_MODE=add6 S > t18.log 2>&1; R18=$?
check "作業ブランチ: exit 1 + 案内" "$R18/$(grep -c 'main ブランチではない' t18.log)" "1/1"
check "何も commit しない" "$(git -C "$T/data" rev-list --count main..work)" 0
git -C "$T/data" checkout -q main; git -C "$T/data" checkout -q --detach
FAKE_MODE=add6 S > t18b.log 2>&1; R18b=$?
check "detached HEAD: exit 1" "$R18b/$(grep -c 'detached HEAD' t18b.log)" "1/1"
git -C "$T/data" checkout -q main

if [ -f "$APP_SRC/local_update.sh" ]; then
echo "■ 19 アプリ側で手入力した回は上書きしない"
newrepo
rm -rf "$T/app"; mkdir -p "$T/app/scripts" "$T/app/Loto7Picker/Data" "$T/app/docs/loto"
cp "$APP_SRC/local_update.sh" "$T/app/scripts/"
/usr/bin/python3 - "$T/app" <<'P'
import json, sys
for sub in ("Loto7Picker/Data", "docs/loto"):
    for n, last in (("loto6", 2140), ("loto7", 698), ("miniloto", 1405)):   # loto7 だけ手入力で新しい
        d = [{"round": r, "date": "2026/9/1"} for r in range(last - 4, last + 1)]
        open(f"{sys.argv[1]}/{sub}/{n}_history.json", "w").write(json.dumps(d))
P
LOTO_APP_REPO="$T/app" LOTO_DATA_REPO="$T/data" bash "$T/app/scripts/local_update.sh" > t19.log 2>&1; R19=$?
check "手入力のロト7 698 を残す（アプリ・docs）" "$(latest "$T/app/Loto7Picker/Data/loto7_history.json")/$(latest "$T/app/docs/loto/loto7_history.json")" "698/698"
check "古いロト6 は 2142 に更新" "$(latest "$T/app/Loto7Picker/Data/loto6_history.json")" 2142
check "警告 + exit 1" "$(grep -c 'アプリ側の方が新しい' t19.log)/$R19" "2/1"
check "一時ファイルなし" "$(ls -A "$T/app/Loto7Picker/Data" "$T/app/docs/loto" | grep -c '^\.')" 0
else echo "■ 19 （アプリ側が無いので省略）"; SKIP=$((SKIP+1)); fi

echo "■ 20 push 失敗の文言の見分け（広げた分）"
newrepo
git -C "$T/data" remote set-url origin git@github.com:x/y.git
cls() {
  printf '#!/bin/bash\necho "%s" >&2\nexit 255\n' "$1" > "$T/ssh_x"; chmod +x "$T/ssh_x"
  git -C "$T/data" config core.sshCommand "$T/ssh_x"
  S > t20.log 2>&1
  if grep -q '（ネットワーク）' t20.log; then echo net
  elif grep -q 'ホスト鍵' t20.log; then echo hostkey
  elif grep -q '認証が通りません' t20.log; then echo auth
  else echo other; fi
}
FAKE_MODE=add6 S >/dev/null 2>&1   # 未公開の commit を 1 件作っておく（push は失敗する）
check "Host is down → ネットワーク"                "$(cls 'ssh: connect to host github.com port 22: Host is down')" net
check "Network is down → ネットワーク"             "$(cls 'ssh: connect to host github.com port 22: Network is down')" net
check "Can't assign requested address → ネットワーク" "$(cls "ssh: connect to host github.com port 22: Can't assign requested address")" net
check "server not responding → ネットワーク"       "$(cls 'Timeout, server github.com not responding.')" net
check "Host key verification failed → ホスト鍵"    "$(cls 'Host key verification failed.')" hostkey
check "読み取り専用の鍵 → 認証"                    "$(cls 'ERROR: The key you are authenticating with has been marked as read only.')" auth
check "Permission denied (publickey) → 認証"       "$(cls 'git@github.com: Permission denied (publickey).')" auth
check "分からない失敗 → 一般の再試行案内"          "$(cls 'fatal: something unexpected')" other

echo "■ 21 追跡していない雑ファイルは公開しない"
newrepo
echo junk > "$T/data/loto/.DS_Store"; echo bak > "$T/data/loto/loto7_history.json.bak"
FAKE_MODE=add6 S > t21.log 2>&1
check "GitHub の loto/ は履歴ファイル 3 つだけ" "$(git -C "$T/origin.git" ls-tree --name-only main loto/ | wc -l | tr -d ' ')" 3

echo "■ 22 元に戻せなければ公開を中止"
newrepo
FAKE_MODE=regress7_lock S > t22.log 2>&1; R22=$?
chflags nouchg "$T/data/loto/loto7_history.json"
check "exit 1 + 中止の案内" "$R22/$(grep -c '元に戻せませんでした' t22.log)" "1/1"
check "GitHub のロト7 は 697 のまま" "$(origin_latest loto7)" 697

echo "■ 23 実行中はスリープを止め、終われば解除（蓋を閉じた運用）"
newrepo
# 関数ではなく直接起動する（$! をスクリプト自身の PID にするため。caffeinate はその PID を代理する）
FAKE_MODE=sleep FAKE_SLEEP=5 bash "$T/data/scripts/local_update.sh" > t23.log 2>&1 & A=$!; sleep 2
SA="$(pgrep -f "stay_awake.py $A\$")"
check "主: stay_awake.py が NetworkClientActive を保持（DarkWake でも効く種類）" \
  "$(pmset -g assertions | grep "pid ${SA:-x}(" | grep -c 'NetworkClientActive named: "loto-update: lottery data import"')" 1
check "予備: caffeinate も保持" \
  "$(pmset -g assertions | grep -A1 ' PreventSystemSleep named: "caffeinate' | grep -c "on behalf of Process ID $A")" 1
wait $A; sleep 2
check "終われば両方とも外れる" \
  "$(pmset -g assertions | grep -c 'loto-update: lottery data import')/$(pmset -g assertions | grep -c "on behalf of Process ID $A")" "0/0"
check "見守り役のプロセスも残らない" "$(pgrep -f "stay_awake.py $A\$" | wc -l | tr -d ' ')" 0

echo "■ 23b stay_awake.py 単体: 引数の検査と 30 分上限の存在"
/usr/bin/python3 "$DATA_SRC/stay_awake.py" >/dev/null 2>&1; check "引数なし → exit 2" "$?" 2
/usr/bin/python3 "$DATA_SRC/stay_awake.py" abc >/dev/null 2>&1; check "数字以外 → exit 2" "$?" 2
/bin/sleep 0 & D=$!; wait $D
SECONDS=0; /usr/bin/python3 "$DATA_SRC/stay_awake.py" $D; R=$?
check "終わっているプロセスならすぐ解除して exit 0" "$R/$([ $SECONDS -lt 3 ] && echo fast)" "0/fast"
check "最長 30 分の上限がある" "$(grep -c '^MAX_SECONDS = 30 \* 60' "$DATA_SRC/stay_awake.py")" 1

echo "■ 24 実行時の状態（電源・蓋・DarkWake）を記録"
check "環境の行がある" "$(grep -cE '環境: 電源=(電源アダプタ|バッテリー) 蓋=(開|閉|不明) 状態=(通常|DarkWake|不明)' t23.log)" 1

echo "■ 25 loto-status が蓋を閉じた実行を、失敗・中断も含めて読み取る"
FH="$T/home"; mkdir -p "$FH/Library/Logs" "$FH/Library/LaunchAgents"
cat > "$FH/Library/Logs/loto-update.log" <<'EOF'
[2026-10-05 08:00:02] === 開始 (x) ===
[2026-10-05 08:00:02] 環境: 電源=電源アダプタ 蓋=開 状態=通常
[2026-10-05 08:00:04] 更新なし
[2026-10-05 08:00:04] === 終了 (exit 0) ===
[2026-10-05 21:12:03] === 開始 (x) ===
[2026-10-05 21:12:03] 環境: 電源=電源アダプタ 蓋=閉 状態=DarkWake
[2026-10-05 21:12:11] 公開しました: ロト6 2143回 / ロト7 697回 / ミニロト 1406回
[2026-10-05 21:12:11] === 終了 ===
EOF
HOME="$FH" bash "$T/data/scripts/loto.sh" status > t25.log 2>&1
# 「蓋を閉じた自動更新」の欄だけを見る（下の「直近のログ」には蓋=開の行もそのまま出る）
sed -n '/蓋を閉じた自動更新/,/直近のログ/p' t25.log > t25s.log
check "蓋を閉じた成功を表示（以前の終了行の形式も読める・開いた回は出さない）" "$(grep -c '蓋=閉 状態=DarkWake → 公開$' t25s.log)/$(grep -c '蓋=開' t25s.log)" "1/0"
check "文字化けしない" "$(grep -c $'\xef\xbf\xbd' t25.log)" 0

cat > "$FH/Library/Logs/loto-update.log" <<'EOF'
[2026-10-05 21:12:03] === 開始 (x) ===
[2026-10-05 21:12:03] 環境: 電源=電源アダプタ 蓋=閉 状態=DarkWake
[2026-10-05 21:12:05] 解釈できない回がありました。取り込めたほかの回は公開します。手動で確認してください。
[2026-10-05 21:12:11] 公開しました: ロト6 2143回
[2026-10-05 21:12:11] === 終了 (exit 1) ===
[2026-10-05 22:13:00] === 開始 (x) ===
[2026-10-05 22:13:00] 環境: 電源=電源アダプタ 蓋=閉 状態=DarkWake
[2026-10-05 22:13:05] push に失敗: GitHub に接続できませんでした（ネットワーク）。次回の実行で送り直します。
[2026-10-05 22:13:05] === 終了 (exit 1) ===
[2026-10-06 08:14:00] === 開始 (x) ===
[2026-10-06 08:14:00] 環境: 電源=電源アダプタ 蓋=閉 状態=DarkWake
[2026-10-06 08:24:00] 待っても終わらないため中止します（次回の実行で拾います）
[2026-10-06 08:24:00] === 終了 (exit 1) ===
[2026-10-06 21:15:00] === 開始 (x) ===
stay_awake: スリープ防止を設定できませんでした (IOReturn 0xe00002c2)
[2026-10-06 21:15:00] 環境: 電源=電源アダプタ 蓋=閉 状態=DarkWake
[2026-10-06 21:15:03] 取り込みを実行
EOF
HOME="$FH" bash "$T/data/scripts/loto.sh" status > t25c.log 2>&1
sed -n '/蓋を閉じた自動更新/,/直近のログ/p' t25c.log > t25cs.log
# 4 件のうち最古（一部解釈できない + 公開）は「直近 3 件」から外れる。別に確かめる
head -n 5 "$FH/Library/Logs/loto-update.log" > "$FH/Library/Logs/x" && mv "$FH/Library/Logs/x" "$FH/Library/Logs/loto-update.log"
HOME="$FH" bash "$T/data/scripts/loto.sh" status 2>&1 | sed -n '/蓋を閉じた自動更新/,/直近のログ/p' > t25ds.log
check "一部解釈できない + 公開 → 公開（要確認）" "$(grep -c '→ 公開（要確認）' t25ds.log)" 1
check "push の失敗を表示" "$(grep -c '→ push 失敗$' t25cs.log)" 1
check "鍵待ちの中止を表示" "$(grep -c '→ 中止$' t25cs.log)" 1
check "終了の行が無い回（途中で停止）を表示 + スリープ防止の失敗" "$(grep -c '→ 失敗・中断（終了の記録なし）（スリープ防止に失敗）' t25cs.log)" 1
check "直近 3 件だけ（古い成功が新しい失敗を隠さない）" "$(grep -c '蓋=閉' t25cs.log)" 3

: > "$FH/Library/Logs/loto-update.log"
HOME="$FH" bash "$T/data/scripts/loto.sh" status > t25b.log 2>&1
check "記録が無いときの案内" "$(grep -c 'まだありません' t25b.log)" 1

echo "■ 26 どの終わり方でも「=== 終了 (exit N) ===」を残す"
lastline() { tail -n 1 "$1" | sed 's/^\[[^]]*\] //'; }
newrepo
FAKE_MODE=add6 S > e0.log 2>&1;   check "成功 → exit 0"                  "$(lastline e0.log)" "=== 終了 (exit 0) ==="
FAKE_MODE=fail S > e1.log 2>&1;   check "解釈できない回 → exit 1"        "$(lastline e1.log)" "=== 終了 (exit 1) ==="
git -C "$T/data" checkout -qb work
S > e2.log 2>&1;                  check "main 以外で中止 → exit 1"       "$(lastline e2.log)" "=== 終了 (exit 1) ==="
git -C "$T/data" checkout -q main
bash -c 'sleep 60; :' local_update.sh & H=$!; sleep 0.5; mkdir "$L"; echo $H > "$L/pid"
HS="$(LC_ALL=C date -j -f '%a %b %e %T %Y' "$(LC_ALL=C ps -p $H -o lstart= | sed 's/ *$//')" +%Y%m%d%H%M.%S)"; touch -t "$HS" "$L"; sleep 2
LOTO_LOCK_WAIT_MAX=5 S > e3.log 2>&1; check "鍵待ちで中止 → exit 1（相手の鍵は残す）" "$(lastline e3.log)/$(cat "$L/pid")" "=== 終了 (exit 1) ===/$H"
kill $H 2>/dev/null; wait $H 2>/dev/null; rm -rf "$L"
git -C "$T/data" remote set-url origin git@github.com:x/y.git; git -C "$T/data" config core.sshCommand "$T/ssh_refused"
FAKE_MODE=add6 S > e4.log 2>&1;   check "push 失敗 → exit 1"             "$(lastline e4.log)" "=== 終了 (exit 1) ==="
check "終了の行は 1 回だけ" "$(grep -c '=== 終了' e4.log)" 1

echo
echo "結果: 合格 $OK / 不合格 $NG$([ $SKIP -gt 0 ] && echo " / 省略 $SKIP")"
[ "$NG" -eq 0 ]
