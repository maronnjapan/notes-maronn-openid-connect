# [P3] PAR / JARM の Discovery メタデータを core の `buildProviderMetadata` で表現できるようにする

## ステータス

🟡 Medium / 未着手

（生成される Discovery ドキュメントの**中身は現状すでに仕様どおり**。
本タスクは型安全性・検証の一元化・core 単独利用者への提供が目的であり、
出力 JSON は変えない。）

## 背景

`packages/experimental` に PAR（RFC 9126）と JARM が実装済みで出荷されているが、
これらを Discovery で広告するためのフィールドは
`packages/core/src/discovery.ts` の `ProviderMetadataConfig` に**一つも存在しない**。

そのため CLI 生成コードは `buildProviderMetadata()` が返したオブジェクトへ
**フィールドを後付けでマージする**回避策を取っている。テンプレートのコメント自身が
これを回避策と認めている。

```
// EXPERIMENTAL (JARM §4): authorization_signing_alg_values_supported has no
// core DiscoveryConfig field, so it is merged onto the metadata object the
// same way the PAR endpoint metadata is.
```

### 何が問題か

1. **core 単独利用者が拡張機能を広告できない**
   `CLAUDE.md` は `core` を「ロジック層（高度な組み込みユースケース向け）」と位置づけている。
   その利用者が `packages/experimental` の PAR / JARM を組み込んでも、
   `buildProviderMetadata()` の戻り値には該当フィールドが無く、
   手書きで `{ ...metadata, pushed_authorization_request_endpoint: ... }` を書くしかない。
   **フィールド名のタイプミスや RFC 9126 §5 の既定値規則の取り違えを型で防げない。**

2. **core のメタデータ検証が後付けフィールドに掛からない**
   `buildProviderMetadata` は issuer の https / query / fragment 検証、
   RS256 鍵の存在検証（`assertHasRs256Key`）、`claim_types_supported` の値検証を行うが、
   後からマージされる `pushed_authorization_request_endpoint` には何の検証も無い。
   `tasks/p3-discovery-endpoint-url-validation.md` が「全エンドポイント URL を issuer と同等に検証する」
   方針を検討しているが、**後付けフィールドはその実装が入っても検証対象外のまま**になる。

3. **フレームワーク間のドリフト**
   現在このマージは Hono テンプレートにしか無い。
   express / fastify / nextjs へ PAR / JARM を展開する際に同じマージを複製する必要があり、
   値や条件分岐がずれても型では検出できない。

### 前例はすでにある

core は RFC 8414 由来の `introspection_endpoint` / `revocation_endpoint` を
**すでに型で持っており**、その理由を明記している（`packages/core/src/discovery.ts` L71-73）。

```ts
// RFC 8414 (OAuth 2.0 Authorization Server Metadata) — advertised here
// because the major IdPs put them on this same document even though
// OIDC Discovery 1.0 itself does not define them.
```

つまり「OIDC Discovery 1.0 の定義外でも、実運用上必要なら core の型に載せる」という
**境界はすでに引かれている**。PAR / JARM だけがその前例から外れている。

### Token Exchange は対象外

RFC 8693 は専用の AS メタデータフィールドを定義せず、
`grant_types_supported` に grant type URN を載せることで広告する。
これは core の `grantTypesSupported` で表現できており、生成コードも正しくそうしている。
**本タスクの対象は PAR の 2 フィールドと JARM の 1 フィールドのみ。**

検討詳細は
`study-material/done/discovery-metadata-experimental-features-core-expressibility.md` を参照。

> 関連（重複回避）:
> - Discovery の任意メタデータ一般（`acr_values_supported` / `ui_locales_supported` 等）は
>   `study-material/discovery-optional-metadata-fields.md`。本タスクは拡張機能由来のフィールドに限る。
> - メタデータ自己整合ガードは `tasks/p3-discovery-metadata-basic-op-self-consistency-guard.md`。
> - エンドポイント URL 検証は `tasks/p3-discovery-endpoint-url-validation.md`。
>   本タスクが入ると、そちらの検証対象に PAR エンドポイントを含められるようになる。
> - JARM の広告値そのものが実鍵と乖離しうる件は
>   `tasks/done/p2-jarm-response-jwt-rs256-key-selection.md`（別タスク）。

