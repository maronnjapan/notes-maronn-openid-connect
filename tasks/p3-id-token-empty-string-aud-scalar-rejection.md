# [P3] ID Token の `aud`（スカラー空文字列）を拒否する非対称ガードの是正

## ステータス

🟢 Low / 未着手

## 背景

`validatePayload`（ID Token 発行経路）は `aud` に対し「欠損」「空配列」「配列メンバーの空文字列/非文字列」を拒否するが、`aud` が**単一のスカラー空文字列 `""`** の場合はどのチェックにも掛からず、構造的に不正な ID Token を発行できてしまう。配列パスには `RFC 7519 §4.1.3`（`aud` = StringOrURI）に基づく厳格検証があるのに、より一般的な単一 audience ケースだけがザルという**非対称な実装の穴**。空 `client_id` 等の誤設定で `aud: ""` の ID Token が発行され得る。

詳細な検討は `study-material/done/id-token-empty-string-audience-scalar-rejection.md` を参照。

## 対象ファイル

- `packages/core/src/id-token.ts`（`validatePayload` の `aud` 検証）
- `packages/core/src/id-token.test.ts`（テスト追加）
- （方針 B 採用時）`packages/core/src/access-token.ts` との共通バリデータ化

## 仕様参照

- RFC 7519 §4.1.3 `aud` / §2 `StringOrURI`（空文字列は有効な StringOrURI ではない）
- OpenID Connect Core 1.0 §2 ID Token（`aud` REQUIRED）/ §3.1.3.7 ID Token Validation（`aud` 照合）

## 現状の実装

```ts
// packages/core/src/id-token.ts（L105-123 付近）
if (payload.aud === undefined || payload.aud === null) {          // L105
  throw new Error('Missing required claim: aud');
}
if (Array.isArray(payload.aud) && payload.aud.length === 0) {     // L110: 配列のみ
  throw new Error('Audience must not be an empty array');
}
if (Array.isArray(payload.aud)) {                                 // L117: 配列のみ
  for (const a of payload.aud) {
    if (typeof a !== 'string' || a.length === 0) {
      throw new Error('Audience array must contain only non-empty strings');
    }
  }
}
// ↑ スカラー payload.aud === '' はいずれの分岐にも入らず素通り
```

テスト `id-token.test.ts:826-841` は配列メンバーの空文字列のみを検証しており、スカラー `aud: ''` のケースが無い（穴の裏付け）。

## 修正方針

- [ ] スカラー `aud` の非空文字列チェックを追加する。配列パスのメッセージと平仄を合わせる:
  ```ts
  // RFC 7519 §4.1.3: scalar aud must be a non-empty StringOrURI.
  if (typeof payload.aud === 'string' && payload.aud.length === 0) {
    throw new Error('Audience must be a non-empty string');
  }
  ```
  （配置は L110 の空配列チェックと同層に置き、配列/スカラー双方をカバーする）
- [ ] `access-token.ts:40-48`（既に非空配列を要求）と共通バリデータ化するか（方針 B）を判断する。過剰対応を避け、まずは `id-token.ts` 内の最小差分（方針 A）で対称性を回復する選択も可
- [ ] `StringOrURI` 完全準拠（`:` を含むなら URI 等）までは踏み込まない（Basic OP スコープでは過剰の懸念）

## テスト要件

- [ ] スカラー `aud: ''`（空文字列）→ 発行拒否（`Audience must be a non-empty string`）
- [ ] 正常なスカラー `aud`（通常の `client_id`）→ 従来どおり発行（リグレッション無し）
- [ ] 正常な配列 `aud`（複数 audience + `azp`）→ 従来どおり発行
- [ ] 既存の「空配列」「配列メンバー空文字列/非文字列」テストが回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- スカラー/配列の両パスで空・不正 `aud` が対称に拒否されること
