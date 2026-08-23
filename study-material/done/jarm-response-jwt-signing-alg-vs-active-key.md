# JARM 応答 JWT の署名 alg が RS256 固定で、OP の active 署名鍵と不整合になりうる

## ステータス

🟠 High（実行時破綻 + Discovery の不正直）/ タスク化済み

タスク: `tasks/done/p2-jarm-response-jwt-rs256-key-selection.md`（方針A を採用）。
方針B（alg agility / `authorization_signed_response_alg` 対応）は保留のままで、
タスクのスコープ外として明記してある。

## 1. このトピックで確認したいこと

`packages/experimental/src/jarm/response-jwt.ts` の `createJarmResponseJwt()` は
JOSE ヘッダの `alg` を **`'RS256'` 定数で固定**し、Web Crypto の署名アルゴリズム名も
**`'RSASSA-PKCS1-v1_5'` 定数で固定**している。

一方、CLI 生成コードがこの関数へ渡す `signingKey` は
**OP の汎用 `signingKeyProvider` の active key**（`c.get('privateKey')`）である。

本 OP は T-022 以降 **RS256 + ES256 のような混在鍵セットを正式にサポート**しており、
active key が RS256 である保証はどこにも無い。確認したいのは次の 3 点。

1. active key が RS256 でないとき、JARM の認可レスポンスが実行時にどう壊れるか
2. その状態で Discovery が `authorization_signing_alg_values_supported: ['RS256']` を
   無条件に広告することが、相互運用性としてどう問題か
3. core にすでに存在する鍵選択ヘルパー（`selectSigningKeyByAlg`）で解消できるか

> 重複回避:
> - 署名アルゴリズムの拡張（PS256 / EdDSA）そのものは
>   `study-material/done/signing-alg-eddsa-ps256-interop.md` および
>   `tasks/p2-signing-alg-ps256.md` / `tasks/done/p3-signing-alg-eddsa-portability-investigation.md`。
>   本ファイルは**既存サポート範囲（RS256 / ES256）内での鍵選択の誤り**に限定する。
> - 複数鍵運用時の `kid` 必須化は `tasks/done/p2-id-token-kid-required-under-multiple-keys.md`。
>   本ファイルは `kid` ではなく `alg` と鍵の組み合わせの話。
> - JARM 拡張の導入検討そのものは `study-material/ext-jarm-jwt-secured-authorization-response.md`。
> - Discovery で JARM メタデータを core が表現できない件は
>   `study-material/done/discovery-metadata-experimental-features-core-expressibility.md`。
>   本ファイルは「広告する値そのものが実態と合わない」という別論点。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 JARM §3 Client Metadata — 既定 alg

一次資料（`https://openid.net/specs/oauth-v2-jarm.html`、2026-08-06 確認）:

> If unspecified, the default algorithm to use for signing authorization response is `RS256`.

本 OP はクライアント別の `authorization_signed_response_alg` を持たないため、
**「常に RS256 で署名する」という設計判断自体は仕様に適合している**。
問題は「RS256 で署名すると宣言しているのに、RS256 鍵で署名していない可能性がある」ことである。

### 2.2 JARM §4 Authorization Server Metadata

`authorization_signing_alg_values_supported` は
**OP が実際に応答 JWT の署名に使える alg** を広告するフィールドである。
OP が RS256 鍵を持たない構成でも `['RS256']` を無条件に出す実装は、
Discovery の honesty（広告と実挙動の一致）を破る。

本リポジトリはこの honesty を `buildProviderMetadata` で強く担保している。
`id_token_signing_alg_values_supported` は手書きの文字列配列を受け取らず、
**実際に登録された鍵から `getJwaAlgorithm` で導出する**設計で、その理由がコメントに明記されている
（`packages/core/src/discovery.ts` L28-31）:

> Letting the OP advertise an alg list it cannot actually sign with breaks
> client-side ID Token verification, so we derive the list from the actual
> keys instead of accepting a manual string list.

**JARM の広告値だけがこの原則から外れている。**

### 2.3 RFC 7515 §4.1.1 — `alg` ヘッダの意味

JOSE ヘッダの `alg` は「この JWS の署名がどのアルゴリズムで作られたか」を表明する。
実際の署名鍵と `alg` が食い違う JWS は、検証側から見て不正な JWS である。

### 2.4 OIDC Core 1.0 §15.1

RS256 のサポートは MUST。ただしこれは**鍵セット全体に対する要求**であり、
`assertHasRs256Key` は「鍵セットのどれか 1 本が RS256 であること」しか保証しない
（`packages/core/src/signing-key.ts` L82-86 のコメントが明示）。
**active key が RS256 であることは保証しない。**

