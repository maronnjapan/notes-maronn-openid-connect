# 出荷済み Experimental 機能（PAR / JARM / Token Exchange）の Discovery メタデータが core で表現できない

## ステータス

🟡 Medium / タスク化済み

タスク: `tasks/p3-discovery-metadata-experimental-fields.md`（方針A を採用）。
方針B（汎用エスケープハッチ）は将来の未知拡張向けに保留。

## 1. このトピックで確認したいこと

`packages/experimental` に **PAR（RFC 9126）/ JARM / Token Exchange（RFC 8693）が実装済みで出荷されている**。
一方、これらを Discovery で広告するためのメタデータフィールドは `packages/core/src/discovery.ts` の
`ProviderMetadataConfig` に**一つも存在しない**。

その結果、CLI 生成コードは `buildProviderMetadata()` が返したオブジェクトへ
**フィールドを後付けでマージする**という回避策を取っている。本トピックで確認したいのは次の 3 点。

1. 拡張機能のメタデータを core の型で表現できないことが、相互運用性・利用者体験にどう影響するか
2. 後付けマージによって、core が持つメタデータ検証（RS256 必須・`claim_types_supported` の正当性検証など）が
   拡張フィールドに適用されない状態をどう扱うか
3. core を直接使う利用者（CLI を通さない「ロジック層」ユースケース）が拡張機能を広告する手段が無い問題

> 重複回避:
> - 個々の拡張機能を「入れるべきか」という導入検討そのものは
>   `study-material/ext-pushed-authorization-requests-rfc9126.md` /
>   `study-material/ext-jarm-jwt-secured-authorization-response.md` /
>   `study-material/ext-token-exchange-rfc8693.md` が扱う（いずれも実装前に書かれた検討文書）。
>   本ファイルは**実装が出荷された後の Discovery 表現**という別論点に限定する。
> - Discovery の任意メタデータ一般（`acr_values_supported` / `ui_locales_supported` 等）は
>   `study-material/discovery-optional-metadata-fields.md`。本ファイルは拡張機能由来のフィールドに限る。
> - メタデータの自己整合ガードは `tasks/p3-discovery-metadata-basic-op-self-consistency-guard.md`、
>   エンドポイント URL 検証は `tasks/p3-discovery-endpoint-url-validation.md`。
>   本ファイルは「そのガードが後付けフィールドに掛からない」という差分だけを述べる。

## 2. 関連する仕様・基準（このトピック固有の差分）

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。

### 2.1 RFC 9126 §5 Authorization Server Metadata

一次資料の文言（2026-08-06 確認）:

- `pushed_authorization_request_endpoint`:
  "The URL of the pushed authorization request endpoint at which a client can post an
  authorization request to exchange for a `request_uri` value usable at the authorization server."
- `require_pushed_authorization_requests`:
  "Boolean parameter indicating whether the authorization server accepts authorization request data
  only via PAR. **If omitted, the default value is `false`**."

つまり PAR を実装した AS は、クライアントが PAR エンドポイントを発見できるよう
`pushed_authorization_request_endpoint` をメタデータに出す必要がある。
`require_pushed_authorization_requests` は既定 `false` なので、
**PAR が任意運用のときは省略するのが正しい**（現行の生成コードはこの規則を正しく実装している）。

### 2.2 JARM §4 Authorization Server Metadata

一次資料（`https://openid.net/specs/oauth-v2-jarm.html`、2026-08-06 確認）で
**§4 が Authorization Server Metadata** であり、次の 3 つを定義する。

- `authorization_signing_alg_values_supported`
- `authorization_encryption_alg_values_supported`
- `authorization_encryption_enc_values_supported`

また **§3 Client Metadata** が `authorization_signed_response_alg` を定義し、
"If unspecified, the default algorithm to use for signing authorization response is `RS256`." と述べる。
本 OP はクライアント別 alg を持たないため RS256 固定であり、この既定と一致する。

`response_modes_supported` に `query.jwt` / `jwt` を含める点は OIDC Discovery 1.0 §3 の
`response_modes_supported` の枠内で表現でき、こちらは **core の既存フィールドで表現できている**。

### 2.3 RFC 8693 / RFC 8414 §2

