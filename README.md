# Japanese Lottery Data

iOS アプリ「ロト番号生成」が参照する、日本の数字選択式宝くじ（ミニロト・ロト6・ロト7）の
抽せん履歴データを配信しています。

## データ

| ファイル | 内容 |
|---|---|
| `loto/loto6_history.json` | ロト6（本数字6個・1〜43） |
| `loto/loto7_history.json` | ロト7（本数字7個・1〜37） |
| `loto/miniloto_history.json` | ミニロト（本数字5個・1〜31） |

## 形式

```json
{
  "round": 2131,
  "date": "2026/8/24",
  "numbers": [25, 26, 28, 33, 35, 43],
  "bonus": [9],
  "prizes": [
    { "rank": 1, "winners": 0, "amount": 0 },
    { "rank": 2, "winners": 3, "amount": 23703800 }
  ],
  "carryover": 237030272
}
```

- `numbers` は本数字（昇順）、`bonus` はボーナス数字
- `winners` は当せん口数、`amount` は1口あたりの当せん金（円）
- `winners` が 0 の等級は「該当なし」
- `carryover` はロト6・ロト7のみ（ミニロトには無い）

## 注意

当せん番号および当せん金の確定情報は、必ず宝くじ公式サイトまたは販売窓口の発表を
ご確認ください。本データは参考値です。
