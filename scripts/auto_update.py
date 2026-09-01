#!/usr/bin/env python3
"""抽せん日の翌に実行して、未反映の回を自動で取り込む。

安全のための考え方:
  - 次に来るはずの回号と抽せん日は「手元のデータ＋抽せん曜日」から自分で計算する。
    取得先の並び順や見出しに依存しないため、回の取り違えが起きない。
  - 取得した内容が計算した回号・抽せん日と一致しなければ取り込まない。
  - 未公開（抽せん前・記事なし）は正常終了。次回の実行で拾えばよい。
  - 解釈できない場合は異常終了して知らせる。黙って古いままにしない。

    python3 scripts/auto_update.py            # 取り込み
    python3 scripts/auto_update.py --dry-run  # 確認のみ（書き込まない）
"""

from __future__ import annotations

import datetime
import json
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_draw import RULES, FetchError, NotPublished, fetch  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

# 書き込み先。存在するものだけ更新する。
TARGET_DIRS = [
    ROOT / "loto",                   # 配信データ（このリポジトリ）
]

# 抽せん曜日（月=0 … 日=6）
DRAW_WEEKDAYS = {"miniloto": [1], "loto6": [0, 3], "loto7": [4]}

# 抽せんは 18:45、結果の掲載は 19:45 頃。余裕をみて 20:30 以降を「確定済み」とみなす。
RESULT_READY_HOUR, RESULT_READY_MINUTE = 20, 30

JST = datetime.timezone(datetime.timedelta(hours=9))


def now_jst() -> datetime.datetime:
    return datetime.datetime.now(JST)


def primary_path(lottery: str) -> Path:
    return TARGET_DIRS[0] / f"{lottery}_history.json"


def load(lottery: str) -> list:
    data = json.loads(primary_path(lottery).read_text(encoding="utf-8"))
    data.sort(key=lambda x: x["round"])
    return data


def parse_date(text: str) -> datetime.date:
    y, m, d = (int(v) for v in text.split("/"))
    return datetime.date(y, m, d)


def pending_draws(lottery: str, data: list, today: datetime.datetime) -> list:
    """まだ取り込んでいない、かつ結果が出ているはずの回を古い順に返す。"""
    last = data[-1]
    rnd, date = last["round"], parse_date(last["date"])
    ready_today = (today.hour, today.minute) >= (RESULT_READY_HOUR, RESULT_READY_MINUTE)

    out = []
    while True:
        date += datetime.timedelta(days=1)
        if date > today.date():
            break
        if date.weekday() not in DRAW_WEEKDAYS[lottery]:
            continue
        rnd += 1
        # 当日分は掲載時刻を過ぎてから
        if date == today.date() and not ready_today:
            break
        out.append((rnd, f"{date.year}/{date.month}/{date.day}"))
    return out


def write_everywhere(lottery: str, data: list) -> list:
    written = []
    payload = json.dumps(data, ensure_ascii=False)
    for directory in TARGET_DIRS:
        if not directory.parent.exists():
            continue
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / f"{lottery}_history.json"
        target.write_text(payload, encoding="utf-8")
        written.append(target)
    return written


def main() -> int:
    dry_run = "--dry-run" in sys.argv
    today = now_jst()
    print(f"実行時刻: {today:%Y-%m-%d %H:%M} JST" + ("  [確認のみ]" if dry_run else ""))

    added_total, failures = 0, []

    for lottery in ("miniloto", "loto6", "loto7"):
        data = load(lottery)
        pending = pending_draws(lottery, data, today)
        if not pending:
            print(f"  {lottery:9} 第{data[-1]['round']}回まで反映済み（追加なし）")
            continue

        added_here = 0
        for rnd, date_text in pending:
            try:
                record = fetch(lottery, rnd, date_text)
            except NotPublished as e:
                print(f"  {lottery:9} 第{rnd}回({date_text}) 未公開のため見送り: {e}")
                break                      # これ以降の回も出ていないはず
            except FetchError as e:
                msg = f"{lottery} 第{rnd}回({date_text}) 取得失敗: {e}"
                print(f"  ✗ {msg}")
                failures.append(msg)
                break

            if any(x["round"] == record["round"] for x in data):
                print(f"  {lottery:9} 第{rnd}回 はすでに登録済み（スキップ）")
                continue

            data.append(record)
            data.sort(key=lambda x: x["round"])
            added_here += 1
            print(f"  ✓ {lottery:9} 第{rnd}回({date_text}) {record['numbers']} + {record['bonus']}")

        if added_here and not dry_run:
            for path in write_everywhere(lottery, data):
                print(f"      更新: {path}")
        added_total += added_here

    print()
    if failures:
        print("解釈できなかった回があります。手動で確認してください:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"追加: {added_total}回" + ("（確認のみ・未書き込み）" if dry_run and added_total else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