Token Exchange は専用の AS メタデータフィールドを定義せず、
`grant_types_supported` に grant type URN
`urn:ietf:params:oauth:grant-type:token-exchange` を載せることで広告する。
`grant_types_supported` は core の `ProviderMetadataConfig.grantTypesSupported` で表現できるため、
**Token Exchange だけは既存フィールドで足りている**（実際、生成コードはそうしている）。

したがって core で表現できないのは **PAR の 2 フィールドと JARM の 1〜3 フィールド**である。

## 3. 参照資料

- RFC 9126 §5 Authorization Server Metadata（`pushed_authorization_request_endpoint` /
  `require_pushed_authorization_requests` の定義と既定値 `false`）
  — https://datatracker.ietf.org/doc/html/rfc9126#section-5
- RFC 9126 §2.2（`request_uri` は "single-use reference"、`expires_in` は「典型的に 5〜600 秒」）
  — https://datatracker.ietf.org/doc/html/rfc9126#section-2.2
- JARM §4 Authorization Server Metadata / §3 Client Metadata（既定 alg = RS256）
  — https://openid.net/specs/oauth-v2-jarm.html
- RFC 8693 §2.1（grant type URN）— https://www.rfc-editor.org/rfc/rfc8693#section-2.1
- RFC 8414 §2 Authorization Server Metadata — https://www.rfc-editor.org/rfc/rfc8414#section-2
- OIDC Discovery 1.0 §3 Provider Metadata
  — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata

## 4. 現在の実装確認

### 4.1 core 側（表現手段が無い）

`packages/core/src/discovery.ts`:

- `ProviderMetadataConfig` / `ProviderMetadata` に PAR・JARM 由来のフィールドは無い。
- RFC 8414 由来の `introspection_endpoint` / `revocation_endpoint` **は**追加されており、
  型定義に次のコメントがある（L71-73）。

  ```ts
  // RFC 8414 (OAuth 2.0 Authorization Server Metadata) — advertised here
  // because the major IdPs put them on this same document even though
  // OIDC Discovery 1.0 itself does not define them.
  ```

  つまり「OIDC Discovery 1.0 の定義外でも、実運用上必要なら core の型に載せる」という
  **前例がすでに確立している**。PAR / JARM だけがその前例から外れている。

### 4.2 CLI 生成コード側（後付けマージで回避）

`packages/cli/src/frameworks/hono/templates.ts`:

- L4040-4048（JARM）— コメントで回避策であることを明示している。

  ```
  // EXPERIMENTAL (JARM §4): authorization_signing_alg_values_supported has no
  // core DiscoveryConfig field, so it is merged onto the metadata object the
  // same way the PAR endpoint metadata is.
      authorization_signing_alg_values_supported: ['RS256'],
  ```

- L4050-4063（PAR）— 同様。`require_pushed_authorization_requests` は
  `parConfig.requirePushedAuthorizationRequests` が真のときだけ条件付きスプレッドで追加する
  （RFC 9126 §5 の既定 `false` を正しく踏まえた実装）。

  ```
  // EXPERIMENTAL (RFC 9126 §5): pushed_authorization_request_endpoint is merged
  // onto the metadata object core builds, so core needs no change to advertise it.
      pushed_authorization_request_endpoint: `${issuer}/par`,
      ...(parConfig.requirePushedAuthorizationRequests
        ? { require_pushed_authorization_requests: true }
        : {}),
  ```

- Token Exchange は L372 / L3978 で `grantTypesSupported` に URN を足すだけで、
  core のフィールドを正しく使っている。

### 4.3 実際の広告フローの構造

```
buildProviderMetadata(config)        ← core の検証が掛かる範囲
        │  返り値
        ▼
{ ...metadata,                        ← ここから先は検証が掛からない
  authorization_signing_alg_values_supported: [...],   （JARM）
  pushed_authorization_request_endpoint: ...,          （PAR）
  ...(require_pushed_authorization_requests) }
```

## 5. 現在の実装との差分

### 満たしていること

- ✅ 生成された OP が出力する Discovery ドキュメントの**中身は仕様どおり**である。
  フィールド名・値・`require_pushed_authorization_requests` の既定省略はいずれも RFC 9126 §5 / JARM §4 に一致する。
