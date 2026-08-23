# [P3] `sub` の ASCII 文字種を検証し、255 ASCII 制約を正確に実装する

## ステータス

🟡 Medium / 未着手

## 背景

ID Token 発行経路の `sub` バリデーションは `payload.sub.length > 255`（UTF-16 コードユニット数）しか見ておらず、OIDC Core §2 が要求する「255 **ASCII** characters」の **ASCII 文字種**を検証していない。その結果、非 ASCII（日本語・絵文字）を含む `sub` や、UTF-16 length と ASCII 文字数が乖離する `sub` を発行できてしまう。

さらに、既存 study-material 2 件（`study-material/sub-stability-and-subject-types.md` / `study-material/pairwise-subject-identifier.md`）が「`sub` の ASCII 構造検証は実装済み」と**実装と乖離した記述**をしており、レビュー者が「対応済み」と誤認するリスクがある。本タスクで実装と記述の両方を是正する。

詳細な検討は `study-material/done/sub-ascii-charset-enforcement.md` を参照。

## 対象ファイル

- `packages/core/src/id-token.ts`（`sub` 検証ロジック）
- `packages/core/src/id-token.test.ts`（テスト追加）
- `study-material/sub-stability-and-subject-types.md`（記述是正）
- `study-material/pairwise-subject-identifier.md`（記述是正）
- 必要に応じて署名付き UserInfo / JWT Access Token の `sub` 発行経路（共通バリデータ化の検討）

## 仕様参照

- OpenID Connect Core 1.0 §2「ID Token」/ Subject Identifier 定義 — 「It MUST NOT exceed 255 ASCII characters in length.」
- OpenID Connect Core 1.0 §8「Subject Identifier Types」
- RFC 7519 §4.1「Registered Claim Names」

## 現状の実装

```ts
// packages/core/src/id-token.ts（行 96-103 付近）
if (!payload.sub) {
  throw new Error('Missing required claim: sub');
}

// OIDC Core 1.0 Section 5.1: sub must not exceed 255 ASCII characters
if (payload.sub.length > 255) {           // ← UTF-16 length のみ。ASCII 文字種チェック無し
  throw new Error('Subject identifier must not exceed 255 ASCII characters');
}
```

ファイル全体に `charCodeAt` / `0x7f` / `[\x00-\x7F]` 等の ASCII 範囲判定が存在しない（grep 確認済み）。

## 修正方針

- [ ] `sub` 検証を ASCII 文字種 + 長さの同時検証に置換する。印字可能 ASCII を基本とする:
  ```ts
  // OIDC Core 1.0 §2: sub MUST NOT exceed 255 ASCII characters.
  if (!/^[\x21-\x7E]{1,255}$/.test(payload.sub)) {
    throw new Error('Subject identifier must be 1-255 printable ASCII characters');
  }
  ```
  - 空白を許容するか（`\x20-\x7E`）は要判断。`sub` に空白・制御文字を入れる正当理由は乏しいため印字可能 ASCII を筆頭とする
  - ASCII に限定すれば「文字数 == バイト数 == `.length`」が一致するため、サロゲートペア等の数え方の曖昧さは自然に解消する
- [ ] 検証側 `validateIdTokenHint` にも同等チェックを入れ、発行・検証の対称性を保つか判断・実装
- [ ] `study-material/sub-stability-and-subject-types.md` の「ASCII の構造検証はある」記述を「長さのみ検証・文字種は本タスクで追加」に是正
- [ ] `study-material/pairwise-subject-identifier.md` の「255 ASCII は実装済み」記述を是正

## テスト要件

- [ ] 純 ASCII 255 文字の `sub` → 発行成功
- [ ] 純 ASCII 256 文字の `sub` → 拒否
- [ ] 非 ASCII を含む `sub`（例 `"abcあ"`）→ 拒否
- [ ] 絵文字（サロゲートペア）を含む `sub` → 拒否
- [ ] 印字不可制御文字（`\x00` / `\n`）を含む `sub` → 拒否（印字可能 ASCII 採用時）
- [ ] 既存の正常 `sub`（英数字 + `-` `_` 等）→ 従来どおり発行（リグレッション無し）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 是正後の study-material 2 件が実装実態と一致していること
