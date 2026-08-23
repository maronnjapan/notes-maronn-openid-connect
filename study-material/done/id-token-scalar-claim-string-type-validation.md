# ID Token 発行時、スカラー `sub` / `aud` / `nonce` の「文字列型」を検証していない

## 1. このトピックで確認したいこと

`validateIdToken<Payload>`（発行前検証）は、配列 `aud` のメンバー型（`typeof a !== 'string'`）と `exp` / `iat` の数値型は検査するが、**スカラー値の `sub`・スカラー `aud`・`nonce` が実際に文字列かどうか**を検査していない。数値・真偽値・オブジェクトが渡されても検証を通過し、構造的に不正な ID Token がそのまま署名・発行され得る。

このトピックは「値が空文字列か」（`study-material/done/id-token-empty-string-audience-scalar-rejection.md`）や「文字列の charset」（`study-material/done/sub-ascii-charset-enforcement.md`）とは別の、**「そもそも文字列型か」というスカラー経路の型ガード欠落**という差分に限定する。

## 2. 関連する仕様・基準

JWT のクレーム型・ID Token 必須クレームの共通説明は `study-material/id-token-nonce-binding-and-replay.md` および `study-material/done/id-token-empty-string-audience-scalar-rejection.md` を参照し繰り返さない。ここでは型に関する差分のみ扱う。

- **RFC 7519 §4.1.2 (`sub`)**: `sub` は StringOrURI 値。数値・真偽値・オブジェクトは許容されない。
- **RFC 7519 §4.1.3 (`aud`)**: `aud` は StringOrURI 値、またはその配列。スカラー経路でも各値は文字列でなければならない。
- **OpenID Connect Core 1.0 §2 (ID Token)**: `sub` は「A locally unique and never reassigned identifier... It MUST NOT exceed 255 ASCII characters」。文字列であることが前提。`nonce` は §3.1.3.7 で「Case sensitive string」。

現状のコードは、配列 `aud` については既に厳格化されている（`typeof a !== 'string'` を拒否）。一方でスカラー経路は「存在するか（falsy でないか）」しか見ておらず、型そのもののガードが抜けている。

## 3. 参照資料

- RFC 7519 §4.1.2 Subject — https://www.rfc-editor.org/rfc/rfc7519#section-4.1.2
- RFC 7519 §4.1.3 Audience — https://www.rfc-editor.org/rfc/rfc7519#section-4.1.3
- OpenID Connect Core 1.0 §2 ID Token — https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- OpenID Connect Core 1.0 §3.1.3.7 ID Token Validation（`nonce` の型） — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
- 既存の関連記述（重複回避）: `study-material/done/id-token-empty-string-audience-scalar-rejection.md`（空文字列）、`study-material/done/sub-ascii-charset-enforcement.md`（charset）

## 4. 現在の実装確認

`packages/core/src/id-token.ts`（`validatePayload`）:

```ts
if (!payload.sub) {                                   // L96
  throw new Error('Missing required claim: sub');
}
// OIDC Core 1.0 Section 5.1: sub must not exceed 255 ASCII characters
if (payload.sub.length > 255) {                       // L101
  throw new Error('Subject identifier must not exceed 255 ASCII characters');
}

if (payload.aud === undefined || payload.aud === null) {   // L105
  throw new Error('Missing required claim: aud');
}
if (Array.isArray(payload.aud) && payload.aud.length === 0) {   // L110
  throw new Error('Audience must not be an empty array');
}
if (Array.isArray(payload.aud)) {                     // L117-123 : 配列のときだけ型検査
  for (const a of payload.aud) {
    if (typeof a !== 'string' || a.length === 0) {
      throw new Error('Audience array must contain only non-empty strings');
    }
  }
}
```

- `sub` が数値 `12345` の場合: `!12345` は `false`、`(12345).length` は `undefined`、`undefined > 255` は `false` → **すべて通過**。
- スカラー `aud`（配列でない）が数値やオブジェクトの場合: `undefined/null` チェック（L105）と「配列のときの空/型チェック」（L110・L117）を素通りする。
- `nonce` はオプションだが、渡された場合の型は検査されていない。

テスト（`packages/core/src/id-token.test.ts:824-826` 付近「strict aud typing」）は**配列メンバー**の型のみを固定しており、スカラー非文字列は未検証。