- ✅ `conformance.test.ts` が `pushed_authorization_request_endpoint` の値と
  `require_pushed_authorization_requests` の省略／付与を回帰テストで固定している
  （`packages/cli/src/frameworks/hono/templates.ts` L9074-9090）。
- ✅ Token Exchange は既存の `grantTypesSupported` で正しく表現されている。

### 不足している可能性があること

- 🟡 **core 単独利用者が拡張機能を広告できない**。
  `CLAUDE.md` は `core` を「ロジック層（高度な組み込みユースケース向け）」と位置づけている。
  その利用者が `packages/experimental` の PAR / JARM を組み込んでも、
  `buildProviderMetadata()` の戻り値には該当フィールドが無く、
  自力で `{ ...metadata, pushed_authorization_request_endpoint: ... }` を書く必要がある。
  **フィールド名のタイプミスや RFC 9126 §5 の既定値規則の取り違えが型で防げない。**
- 🟡 **core の検証が後付けフィールドに掛からない**。
  `buildProviderMetadata` は issuer の https / query / fragment 検証、RS256 鍵の存在検証
  （`assertHasRs256Key`）、`claim_types_supported` の値検証を行うが、
  後からマージされる `pushed_authorization_request_endpoint` には何の検証も無い。
  `tasks/p3-discovery-endpoint-url-validation.md` が「全エンドポイント URL を issuer と同等に検証する」
  方針を検討しているが、**後付けフィールドはその実装が入っても検証対象にならない**。
- 🟡 **フレームワーク間のドリフト**。現在このマージは Hono テンプレートに書かれている。
  express / fastify / nextjs テンプレートへ PAR / JARM を展開する際、
  同じマージを各テンプレートへ複製する必要があり、値・条件分岐がずれても
  型では検出できない（`packages/cli` のテンプレート横断の検証手段が無い）。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **JARM の暗号化メタデータを広告しない判断の明文化**。
  JARM §4 は `authorization_encryption_alg_values_supported` /
  `authorization_encryption_enc_values_supported` も定義するが、本 OP は応答 JWT の暗号化を実装しない。
  仕様上、非対応なら省略が正しい（省略＝非対応の表明）ので違反ではないが、
  「省略は意図的」であることがコードにもドキュメントにも書かれていない。

### セキュリティ上、改善した方がよいこと

- 🟢 本トピック自体は直接の脆弱性ではない。ただし
  `require_pushed_authorization_requests: true` を広告しているのに実際には PAR を強制していない
  （あるいは逆）という**広告と実挙動の乖離**が起きると、クライアントの安全側の前提が崩れる。
  現在は `parConfig` から導出しているため乖離しないが、この不変条件は型ではなく
  テンプレートの記述に依存している。

### 相互運用性の観点で改善した方がよいこと

- 🟡 Discovery は「クライアントの自動構成」のための機構であり、
  **広告できない機能は実質的に存在しないのと同じ**。core 利用者にとって PAR / JARM は
  「動くが発見されない」状態になる。

## 6. 改善・追加を検討する理由

- **Fidelity**: 本リポジトリは「仕様を忠実に」を差別化軸に置いている。
  RFC 9126 §5 / JARM §4 が定義するメタデータを型で表現できないのは、
  仕様の一部を実装が取りこぼしている状態である。
- **導入しやすさ**: `ProviderMetadataConfig` に optional フィールドを足すのは
  **既存の RFC 8414 フィールド（introspection / revocation）と完全に同じパターン**であり、
  設計判断としての新規性が無い。前例に沿った追加で済む。
- **後方互換**: すべて optional フィールドとして追加すれば、既存の呼び出し側は無変更で動く。
  生成テンプレートは後付けマージをやめて `buildProviderMetadata` の引数へ移すだけになり、
  出力される JSON は同一に保てる（回帰テストで固定できる）。
- **core / experimental の依存方向**: core が experimental へ依存してはならないが、
  **メタデータのフィールド名は単なる文字列定数**であり、型の追加は依存を生まない。
  RFC 8414 のフィールドを core が持っているのと同じ理屈で成立する。