## 3. 参照資料

- JARM §2.1 The JWT Response Document（`iss` / `aud` / `exp` が REQUIRED、
  最大寿命 10 分が RECOMMENDED）— https://openid.net/specs/oauth-v2-jarm.html
- JARM §3 Client Metadata（`authorization_signed_response_alg` の既定は RS256）— 同上
- JARM §4 Authorization Server Metadata（`authorization_signing_alg_values_supported`）— 同上
- RFC 7515 §4.1.1 "alg" (Algorithm) Header Parameter
  — https://www.rfc-editor.org/rfc/rfc7515#section-4.1.1
- OIDC Core 1.0 §15.1 Mandatory to Implement Features for All OpenID Providers
  — https://openid.net/specs/openid-connect-core-1_0.html#ServerMTI
- W3C Web Cryptography API — `SubtleCrypto.sign()` は
  鍵の `algorithm.name` と引数のアルゴリズムが一致しない場合 `InvalidAccessError` を投げる
  — https://www.w3.org/TR/WebCryptoAPI/#SubtleCrypto-method-sign

## 4. 現在の実装確認

### 4.1 固定されている 2 つの定数

`packages/experimental/src/jarm/response-jwt.ts`:

```ts
const RESPONSE_SIGNING_ALG = 'RS256';
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';
```

`createJarmResponseJwt()` 内:

```ts
const encodedHeader = base64UrlFromJson({
  alg: RESPONSE_SIGNING_ALG,          // 常に "RS256"
  kid: options.signingKey.keyId,      // active key の kid
});
...
const signature = await crypto.subtle.sign(
  WEB_CRYPTO_ALGORITHM,               // 常に RSASSA-PKCS1-v1_5
  options.signingKey.privateKey,      // active key（alg は不定）
  new TextEncoder().encode(signingInput),
);
```

コメントは設計意図をこう説明している:

> JARM §3: クライアントが `authorization_signed_response_alg` を登録していない
> 場合の既定は RS256。この OP はクライアント別 alg を持たないため RS256 固定と
> する。

**「OP が RS256 で署名する」という結論は正しいが、「渡された鍵が RS256 である」という
前提が検査されていない。**

### 4.2 渡される鍵は「汎用 active key」

`packages/cli/src/frameworks/hono/templates.ts` L4506-4517（`resolveJarmResponse`）:

```
// JARM Section 2.2: signed with the OP's general-purpose active signing key,
// whose public half is published at /.well-known/jwks.json under the same kid.
return {
  issuer: c.get('config').issuer,
  clientId: transaction.clientId,
  signingKey: {
    privateKey: c.get('privateKey'),
    publicJwk: c.get('publicJwk'),
    keyId: c.get('keyId'),
  },
};
```

`c.get('privateKey')` の出所は同ファイル L235:

```
signingKey = await options.signingKeyProvider.getSigningKey();
```

`SigningKeyProvider` の契約（`packages/core/src/signing-key.ts` L13-21）:

> `getSigningKey()` returns the key the OP should currently use to sign new
> tokens (the "active" key). `getSigningKeys()` is optional and returns every
> key the OP wants to advertise as verifiable — ... plus alternate-alg
> keys (e.g. RS256 + ES256) ...

**active key の alg は契約上 RS256 に限定されていない。**

### 4.3 破綻する具体的な構成

利用者が次の `SigningKeyProvider` を実装した場合（いずれも現行契約で正当）:

- `getSigningKey()` → **ES256 鍵**（active）
- `getSigningKeys()` → `[RS256 鍵, ES256 鍵]`（登録鍵セット）

このとき:

| 経路 | 結果 |
|---|---|
| `assertHasRs256Key(idTokenSigningKeys)` | ✅ 通る（鍵セットに RS256 が居る） |
| Discovery `id_token_signing_alg_values_supported` | `['RS256','ES256']`（鍵から導出、正しい） |
| Discovery `authorization_signing_alg_values_supported` | `['RS256']`（**無条件のハードコード**） |
| ID Token 署名 | 用途別 provider / `selectSigningKeyByAlg` 経由で正しく解決される |
| **JARM 応答 JWT 署名** | **`crypto.subtle.sign('RSASSA-PKCS1-v1_5', ES256鍵, ...)` → 実行時例外** |

JARM の署名は**認可レスポンスの配送経路**で起きるため、失敗すると
`response_mode=query.jwt` を要求したクライアントは認可コードを受け取れない。
しかも例外は Web Crypto 由来（`InvalidAccessError`）で、
「JARM の鍵選択が誤っている」という原因に到達しにくいメッセージになる。

