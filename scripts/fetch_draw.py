#!/usr/bin/env python3
"""指定した回の抽せん結果を公開ページから取得する。

安全のための考え方:
  - 回号は URL で指定し、ページ本文の回号・抽せん日と一致することを確認する
    （ページ側の並び順に依存しないので、取り違えが起きない）
  - 抽せん前のページは数字が「*」なので、検証で自動的に弾かれる
  - 少しでも解釈できなければ何も返さない。取りこぼす方が、誤って取り込むより安全。

単体実行:
    python3 scripts/fetch_draw.py loto6 2134
"""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request

# 宝くじごとのルール: 本数字, 上限, ボーナス数, 等級数, キャリーオーバーの有無
RULES = {
    "miniloto": {"pick": 5, "max": 31, "bonus": 1, "ranks": 4, "carryover": False},
    "loto6":    {"pick": 6, "max": 43, "bonus": 1, "ranks": 5, "carryover": True},
    "loto7":    {"pick": 7, "max": 37, "bonus": 2, "ranks": 6, "carryover": True},
}

# サイト側でパスが揃っていないため、両方を順に試す
URL_PATTERNS = [
    "https://www.syumimania.com/takarakuji/{lottery}-{round}/",
    "https://www.syumimania.com/{lottery}-{round}/",
]

JP_NAME = {"loto6": "ロト6", "loto7": "ロト7", "miniloto": "ミニロト"}

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36")


class NotPublished(Exception):
    """まだ結果が出ていない（抽せん前・記事未公開）。次回に回せばよい。"""


class FetchError(Exception):
    """取得または解釈に失敗した。人が確認するまで取り込まない。"""


def _download(url: str) -> str | None:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            return res.read().decode("utf-8", errors="ignore")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise FetchError(f"HTTP {e.code}")
    except Exception as e:
        raise FetchError(str(e))


def _plain(html_text: str) -> str:
    t = re.sub(r"<script.*?</script>", " ", html_text, flags=re.S)
    t = re.sub(r"<style.*?</style>", " ", t, flags=re.S)
    t = re.sub(r"<[^>]+>", " ", t)
    t = (t.replace("&nbsp;", " ").replace("&amp;", "&")
           .replace("&lt;", "<").replace("&gt;", ">"))
    return re.sub(r"\s+", " ", t)