- **実装しない場合に残る制約**:
  - core 単独利用者は拡張機能を広告できず、手書きマージのミスを型で防げない。
  - エンドポイント URL 検証・自己整合ガードの適用範囲に恒久的な穴が残る。
  - フレームワークテンプレートを増やすたびにマージ処理を複製する保守コストが増える。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: `ProviderMetadataConfig` に optional フィールドを追加する（RFC 8414 前例踏襲）

```ts
// RFC 9126 §5 (PAR) — advertised here for the same reason as the RFC 8414
// fields above: the endpoint lives on this document even though OIDC
// Discovery 1.0 does not define it.
pushedAuthorizationRequestEndpoint?: string;
/**
 * RFC 9126 §5: default is false. Pass true ONLY when PAR is actually enforced;
 * leave undefined to omit the field (= advertise the default).
 */
requirePushedAuthorizationRequests?: boolean;
// JARM §4
authorizationSigningAlgValuesSupported?: string[];
```

- 出力側は既存フィールドと同じ「値があるときだけ載せる」規則に従う。
- `requirePushedAuthorizationRequests` は **`true` のときだけ出力**し、
  `false` / `undefined` では省略する（RFC 9126 §5 の既定を二重に表明しない）。
- 生成テンプレートは後付けマージを削除し、`buildProviderMetadata` の引数へ移す。
- メリット: 型安全・検証の一元化・テンプレート横断の重複解消。
- デメリット: core の型が experimental 機能名を知ることになる（ただし文字列定数のみ）。

### 方針B: 拡張メタデータ用の汎用エスケープハッチを設ける

```ts
/** 仕様で定義済みだが core が型を持たないメタデータ。値はそのまま出力される。 */
additionalMetadata?: Record<string, unknown>;
```

- メリット: core が個別の拡張仕様を知らずに済む。将来の拡張にも無変更で対応。
- デメリット: フィールド名のタイプミスを型で防げず、方針Aの主目的（型安全）を達成しない。
  検証も掛けにくい。
- 方針A と併用（既知は型、未知はエスケープハッチ）なら合理的。

### 方針C: 現状維持＋明文化

- 後付けマージのままとし、「core は Basic OP の範囲だけを型で表現する。
  experimental のメタデータは生成コード側の責務」とドキュメントに明記する。
- メリット: 変更ゼロ。core の責務境界が明確。
- デメリット: core 単独利用者の問題と検証の穴は残る。

### 判断材料

- core が RFC 8414 の introspection / revocation を**すでに型で持っている**以上、
  「core は OIDC Discovery 1.0 の定義だけを持つ」という境界はすでに引かれていない。
  方針C を採るなら、その非対称の理由（experimental は API 不安定だから、等）を明示する必要がある。
- 方針A のコストは小さいが、`packages/experimental` の API が不安定であることと
  「core の型は安定させたい」方針が衝突しうる。ただし追加するのは**仕様側で確定した文字列**であり、
  experimental の API 変更に追随する必要は無い点は方針A に有利。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採るかを人間が判断する
- [ ] 方針 A 採用時:
  - [ ] `ProviderMetadataConfig` / `ProviderMetadata` に
        `pushedAuthorizationRequestEndpoint` / `requirePushedAuthorizationRequests` /
        `authorizationSigningAlgValuesSupported` を optional で追加する
  - [ ] `requirePushedAuthorizationRequests` は `true` のときだけ出力する分岐を実装する
  - [ ] `buildProviderMetadata` のテストに、値なし＝フィールド省略／`false`＝省略／`true`＝出力を追加する
  - [ ] Hono テンプレートの後付けマージを削除し `buildProviderMetadata` の引数へ移す
  - [ ] 生成された Discovery JSON がバイト単位で変わらないことを `conformance.test.ts` で確認する
  - [ ] JARM の暗号化メタデータを省略する判断（＝非対応の表明）をコメントで明文化する
- [ ] `tasks/p3-discovery-endpoint-url-validation.md` の対象に PAR エンドポイント URL を含めるかを確認する
- [ ] express / fastify / nextjs テンプレートへ PAR / JARM を展開する際の広告手順を決める
