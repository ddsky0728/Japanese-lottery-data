#!/usr/bin/env python3
"""配信データが抽せんルールを満たしているか検証する。
問題があれば異常終了し、公開を止める（壊れたデータを配信しないため）。

    python3 scripts/verify.py            # 検証
    python3 scripts/verify.py --summary  # 最新回の一行要約を出力
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOTO = ROOT / "loto"

# 本数字, 上限, ボーナス数, 等級数, 表示名
RULES = {
    "loto6":    (6, 43, 1, 5, "ロト6"),
    "loto7":    (7, 37, 2, 6, "ロト7"),
    "miniloto": (5, 31, 1, 4, "ミニロト"),
}


def load(name: str) -> list:
    return json.loads((LOTO / f"{name}_history.json").read_text(encoding="utf-8"))


def summary() -> str:
    parts = []
    for name, (_, _, _, _, label) in RULES.items():
        d = load(name)
        parts.append(f"{label} {d[-1]['round']}回")
    return " / ".join(parts)


def verify() -> list:
    problems = []
    for name, (pick, mx, bn, ranks, label) in RULES.items():
        d = load(name)
        rounds = [x["round"] for x in d]
        if rounds != sorted(rounds):
            problems.append(f"{label}: 回号が昇順でない")
        if len(set(rounds)) != len(rounds):
            problems.append(f"{label}: 回号が重複している")
        if any(b - a != 1 for a, b in zip(rounds, rounds[1:])):
            problems.append(f"{label}: 回号に抜けがある")
        for x in d:
            ns, bs = x["numbers"], x["bonus"]
            if len(ns) != pick or len(set(ns)) != pick:
                problems.append(f"{label} 第{x['round']}回: 本数字が{pick}個そろっていない")
                break
            if any(not (1 <= n <= mx) for n in ns):
                problems.append(f"{label} 第{x['round']}回: 本数字が1〜{mx}の範囲外")
                break
            if len(bs) != bn or (set(bs) & set(ns)):
                problems.append(f"{label} 第{x['round']}回: ボーナス数字が不正")
                break
            if x.get("prizes") and len(x["prizes"]) != ranks:
                problems.append(f"{label} 第{x['round']}回: 等級数が{ranks}でない")
                break
        print(f"{label}: {len(d)}回  最新 第{d[-1]['round']}回 ({d[-1]['date']})")
    return problems


if __name__ == "__main__":
    if "--summary" in sys.argv:
        print(summary())
        sys.exit(0)
    issues = verify()
    if issues:
        print("\n検証に失敗しました:")
        for i in issues:
            print(f"  - {i}")
        sys.exit(1)
    print("検証OK")