## 5. 現在の実装との差分

- **満たしていること**
  - `iss` / `sub` / `aud` / `exp` の存在検証、`exp` の数値型検証、配列 `aud` の空・型検証、`sub` の 255 文字上限。
- **不足している可能性があること**
  - スカラー `sub` の文字列型ガードが無い（数値・真偽値・オブジェクトが通る）。
  - スカラー `aud`（配列でない `aud`）の文字列型ガードが無い。
  - `nonce`（渡された場合）の文字列型ガードが無い。
- **セキュリティ／相互運用性の観点**
  - 直接の攻撃経路ではない（発行側が渡す値の型ミスに起因）が、resolver や生成コードのカスタマイズで誤った型を渡すと、構造的に不正な ID Token が署名・発行される。準拠 RP は `sub`/`aud` を文字列前提でパースするため、静かに相互運用が壊れる（型不整合の破損）。
  - 配列経路だけ厳格でスカラー経路が緩いという**非対称**は、コードのリファクタ時に「配列は守られているからスカラーも守られている」という誤解を生む。
- **Basic OP として確認すべきこと**
  - Basic OP 認定テストは正常系クレームの型を主に扱うため、認定可否に直結する可能性は低い。ただし本リポジトリが差別化軸に掲げる Fidelity の観点で、型の一貫した強制は主張の裏付けになる。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 配列経路には既に型ガードが入っているのに、スカラー経路だけ抜けている非対称は明確な実装の穴。修正は小さく、リグレッションのリスクも低い。
- **Basic OP 必須か拡張か**: 認定必須ではないが、ID Token の構造的正当性を担保する Fidelity ハードニング。
- **導入しやすさ**: `validatePayload` の該当箇所に `typeof === 'string'` ガードを 3 箇所足すだけ。配列経路の既存メッセージと整合させやすい。
- **既存実装との接続**: 配列 `aud` の `typeof a !== 'string'` ガード（L117-123）と同じ方針をスカラー経路に展開するだけで、コードの意図も揃う。
- **実装しない場合のリスク**: 発行側の型ミスが検知されず、破損 ID Token が発行される経路が残る。テストでも固定されないため、将来のリファクタで気付けない。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（スカラー経路に型ガード追加, 推奨）:
  - `sub`: 存在チェック直後に `typeof payload.sub !== 'string'` を拒否してから 255 文字チェックへ。
  - `aud`: `Array.isArray` でない場合に `typeof payload.aud !== 'string' || payload.aud.length === 0` を拒否（空文字列拒否は既存トピックと整合。空文字列の扱いは `study-material/done/id-token-empty-string-audience-scalar-rejection.md` に既出のため、本タスクでは「非文字列型」を主眼にしつつ空文字列も同時に弾く形で統合してよい）。
  - `nonce`: 渡された場合 `typeof payload.nonce !== 'string'` を拒否。
- 方針B（スキーマ的な一括検証）: クレーム型のスキーマを定義して一括検証する。網羅的だが、Web 標準のみ・外部依存なしの方針下では自前実装が増える。方針A の局所修正で十分と考えられる。

## 8. タスク案

- [ ] `id-token.test.ts` に先行テスト（Red）を追加:
  - [ ] `sub` が数値・真偽値・オブジェクトのとき発行が拒否される
  - [ ] スカラー `aud` が数値・オブジェクトのとき拒否される
  - [ ] `nonce` が数値のとき拒否される
  - [ ] 既存の正常系（文字列 `sub`/`aud`/`nonce`）がリグレッションしない
- [ ] `validatePayload` にスカラー経路の `typeof === 'string'` ガードを追加（方針A）
- [ ] 生成 OP の発行挙動は変えない（不正型は元々発行されない想定）が、`packages/cli` 側で型を渡す経路があるか確認し、必要なら `samples/*/conformance.test.ts`（生成元 `packages/cli`）に契約テストを追加
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス

## 関連トピック

- `study-material/done/id-token-empty-string-audience-scalar-rejection.md` — スカラー `aud` の**空文字列**拒否。本ファイルは**非文字列型**という別軸。
- `study-material/done/sub-ascii-charset-enforcement.md` — `sub` 文字列の charset。本ファイルは「そもそも文字列か」の型ガード。