## 対象ファイル

- `packages/core/src/discovery.ts`（`ProviderMetadataConfig` / `ProviderMetadata` / `buildProviderMetadata`）
- `packages/core/src/discovery.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（discovery ルートの後付けマージを引数へ移す）
- `packages/cli/src/__tests__/par-feature.test.ts`
- `packages/cli/src/__tests__/jarm-feature.test.ts`

## 仕様参照

- **RFC 9126 §5 Authorization Server Metadata**（一次資料、2026-08-06 確認）
  - `pushed_authorization_request_endpoint`:
    「The URL of the pushed authorization request endpoint at which a client can post an
    authorization request to exchange for a `request_uri` value usable at the authorization server.」
  - `require_pushed_authorization_requests`:
    「Boolean parameter indicating whether the authorization server accepts authorization
    request data only via PAR. **If omitted, the default value is `false`**.」
    → **既定が `false` なので、PAR が任意運用のときはフィールドを省略するのが正しい。**
      `false` を明示出力してはならない、という規則ではないが、
      既定の二重表明を避けるため省略する現行実装の判断を維持する。
- **JARM §4 Authorization Server Metadata**（一次資料、2026-08-06 確認）
  - `authorization_signing_alg_values_supported`
  - `authorization_encryption_alg_values_supported`
  - `authorization_encryption_enc_values_supported`
    → 本 OP は応答 JWT の暗号化を実装しないため、暗号化系 2 つは**省略が正しい**（省略＝非対応の表明）。
- **RFC 8414 §2**: AS メタデータの一般規則。値を持たないフィールドは省略する。
- **OIDC Discovery 1.0 §3 Provider Metadata**: 既存フィールドの出力規則。
  本リポジトリは「空配列は出力しない」規則をすでに実装している。

## 現状の実装

```ts
// packages/core/src/discovery.ts — PAR / JARM 由来のフィールドは存在しない
export interface ProviderMetadataConfig {
  issuer: string;
  ...
  // RFC 8414 由来はある
  introspectionEndpoint?: string;
  revocationEndpoint?: string;
  // pushedAuthorizationRequestEndpoint / authorizationSigningAlgValuesSupported は無い
}
```

```
// packages/cli/src/frameworks/hono/templates.ts — 後付けマージで回避
const metadata = buildProviderMetadata({ ...core が検証する範囲... });

return c.json({
  ...metadata,
  // ここから先は core の検証が一切掛からない
  authorization_signing_alg_values_supported: ['RS256'],          // JARM
  pushed_authorization_request_endpoint: `${issuer}/par`,          // PAR
  ...(parConfig.requirePushedAuthorizationRequests
    ? { require_pushed_authorization_requests: true }
    : {}),
});
```

構造を図にすると次のとおりで、検証境界が二層に割れている。

```
buildProviderMetadata(config)        ← core の検証が掛かる範囲
        │  返り値
        ▼
{ ...metadata,                        ← ここから先は検証なし
  authorization_signing_alg_values_supported: [...],
  pushed_authorization_request_endpoint: ...,
  ...(require_pushed_authorization_requests) }
