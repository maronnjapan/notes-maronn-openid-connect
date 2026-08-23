# [P2] ID Token 発行時にスカラー `sub` / `aud` / `nonce` の文字列型を検証する

## ステータス

🟠 High / 未着手

## 背景

`validatePayload`（ID Token 発行前検証）は、配列 `aud` のメンバー型（`typeof a !== 'string'`）と `exp` の数値型は検査するが、**スカラー `sub`・スカラー `aud`・`nonce` が文字列かどうか**を検査していない。数値・真偽値・オブジェクトが渡されても検証を通過し、構造的に不正な ID Token が署名・発行され得る。配列経路だけ厳格でスカラー経路が緩いという非対称であり、準拠 RP は `sub`/`aud` を文字列前提でパースするため相互運用が静かに壊れる。

詳細な検討は `study-material/done/id-token-scalar-claim-string-type-validation.md` を参照。空文字列（`study-material/done/id-token-empty-string-audience-scalar-rejection.md`）や charset（`study-material/done/sub-ascii-charset-enforcement.md`）とは別の「型」の軸。

## 対象ファイル

- `packages/core/src/id-token.ts`（`validatePayload`）
- `packages/core/src/id-token.test.ts`（テスト追加）

## 仕様参照

- RFC 7519 §4.1.2（`sub` = StringOrURI）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.2
- RFC 7519 §4.1.3（`aud` = StringOrURI or array thereof）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.3
- OpenID Connect Core 1.0 §2（`sub` は 255 ASCII 文字以内の識別子）/ §3.1.3.7（`nonce` は case sensitive string）

## 現状の実装

```ts
// packages/core/src/id-token.ts validatePayload
if (!payload.sub) { throw new Error('Missing required claim: sub'); }   // L96
if (payload.sub.length > 255) { ... }                                   // L101 : sub=12345 だと (12345).length===undefined で通過
if (payload.aud === undefined || payload.aud === null) { ... }         // L105 : スカラー非文字列を弾かない
if (Array.isArray(payload.aud) && payload.aud.length === 0) { ... }    // L110
if (Array.isArray(payload.aud)) {                                       // L117-123 : 配列のときだけ型検査
  for (const a of payload.aud) { if (typeof a !== 'string' || a.length === 0) throw ...; }
}
```

`sub` が数値 `12345` の場合、`!12345`（false）→ `(12345).length > 255`（`undefined > 255` は false）で全チェックを通過する。スカラー `aud`・`nonce` も型検査が無い。

## 修正方針

- [ ] スカラー経路に `typeof === 'string'` ガードを追加（study-material 方針A）
  - [ ] `sub`: 存在チェック直後に `typeof payload.sub !== 'string'` を拒否してから 255 文字チェックへ
  - [ ] `aud`: `Array.isArray` でない場合に `typeof payload.aud !== 'string'`（および空文字列）を拒否
  - [ ] `nonce`: 渡された場合 `typeof payload.nonce !== 'string'` を拒否
  - [ ] エラーメッセージは配列経路の既存文言と整合させる

実装例:
```ts
if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
  throw new Error('sub must be a non-empty string');
}
if (payload.sub.length > 255) { throw new Error('Subject identifier must not exceed 255 ASCII characters'); }
// aud
if (!Array.isArray(payload.aud)) {
  if (typeof payload.aud !== 'string' || payload.aud.length === 0) {
    throw new Error('aud must be a non-empty string or a non-empty array of strings');
  }
}
// nonce
if (payload.nonce !== undefined && typeof payload.nonce !== 'string') {
  throw new Error('nonce must be a string');
}
```

## テスト要件

- [ ] `sub` が数値・真偽値・オブジェクトのとき発行が拒否される
- [ ] スカラー `aud` が数値・オブジェクトのとき拒否される
- [ ] `nonce` が数値のとき拒否される
- [ ] 既存の正常系（文字列 `sub`/`aud`/`nonce`、配列 `aud`）がリグレッションしない
- [ ] 生成 OP の発行経路で不正型が渡り得るか確認し、必要なら `samples/*/conformance.test.ts`（生成元 `packages/cli`）に契約テストを追加

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
