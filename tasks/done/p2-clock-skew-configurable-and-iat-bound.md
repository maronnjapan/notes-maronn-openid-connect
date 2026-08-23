# [P2] ID Token / id_token_hint の Clock Skew 許容を設定可能化し、`iat` 上限を検証する

## ステータス

🟡 Medium / 未着手

## 背景

`packages/core/src/id-token.ts` の `validatePayload` と `verifyIdTokenHint` には Clock Skew 許容として **60 秒のハードコード**が埋め込まれている。デプロイ環境（コンテナの NTP 同期状況、CI 環境）で適切な値は変動し、利用者側でチューニングできないと「過剰拒否でテスト失敗」「過大許容でリプレイ窓拡大」のどちらかに振れる。

加えて `verifyIdTokenHint` は `exp` の過去日付は弾くが、**`iat` の未来日付を検証していない**。攻撃者が未来 `iat` を持つ `id_token_hint` を送り、`exp` だけ通過させてセッション固定に近い挙動を引き出す余地が残る（RFC 8725 §3.8 推奨の防御）。

関連: `study-material/done/jwt-clock-skew-and-time-tolerance.md`（本タスクの根拠ファイル）、`study-material/token-lifetime-security-policy.md`（TTL ポリシー）、`tasks/T-019-dpop.md`（DPoP 拡張時の `iat` 検証）。

## 対象ファイル

- `packages/core/src/id-token.ts`（`validatePayload`, `verifyIdTokenHint`）
- `packages/core/src/id-token.test.ts`

## 仕様参照

- RFC 7519 §4.1.4–4.1.6 — `exp` / `nbf` / `iat` の定義と "small leeway" 許容
  https://datatracker.ietf.org/doc/html/rfc7519#section-4.1
- RFC 8725 §3.8 — JWT Best Current Practice: 検証側は `iat` / `exp` / `nbf` を厳格に確認、leeway は数分以内
  https://datatracker.ietf.org/doc/html/rfc8725#section-3.8
- OpenID Connect Core 1.0 §3.1.3.7 (10) — `iat` の "too far in the past" 拒否は実装定義
  https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation

## 現状の実装

```ts
// packages/core/src/id-token.ts（validatePayload）
const now = Math.floor(Date.now() / 1000);
const clockSkewTolerance = 60;
if (payload.exp < now - clockSkewTolerance) {
  throw new Error('Token expiration time is in the past');
}
```

```ts
// packages/core/src/id-token.ts（verifyIdTokenHint）
const now = Math.floor(Date.now() / 1000);
const clockSkewTolerance = 60;
if (exp + clockSkewTolerance < now) {
  throw new IdTokenHintError('id_token_hint has expired');
}
// iat の未来日付は未検証
```

問題点:

- 60 秒固定で外部から変更できない
- 同じ定数を 2 箇所で別宣言しており乖離リスクがある
- `iat > now + leeway` の上限チェックが無い（未来日付の `id_token_hint` 受け入れ）

## 修正方針

- [ ] `clockSkewTolerance` の既定値（60 秒）を `id-token.ts` の共通定数として 1 箇所に切り出す
- [ ] `validatePayload` / `verifyIdTokenHint` に optional の `clockSkewToleranceSec` 引数を追加し、未指定時は既定値を使う
- [ ] `verifyIdTokenHint` に `iat` の上限チェックを追加（`typeof iat === 'number'` を要求し、`iat > now + clockSkewTolerance` を拒否）
- [ ] 公開関数のシグネチャ変更となるため、呼び出し元（`packages/core/src/authorization-request.ts` の `id_token_hint` 検証経路など）を確認し、optional 引数のままにして後方互換を維持
- [ ] JSDoc に「leeway は通常 30〜60 秒、5 分超は推奨しない」を明記（RFC 8725 §3.8 引用）

実装例:

```ts
// id-token.ts 共通
const DEFAULT_CLOCK_SKEW_TOLERANCE_SEC = 60;

export function validatePayload(
  payload: IdTokenPayload,
  options?: { clockSkewToleranceSec?: number },
): void {
  const leeway = options?.clockSkewToleranceSec ?? DEFAULT_CLOCK_SKEW_TOLERANCE_SEC;
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp < now - leeway) {
    throw new Error('Token expiration time is in the past');
  }
  // ... 既存検証
}

export async function verifyIdTokenHint(
  hint: string,
  context: VerifyIdTokenHintContext,
  options?: { clockSkewToleranceSec?: number },
): Promise<IdTokenPayload> {
  const leeway = options?.clockSkewToleranceSec ?? DEFAULT_CLOCK_SKEW_TOLERANCE_SEC;
  const now = Math.floor(Date.now() / 1000);
  // ... 既存の exp 検証
  if (exp + leeway < now) {
    throw new IdTokenHintError('id_token_hint has expired');
  }
  const iat = payload['iat'];
  if (typeof iat !== 'number') {
    throw new IdTokenHintError('id_token_hint is missing iat claim');
  }
  if (iat > now + leeway) {
    throw new IdTokenHintError('id_token_hint iat is in the future');
  }
  // ...
}
```

## テスト要件

- [ ] `validatePayload` で `clockSkewToleranceSec` を 0 にすると、ちょうど 1 秒過去の `exp` が拒否される
- [ ] `validatePayload` で `clockSkewToleranceSec` を 300 にすると、4 分前の `exp` を許容する
- [ ] `validatePayload` の既存テスト（leeway 指定なし）が引き続きパスする（後方互換）
- [ ] `verifyIdTokenHint` で `iat = now + 120` の `id_token_hint`（leeway 60s）が `IdTokenHintError`（"iat is in the future"）で拒否される
- [ ] `verifyIdTokenHint` で `iat` が無い `id_token_hint` が `IdTokenHintError`（"missing iat"）で拒否される
- [ ] `verifyIdTokenHint` で `iat = now`、`exp = now + 600` の正常な `id_token_hint` が通過する（リグレッションなし）
- [ ] `verifyIdTokenHint` で `clockSkewToleranceSec` を上書きすると `exp` 過去・`iat` 未来の許容幅が同方向に変わる

## 完了条件

- 上記テストがすべて通る
- `pnpm --filter @maronn-openid-connect/core test` がパスする
- 既存の `id-token.test.ts` テストにリグレッションが無い
- `verifyIdTokenHint` を呼び出している全箇所が新シグネチャでビルド可能（optional 引数のため呼び出し側修正不要を確認）