```

## 修正方針

- [ ] `ProviderMetadataConfig` に optional フィールドを追加する（RFC 8414 前例と同じコメント様式で）

  ```ts
  // RFC 9126 §5 (Pushed Authorization Requests) — advertised here for the same
  // reason as the RFC 8414 fields above: the endpoint lives on this document even
  // though OIDC Discovery 1.0 does not define it.
  pushedAuthorizationRequestEndpoint?: string;
  /**
   * RFC 9126 §5: the default is false. Pass `true` ONLY when PAR is actually
   * enforced; leave undefined to omit the field (= advertise the default).
   */
  requirePushedAuthorizationRequests?: boolean;
  /**
   * JARM §4: JWS `alg` values the OP can use to sign JWT authorization responses.
   * Advertise only when the OP actually implements a JWT response mode.
   */
  authorizationSigningAlgValuesSupported?: string[];
  ```

- [ ] `ProviderMetadata`（snake_case 出力型）に対応するフィールドを追加する
- [ ] `buildProviderMetadata` の出力規則を既存と揃える
  - [ ] `pushedAuthorizationRequestEndpoint`: 値があるときだけ出力（既存の endpoint 系と同じ）
  - [ ] `requirePushedAuthorizationRequests`: **`true` のときだけ出力**する。
        `false` / `undefined` では省略し、RFC 9126 §5 の既定を二重に表明しない。
        ※ `claimsParameterSupported` 等の既存 boolean は `!== undefined` で出力しているが、
        本フィールドは「既定 false を省略で表現する」現行の生成コード挙動を保つため
        意図的に規則を変える。**この非対称の理由をコメントに明記すること。**
  - [ ] `authorizationSigningAlgValuesSupported`: 空配列なら省略（既存の配列系と同じ）
- [ ] Hono テンプレートの discovery ルートから後付けマージを削除し、
      `buildProviderMetadata` の引数へ移す
  - [ ] `parConfig.requirePushedAuthorizationRequests` が `false` のときは
        `undefined` を渡す（`false` をそのまま渡しても省略されるが、意図を明示する）
- [ ] JARM の暗号化メタデータ（`authorization_encryption_*`）を追加しない判断を、
      「本 OP は応答 JWT の暗号化を実装しないため省略＝非対応の表明」としてコメントに明記する

## テスト要件

- [ ] `buildProviderMetadata` の単体テスト（`packages/core/src/discovery.test.ts`）
  - [ ] `pushedAuthorizationRequestEndpoint` 未指定時、
        戻り値に `pushed_authorization_request_endpoint` キーが**存在しない**ことを検証する
  - [ ] 指定時、値が `toBe` で一致することを検証する
  - [ ] `requirePushedAuthorizationRequests` が `undefined` のときキーが存在しないこと
  - [ ] `false` のときも**キーが存在しない**こと（既定の二重表明を避ける規則の固定）
  - [ ] `true` のとき `require_pushed_authorization_requests: true` が出力されること
  - [ ] `authorizationSigningAlgValuesSupported: []` のときキーが存在しないこと
  - [ ] `['RS256']` のとき `toEqual(['RS256'])` で固定すること
- [ ] 生成コードの回帰テスト
  - [ ] `--enable par` で生成した OP の Discovery レスポンスが、
        **変更前と JSON として同一**であることを確認する（キー順を含めて差分が出る場合は
        キー集合と各値の一致で固定する）
  - [ ] `--enable jarm` でも同様
  - [ ] PAR / JARM を有効にしない生成物がバイト単位で変わらないことを確認する
  - [ ] `parConfig.requirePushedAuthorizationRequests` の true / false で
        フィールドの有無が切り替わる既存テスト
        （`packages/cli/src/frameworks/hono/templates.ts` L9074-9090 相当）が
        引き続き通ることを確認する

## 完了条件

- [ ] `packages/cli` の discovery テンプレートに、`buildProviderMetadata` の外側で
      メタデータフィールドを足すコードが残っていない
- [ ] `--enable par` / `--enable jarm` で生成した OP の Discovery レスポンスが変更前と同一
- [ ] PAR / JARM 無効時の生成物に差分が無い
- [ ] core 単独利用者が `buildProviderMetadata` の引数だけで
      PAR / JARM のメタデータを広告できる
- [ ] 以下がすべて通る

```bash
pnpm --filter @maronn-openid-connect/core test
pnpm --filter @maronn-openid-connect/cli test
pnpm test
```

## 後続作業（本タスクの範囲外）

- `tasks/p3-discovery-endpoint-url-validation.md` の検証対象に
  `pushed_authorization_request_endpoint` を含める（本タスク完了後に可能になる）
- express / fastify / nextjs テンプレートへ PAR / JARM を展開する際、
  広告は `buildProviderMetadata` の引数経由に統一する