### 4.4 core にはすでに正しい解決手段がある

`packages/core/src/signing-key.ts` の `selectSigningKeyByAlg(keys, requestedAlg)` は
まさにこの用途の関数であり、core の public API として export 済み
（`packages/core/src/index.ts` L229）。関数コメントも本件と同じ危険を指摘している:

> When no key matches, throws — the caller should map this to a server
> configuration error, since advertising an alg we cannot sign with would
> produce ID Tokens the client cannot verify.

ID Token 側はこの経路を通っているが、**JARM だけが active key を直接使っている**。

## 5. 現在の実装との差分

### 満たしていること

- ✅ 「RS256 で署名する」という方針自体は JARM §3 の既定と一致する。
- ✅ `alg: none` を生成する経路は存在しない（設定で alg を変えられない）。
- ✅ `kid` を JOSE ヘッダに含めており、JWKS 経由の検証鍵解決が可能。
- ✅ `iss` / `aud` / `exp` を応答パラメータから上書きできない実装になっている（JARM §2.1 の要求を満たす）。
- ✅ 既定の RS256 単一鍵構成（CLI が生成する既定の OP）では**現時点で問題は顕在化しない**。

### 不足している可能性があること

- 🟠 **`alg` ヘッダと実鍵の整合が保証されていない**。
  active key が RS256 でない構成で、JARM の認可レスポンスが実行時に失敗する。
- 🟠 **Discovery `authorization_signing_alg_values_supported` が鍵から導出されていない**。
  `id_token_signing_alg_values_supported` に適用されている「広告は実鍵から導出する」原則が、
  JARM の広告値にだけ適用されていない。
- 🟡 **起動時ガードが無い**。`assertParExpiresInSeconds` / `assertJarmLifetimeSeconds` のように
  JARM は設定値を起動時に検証する方針を取っているが、
  **鍵の alg だけは起動時に検証していない**。同じ方針を適用できるはずの箇所が抜けている。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 JARM 応答 JWT を **ID Token 用鍵ではなく汎用鍵**で署名する設計判断の是非。
  JARM は署名鍵の出所を規定しないので違反ではないが、
  用途別鍵（`idTokenSigningKeyProvider` / `userinfoSigningKeyProvider`）を用意している本 OP で
  JARM だけ汎用鍵を使う非対称は、鍵ローテーション運用時に混乱を招きうる
  （`study-material/signing-key-rotation-operations.md` と関連）。

### セキュリティ上、改善した方がよいこと

- 🟢 **偽造リスクは無い**。Web Crypto は鍵とアルゴリズムの不一致で署名を作らず例外を投げるため、
  「RS256 と称して別方式で署名された JWS」が生成されることはない。
  本件は**可用性（認可フローの破綻）と honesty（広告の不正確さ）の問題**であり、
  署名偽造や検証迂回の問題ではない。この区別は対応優先度の判断材料になる。

### 相互運用性の観点で改善した方がよいこと

- 🟠 クライアントは `authorization_signing_alg_values_supported` を見て検証器を構成する。
  広告が実態と乖離すると、クライアント側の自動構成が誤った前提で組み上がる。

## 6. 改善・追加を検討する理由

- **Fidelity**: 「広告する alg は実鍵から導出する」という原則を本リポジトリはすでに
  core で確立している。JARM だけが例外である状態は、原則の一貫性を損なう。
- **導入しやすさ**: 修正に必要な部品（`selectSigningKeyByAlg` / `getJwaAlgorithm` /
  `getRegisteredSigningKeys`）は**すべて core に実装済み・export 済み**。
  新規の設計判断はほぼ不要で、既存の ID Token 経路と同じ形に揃えるだけで済む。
- **既存実装との接続**: 生成テンプレートの `resolveJarmResponse` が
  `c.get('privateKey')` を読んでいる箇所を、`c.get('signingKeys')` +
  `selectSigningKeyByAlg(keys, 'RS256')` に差し替えるのが最短経路。
  `signingKeys` はすでにコンテキストに載っている（L238 `getRegisteredSigningKeys`）。
- **利用者へのメリット**: 混在鍵セット（RS256 + ES256）は本 OP が公式にサポートする構成であり、
  その構成で JARM が壊れないことは「どこでも動く」という Portability の主張に直結する。
