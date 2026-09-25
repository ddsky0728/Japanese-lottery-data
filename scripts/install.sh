#!/bin/bash
# この Mac に抽せんデータの自動更新をセットアップする。何度実行してもよい。
#
#   1. GitHub への接続を配備鍵（SSH）に切り替える
#        トークンは期限が切れると push が止まる（2026-09-24 に実際に起きた）。
#        配備鍵には期限がなく、権限もこのリポジトリだけに限られる。
#        鍵が GitHub に未登録なら、HTTPS（トークン）のまま続ける。
#   2. launchd に定期実行を登録する（登録済みなら入れ替える）
#   3. ターミナルに loto-update / loto-status を追加する
#
# 使い方:
#   bash ~/loto/Japanese-lottery-data/scripts/install.sh
#
# 新しい Mac に移すときも、リポジトリを ~/loto に clone してこれを実行すればよい。
# （~/Downloads・~/Desktop・~/Documents には置かないこと。launchd から読めない）

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.ddsky0728.loto-update"
PLIST_SRC="$REPO/scripts/$LABEL.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
KEY="$HOME/.ssh/loto_deploy"
KNOWN="$HOME/.ssh/loto_known_hosts"
SSH_URL="git@github.com:ddsky0728/Japanese-lottery-data.git"
HTTPS_URL="https://github.com/ddsky0728/Japanese-lottery-data.git"
DEPLOY_KEYS_PAGE="https://github.com/ddsky0728/Japanese-lottery-data/settings/keys"
# GitHub が公開している ed25519 ホスト鍵の指紋。なりすましたサーバーに繋がないための照合用。
GITHUB_ED25519_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
ZSHRC="$HOME/.zshrc"

step() { echo; echo "■ $*"; }

case "$REPO" in
  "$HOME/Downloads"*|"$HOME/Desktop"*|"$HOME/Documents"*)
    echo "このリポジトリが macOS の保護フォルダの中にあります: $REPO"
    echo "launchd から読めないため、~/loto などに移してから実行してください。"
    exit 1 ;;
esac

# ---------------------------------------------------------------- 1
step "1/3 GitHub への接続"

mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$KEY" \
    -C "loto-update@$(scutil --get LocalHostName 2>/dev/null || hostname -s) Japanese-lottery-data"
  chmod 600 "$KEY"
  echo "  配備鍵を作成しました: $KEY"
fi

if [ ! -s "$KNOWN" ]; then
  tmp="$(mktemp)"
  ssh-keyscan -t ed25519 github.com 2>/dev/null > "$tmp"
  fp="$(ssh-keygen -lf "$tmp" | awk '{print $2}')"
  if [ "$fp" = "$GITHUB_ED25519_FP" ]; then
    mv "$tmp" "$KNOWN" && chmod 644 "$KNOWN"
    echo "  GitHub のホスト鍵を照合して保存しました"
  else
    rm -f "$tmp"
    echo "  GitHub のホスト鍵が公開値と一致しません（$fp）。中止します。"
    exit 1
  fi
fi

# このリポジトリの git だけが配備鍵を使う（ほかのリポジトリや ~/.ssh/config には触れない）。
# BatchMode: 入力待ちで止まらない / ConnectTimeout・ServerAlive: 通信が固まったら打ち切る
git -C "$REPO" config core.sshCommand \
  'ssh -i "$HOME/.ssh/loto_deploy" -o IdentitiesOnly=yes -o UserKnownHostsFile="$HOME/.ssh/loto_known_hosts" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'

probe="$(ssh -i "$KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN" \
             -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15 \
             -T git@github.com 2>&1)"
if echo "$probe" | grep -q "successfully authenticated"; then
  git -C "$REPO" remote set-url origin "$SSH_URL"
  # 書き込みまでできるか（Allow write access が付いているか）を空 push で確かめる
  if git -C "$REPO" push --dry-run -q origin HEAD 2>/dev/null; then
    echo "  配備鍵で接続できました。push 先を SSH に切り替えました（期限切れで止まることはなくなります）"
  else
    git -C "$REPO" remote set-url origin "$HTTPS_URL"
    echo "  配備鍵は登録されていますが、書き込み権限がありません。HTTPS のまま続けます"
    echo "  → $DEPLOY_KEYS_PAGE で鍵を開き、「Allow write access」にチェックしてください"
  fi
else
  echo "  配備鍵がまだ GitHub に登録されていません。HTTPS（トークン）のまま続けます"
  echo "  → 登録ページ: $DEPLOY_KEYS_PAGE"
  echo "  → 登録する公開鍵:"
  echo "    $(cat "$KEY.pub")"
  echo "  → 登録したら、もう一度このスクリプトを実行してください"
fi
echo "  現在の push 先: $(git -C "$REPO" remote get-url origin)"

# ---------------------------------------------------------------- 2
step "2/3 定期実行（launchd）"

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
# plist の中の絶対パスを、この Mac のリポジトリとホームに合わせて書き換える
sed -e "s#/Users/jeong/loto/Japanese-lottery-data#$REPO#g" \
    -e "s#/Users/jeong/Library/Logs#$HOME/Library/Logs#g" \
    "$PLIST_SRC" > "$PLIST_DST"
plutil -lint -s "$PLIST_DST" || { echo "  plist が壊れています"; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
if launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"; then
  echo "  登録しました — 抽せん日（月・火・木・金）21:30 / 23:00、毎朝 08:00"
else
  echo "  登録に失敗しました"
  exit 1
fi

# ---------------------------------------------------------------- 3
step "3/3 ターミナルのコマンド"

BEGIN="# >>> loto (scripts/install.sh) >>>"
END="# <<< loto <<<"
touch "$ZSHRC"
if grep -qF "$BEGIN" "$ZSHRC"; then
  # 以前に追加した分を消してから入れ直す（二重に増えないように）
  /usr/bin/sed -i '' "/^# >>> loto (scripts\/install.sh) >>>$/,/^# <<< loto <<<$/d" "$ZSHRC"
fi
cat >> "$ZSHRC" <<EOS
$BEGIN
alias loto-update='bash "$REPO/scripts/loto.sh" update'
alias loto-status='bash "$REPO/scripts/loto.sh" status'
$END
EOS
echo "  ~/.zshrc に追加しました:"
echo "    loto-update   今すぐ取り込み・公開し、配信への反映まで確かめる"
echo "    loto-status   いまの状態を確認する（何も変更しない）"
echo "  → 新しいターミナルを開くと使えます（このウィンドウでは: source ~/.zshrc）"

echo
echo "完了"