def parse(text: str, lottery: str, expected_round: int, expected_date: str) -> dict:
    rule = RULES[lottery]
    name = JP_NAME[lottery]

    # 1) ページが本当にその回のものか確かめる
    if not re.search(rf"第\s*{expected_round}\s*回\s*{name}", text):
        raise FetchError(f"ページに「第{expected_round}回{name}」の記載がありません")

    y, m, d = (int(x) for x in expected_date.split("/"))
    if not re.search(rf"抽選日は\s*{y}年{m}月{d}日", text):
        raise FetchError(f"抽せん日が {expected_date} と一致しません")

    # 対象回の記述以降だけを見る。
    # 同じ文字列は <title> にも出るため、直後に「本数字」と「1等」が続く
    # 箇所＝実際の結果表だけを選ぶ（見出しやメニューの数字を拾わないため）。
    heading = f"第{expected_round}回{name}の当選番号"
    body = None
    for m in re.finditer(re.escape(heading), text):
        window = text[m.end(): m.end() + 400]
        if "本数字" in window and "1等" in text[m.end(): m.end() + 1200]:
            body = text[m.end():]
            break
    if body is None:
        raise NotPublished("結果表が見つかりません")

    # 2) 本数字とボーナス数字
    #    書式は宝くじごとに違う:
    #      ロト6/7  : 本数字 01 11 … ボーナス数字 (27)   ／ ロト7は (21) (34)
    #      ミニロト : 本数字 ( )はボーナス数字 01 04 … (22)
    #    そこで「括弧の中＝ボーナス、それ以外＝本数字」として扱う。
    #    抽せん前は数字が「*」なので、個数が揃わず NotPublished になる。
    head = body.find("本数字")
    tail = body.find("1等")
    if head < 0 or tail < 0 or tail <= head:
        raise FetchError("当選番号の区画を特定できません")
    seg = body[head: tail]

    bonus = [int(x) for x in re.findall(r"\((\s*\d{1,2}\s*)\)", seg)]
    main_src = re.sub(r"\([^)]*\)", " ", seg)           # 括弧ごと除去
    for label in ("本数字", "ボーナス数字", "はボーナス数字"):
        main_src = main_src.replace(label, " ")
    numbers = [int(x) for x in re.findall(r"\b\d{1,2}\b", main_src)]

    if len(numbers) != rule["pick"] or len(bonus) != rule["bonus"]:
        raise NotPublished("数字がまだ確定していません")

    # 3) 等級表
    prizes = []
    for rank in range(1, rule["ranks"] + 1):
        row = re.search(
            rf"{rank}等\s*(該当なし|[\d,]+口|\*口)\s*(該当なし|[\d,]+円|\*円)", body)
        if not row:
            raise FetchError(f"{rank}等の行を読み取れません")
        winners_text, amount_text = row.group(1), row.group(2)
        if "*" in winners_text or "*" in amount_text:
            raise NotPublished("当せん金がまだ確定していません")
        # 「該当なし」は 0口・0円 として扱う
        winners = 0 if "該当" in winners_text else int(re.sub(r"[^\d]", "", winners_text))
        amount = 0 if "該当" in amount_text else int(re.sub(r"[^\d]", "", amount_text))
        prizes.append({"rank": rank, "winners": winners, "amount": amount})

    record = {"round": expected_round, "date": expected_date,
              "numbers": sorted(numbers), "bonus": sorted(bonus), "prizes": prizes}

    # 4) キャリーオーバー
    if rule["carryover"]:
        co = re.search(r"キャリーオーバー\s*([\d,]+|\*)円", body)
        if not co:
            raise FetchError("キャリーオーバーを読み取れません")
        if "*" in co.group(1):
            raise NotPublished("キャリーオーバーがまだ確定していません")
        record["carryover"] = int(co.group(1).replace(",", ""))

    _validate(record, rule)
    return record


def _validate(record: dict, rule: dict) -> None:
    """抽せんルールに反していれば取り込まない。最後の砦。"""
    problems = []
    nums, bonus = record["numbers"], record["bonus"]
    if len(set(nums)) != rule["pick"]:
        problems.append(f"本数字に重複がある: {nums}")
    if any(not (1 <= n <= rule["max"]) for n in nums):
        problems.append(f"本数字が1〜{rule['max']}の範囲外: {nums}")
    if any(not (1 <= b <= rule["max"]) for b in bonus):
        problems.append(f"ボーナス数字が範囲外: {bonus}")
    if set(bonus) & set(nums):
        problems.append("ボーナス数字が本数字と重複")
    for p in record["prizes"]:
        if (p["winners"] == 0) != (p["amount"] == 0):
            problems.append(f"{p['rank']}等の口数と金額が不整合")
    if problems:
        raise FetchError("; ".join(problems))


def fetch(lottery: str, expected_round: int, expected_date: str) -> dict:
    last_error = None
    for pattern in URL_PATTERNS:
        url = pattern.format(lottery=lottery, round=expected_round)
        html_text = _download(url)
        if html_text is None:
            continue
        try:
            return parse(_plain(html_text), lottery, expected_round, expected_date)
        except NotPublished:
            raise
        except FetchError as e:
            last_error = e
    if last_error:
        raise last_error
    raise NotPublished("記事がまだ公開されていません")


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in RULES:
        sys.exit(f"使い方: {sys.argv[0]} [{'|'.join(RULES)}] 回号 抽せん日(yyyy/m/d)")
    try:
        print(json.dumps(fetch(sys.argv[1], int(sys.argv[2]), sys.argv[3]),
                         ensure_ascii=False, indent=2))
    except NotPublished as e:
        sys.exit(f"未公開: {e}")
    except FetchError as e:
        sys.exit(f"取得失敗: {e}")