- **実装しない場合に残るリスク**:
  - 混在鍵セット + JARM の利用者が、原因の分かりにくい実行時例外に遭遇する。
  - Discovery の広告が実態と乖離したまま残る。
  - 将来 PS256 / EdDSA を追加した際（`tasks/p2-signing-alg-ps256.md`）、
    同じ不整合が別 alg でも再発する。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: 鍵セットから RS256 鍵を明示的に選ぶ（推奨度：判断材料として最有力）

- 生成テンプレートの `resolveJarmResponse` で
  `selectSigningKeyByAlg(await getRegisteredSigningKeys(provider), 'RS256')` を使う。
- `createJarmResponseJwt` は RS256 固定のままでよい（JARM §3 の既定と一致）。
- RS256 鍵が無い構成では `selectSigningKeyByAlg` が throw するので、
  **設定ミスが認可フローではなく起動時／初回リクエストで露見する**。
- Discovery の `['RS256']` 広告は真になる。
- メリット: 変更が小さく、既存の ID Token 経路と同じ形。core 無変更。
- デメリット: JARM は常に RS256 に固定され、ES256 で署名したい利用者は選べない。

### 方針B: 鍵から alg を導出し、ヘッダと Web Crypto 名の両方を鍵に追従させる

- `createJarmResponseJwt` が `getJwaAlgorithm(signingKey.privateKey)` で alg を決め、
  RS256 / ES256 の双方に対応する（`jwaToWebCryptoParams` 相当のマッピングが必要）。
- Discovery の `authorization_signing_alg_values_supported` も同じ導出で組み立てる。
- メリット: 「広告は実鍵から導出する」原則に完全準拠。混在鍵セットでも壊れない。
- デメリット: JARM §3 の既定 RS256 から外れた alg で署名すると、
  `authorization_signed_response_alg` を登録していないクライアントが
  **既定の RS256 を期待して検証に失敗する**可能性がある。
  この方針を採るならクライアントメタデータ `authorization_signed_response_alg` の
  受け入れとセットにするのが筋であり、作業範囲が広がる。

### 方針C: 起動時アサーションだけ足す（最小）

- `assertJarmLifetimeSeconds` と同じ場所で、
  active key の `getJwaAlgorithm` が `'RS256'` であることを検証して起動を止める。
- メリット: 実装が最小。実行時の不可解な例外を、起動時の明確なエラーに置き換えられる。
- デメリット: 混在鍵セット構成では **JARM を有効にすると起動できなくなる**ため、
  問題を「早期に発見できる形」にしただけで、利用可能な構成は広がらない。

### 判断材料

- 既定構成（RS256 単一鍵）しか使わない利用者にとっては A / B / C のどれでも挙動は変わらない。
- **A は「JARM は RS256 固定」という現在の設計判断を維持したまま、その前提を実装で保証する**。
  設計判断を変えずに欠陥だけ塞ぐという意味で、影響範囲が最も読みやすい。
- B は将来 `authorization_signed_response_alg` に対応する布石になるが、
  単体で入れると JARM §3 の既定との齟齬を生むため、クライアントメタデータ対応と同時に検討すべき。
- C は A の劣化版に近い（A の方が利用可能な構成が広い）。A を採るなら C は不要。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採るかを人間が判断する
- [ ] 方針 A 採用時:
  - [ ] Hono テンプレートの `resolveJarmResponse` を、コンテキストの登録鍵セットから
        `selectSigningKeyByAlg(keys, 'RS256')` で鍵を選ぶ形に変更する
  - [ ] RS256 鍵が登録されていない構成で JARM を有効にした場合の失敗を、
        認可フローではなく起動時／初回リクエストの明示的なエラーとして扱う経路を決める
  - [ ] `createJarmResponseJwt` に「渡す鍵は RS256 でなければならない」旨を JSDoc で明記する
  - [ ] Discovery の `authorization_signing_alg_values_supported` が
        実際に JARM 署名に使う鍵の alg と一致することをテストで固定する
- [ ] テスト要件:
  - [ ] `createJarmResponseJwt` に ES256 鍵を渡したときの挙動を単体テストで固定する
        （現状は Web Crypto 例外。方針決定後は「明示的なエラー」へ）
  - [ ] `getSigningKey()` が ES256 / `getSigningKeys()` が `[RS256, ES256]` を返す
        provider を用いた統合テストで、JARM 認可レスポンスが成功することを確認する
  - [ ] 既定の RS256 単一鍵構成で生成される JWT がバイト単位で変わらないことを回帰テストで確認する
- [ ] `tasks/p2-signing-alg-ps256.md` を実施する際、JARM の alg 選択が同じ問題を再発させないか確認する
