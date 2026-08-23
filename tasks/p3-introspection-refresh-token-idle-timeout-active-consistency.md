# [P3] Introspection の Refresh Token `active` 判定をアイドルタイムアウトと一貫させる（RFC 7662 §2.2）

## ステータス

🟢 Low / 未着手

## 背景

Token Endpoint の Refresh 経路は `refreshTokenIdleTimeoutSeconds`（無操作タイムアウト）超過の RT を
`invalid_grant` で拒否するのに、`handleIntrospectionRequest` は同じトークンを `active: true` と報告する。
`isRefreshTokenActive` が `used` と `expiresAt` しか見ず、Introspection 側にアイドルタイムアウトの入力が
無いため、OP 自身の無操作失効ポリシーが Introspection から不可視になっている。

RFC 7662 §2.2 の `active` は「現時点で使用可能（有効期限切れ・失効・その他の理由で無効でない）」を意味する。
Token Endpoint が使用不可と判断するトークンを `active: true` と返すのは定義と整合しない。
アイドルタイムアウトはオプトイン設定のため、有効化した OP でのみ顕在化する。Introspection は Basic OP 認証の
必須ではない（拡張）ため認定ブロッカーではないが、Fidelity と失効の観測性に関わる。

併せて、`buildRefreshTokenResponse` が保存済み `audience` を `aud` として返さない（access token 応答は返す）
非対称も本タスクで方針を決める。

検討詳細は `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` を参照。

> 関連：アイドルタイムアウト自体（Token Endpoint 側）は `tasks/done/p3-refresh-token-idle-inactivity-timeout.md`。
> Introspection の形状・`token_type` 値は `tasks/done/p1-token-introspection.md` /
> `study-material/introspection-refresh-token-type-value-rfc7662.md`。本タスクは `active` 判定の一貫性に限定する。

## 対象ファイル

- `packages/core/src/introspection.ts`（`isRefreshTokenActive` / `IntrospectionRequestContext` / `buildRefreshTokenResponse`）
- `packages/core/src/introspection.test.ts`
- `packages/core/src/refresh-token-grant.ts`（判定ロジックを共有関数に切り出す場合）
- CLI テンプレートの introspection ルート（アイドル設定を core に渡す配線。該当 sample がある場合）

## 仕様参照

- RFC 7662 §2.2: `active` = "whether or not the presented token is currently active"。失効・期限切れ・
  その他の理由で無効なら `false`。`aud` は OPTIONAL なレスポンスメンバ。
- RFC 9700 §4.14: Refresh Token の無効化ポリシー（採るなら観測系でも一貫が望ましい）。

## 現状の実装

```ts
// packages/core/src/introspection.ts:103-107
function isRefreshTokenActive(info, now) {
  if (info.used) return false;
  if (info.expiresAt <= now) return false;
  return true; // アイドルタイムアウトを見ていない
}
```

`IntrospectionRequestContext`（:64-70）にアイドルタイムアウト秒/最終使用時刻の供給口が無い。
Token Endpoint 側（`refresh-token-grant.ts:86-97`）はアイドル超過を `invalid_grant` で拒否する。
`buildRefreshTokenResponse`（:129-141）は `aud` を返さないが、`buildAccessTokenResponse`（:121-123）は返す。

## 修正方針

- [ ] Introspection のアイドル反映方針を決定（案A: Token 経路と共有 `isRefreshTokenUsable` を切り出し両者で使用 /
  案B: `IntrospectionRequestContext` にアイドル秒を追加し `isRefreshTokenActive` にだけ判定追加 /
  案C: アイドルは Token Endpoint の責務と割り切り、Introspection は used/exp のみと明文化）
- [ ] `aud` 方針を決定（案X: access と揃えて返す / 案Y: RT の audience は AS であり返さない旨をコメント/README に明文化）
- [ ] （案A/B）`IntrospectionRequestContext` にアイドルタイムアウト秒（必要なら最終使用時刻の供給口）を追加し判定を実装
- [ ] CLI テンプレートの introspection ルートが該当設定を core に渡すよう配線（該当 sample がある場合）

## テスト要件

- [ ] （core）アイドルタイムアウト超過の RT を introspect → `active: false`
- [ ] （core）アイドルタイムアウト未超過の RT を introspect → `active: true`
- [ ] （案X 採用時）active な RT 応答に `aud` が含まれる／（案Y 採用時）含まれないことを回帰固定
- [ ] 既存の `used` / `expiresAt` 判定が回帰しない

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 挙動変更が生成 OP の introspection に及ぶ場合、`packages/cli` テンプレートと各 sample の
  `conformance.test.ts` を更新し、`pnpm test` がパスすること
