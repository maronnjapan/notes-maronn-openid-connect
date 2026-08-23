# [P2] JARM 応答 JWT を必ず RS256 鍵で署名する（active key 直接使用をやめる）

## ステータス

🟡 Medium / 未着手

（既定構成 = RS256 単一鍵では顕在化しない。RS256 + ES256 の混在鍵セットという
**本 OP が公式にサポートする構成**で JARM を有効にしたときに認可フローが実行時に壊れる。）

## 背景

`packages/experimental/src/jarm/response-jwt.ts` の `createJarmResponseJwt()` は、
JOSE ヘッダの `alg` を `'RS256'` 定数で、Web Crypto の署名アルゴリズム名を
`'RSASSA-PKCS1-v1_5'` 定数で**固定**している。

一方、CLI 生成コードがこの関数へ渡す鍵は
**OP の汎用 `signingKeyProvider` の active key**（`c.get('privateKey')`）であり、
`SigningKeyProvider` の契約上、この鍵が RS256 である保証は無い。

`SigningKeyProvider` の JSDoc（`packages/core/src/signing-key.ts` L13-21）は
`getSigningKeys()` が「alternate-alg keys (e.g. RS256 + ES256)」を返しうると明記しており、
T-022 以降この混在鍵セットは正式サポートされている。

### 影響

`getSigningKey()`（active）が ES256、`getSigningKeys()` が `[RS256, ES256]` を返す
provider（いずれも現行契約で正当）を利用者が実装した場合:

| 経路 | 結果 |
|---|---|
| `assertHasRs256Key(idTokenSigningKeys)` | ✅ 通る（鍵セットに RS256 が居る） |
| Discovery `id_token_signing_alg_values_supported` | `['RS256','ES256']`（鍵から導出。正しい） |
| Discovery `authorization_signing_alg_values_supported` | `['RS256']`（**無条件ハードコード**。実態と乖離） |
| ID Token 署名 | 正しく解決される |
| **JARM 応答 JWT 署名** | **`crypto.subtle.sign('RSASSA-PKCS1-v1_5', ES256鍵, ...)` → 実行時例外** |

JARM の署名は**認可レスポンスの配送経路**で起きるため、失敗すると
`response_mode=query.jwt` を要求したクライアントは認可コードを受け取れない。
例外は Web Crypto 由来（`InvalidAccessError`）で、
「JARM の鍵選択が誤っている」という原因に到達しにくい。

### 偽造リスクは無い（優先度判断のため明記）

Web Crypto は鍵とアルゴリズムの不一致で署名を作らず例外を投げるため、
「RS256 と称して別方式で署名された JWS」が生成されることはない。
本件は**可用性（認可フローの破綻）と Discovery honesty（広告の不正確さ）**の問題であり、
署名偽造・検証迂回の問題ではない。

### 本リポジトリの確立済み原則からの逸脱

`packages/core/src/discovery.ts` L28-31 は、広告 alg を手書き配列で受け取らず
実鍵から導出する理由をこう述べている。

> Letting the OP advertise an alg list it cannot actually sign with breaks
> client-side ID Token verification, so we derive the list from the actual
> keys instead of accepting a manual string list.

**JARM の署名鍵選択と広告値だけがこの原則の外にある。**

検討詳細は `study-material/done/jarm-response-jwt-signing-alg-vs-active-key.md` を参照。

> 関連（重複回避）:
> - PS256 / EdDSA など**署名 alg の拡張**は `tasks/p2-signing-alg-ps256.md` /
>   `tasks/done/p3-signing-alg-eddsa-portability-investigation.md`。
>   本タスクは**既存サポート範囲（RS256 / ES256）内の鍵選択の誤り**に限定し、
>   JARM が扱える alg を増やすことは**目的としない**（それは方針B として study-material に保留）。
> - 複数鍵運用時の `kid` 必須化は `tasks/done/p2-id-token-kid-required-under-multiple-keys.md`。
>   本タスクは `kid` ではなく `alg` と鍵の組み合わせ。
> - JARM メタデータを core の型で表現できない件は
>   `tasks/p3-discovery-metadata-experimental-fields.md`（別タスク）。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  （`resolveJarmResponse` と、authorize ルート側の `jarmResponse` 組み立ての 2 箇所）
- `packages/experimental/src/jarm/response-jwt.ts`（JSDoc への前提明記）
- `packages/experimental/src/jarm/response-jwt.test.ts`
- `packages/cli/src/__tests__/jarm-feature.test.ts`
- 生成される `conformance.test.ts`（JARM 有効時）を出力する CLI テンプレート側

## 仕様参照

- **JARM §3 Client Metadata**: 「If unspecified, the default algorithm to use for signing
  authorization response is `RS256`.」
  → **「常に RS256 で署名する」という現在の設計判断自体は仕様に適合している。**
  本タスクはその設計判断を変えず、前提（渡される鍵が RS256）を実装で保証する。
- **JARM §4 Authorization Server Metadata**: `authorization_signing_alg_values_supported` は
  OP が実際に応答 JWT の署名に使える alg を広告するフィールド。
- **JARM §2.1 The JWT Response Document**: `iss` / `aud` / `exp` は REQUIRED。
  最大寿命 10 分が RECOMMENDED（既存実装は `assertJarmLifetimeSeconds` で 5〜600 秒に制約済み）。
- **RFC 7515 §4.1.1**: JOSE ヘッダの `alg` は「この JWS の署名がどのアルゴリズムで作られたか」の表明。
  実鍵と食い違う JWS は検証側から見て不正。
- **OIDC Core 1.0 §15.1**: RS256 サポートは MUST。ただしこれは**鍵セット全体**への要求であり、
  `assertHasRs256Key`（`packages/core/src/signing-key.ts` L82-86 のコメント）は
  「鍵セットのどれか 1 本が RS256」しか保証せず、**active key が RS256 であることは保証しない**。

## 現状の実装

```ts
// packages/experimental/src/jarm/response-jwt.ts
const RESPONSE_SIGNING_ALG = 'RS256';
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';

export async function createJarmResponseJwt(options: {
  ...
  signingKey: SigningKey;      // ← alg は不定
}): Promise<string> {
  const encodedHeader = base64UrlFromJson({
    alg: RESPONSE_SIGNING_ALG,          // 常に "RS256" と表明
    kid: options.signingKey.keyId,
  });
  ...
  const signature = await crypto.subtle.sign(
    WEB_CRYPTO_ALGORITHM,               // 常に RSASSA-PKCS1-v1_5
    options.signingKey.privateKey,      // ← RS256 とは限らない
    new TextEncoder().encode(signingInput),
  );
}
```

```
// packages/cli/src/frameworks/hono/templates.ts（resolveJarmResponse）
// JARM Section 2.2: signed with the OP's general-purpose active signing key,
// whose public half is published at /.well-known/jwks.json under the same kid.
return {
  issuer: c.get('config').issuer,
  clientId: transaction.clientId,
  signingKey: {
    privateKey: c.get('privateKey'),    // ← signingKeyProvider.getSigningKey() の戻り
    publicJwk: c.get('publicJwk'),
    keyId: c.get('keyId'),
  },
};
```

### core にはすでに正しい解決手段がある

`selectSigningKeyByAlg(keys, requestedAlg)`（`packages/core/src/signing-key.ts` L56-77）は
まさにこの用途の関数で、core の public API として export 済み（`packages/core/src/index.ts` L229）。
関数コメント自身が本件と同じ危険を指摘している。

> When no key matches, throws — the caller should map this to a server
> configuration error, since advertising an alg we cannot sign with would
> produce ID Tokens the client cannot verify.

生成コードのコンテキストには登録鍵セットがすでに載っている
（`packages/cli/src/frameworks/hono/templates.ts` L238 の `getRegisteredSigningKeys`）ため、
**新しい配線を作らずに解決できる**。

## 修正方針

- [ ] 生成テンプレートの `resolveJarmResponse` を、active key 直接使用から
      **登録鍵セットからの RS256 鍵選択**へ変更する
  - [ ] コンテキストの登録鍵セット（`signingKeys`）を読む
  - [ ] `selectSigningKeyByAlg(signingKeys, 'RS256')` で鍵を選ぶ
  - [ ] 鍵セットが空／未設定の場合は従来どおり active key へフォールバックする
        （後方互換。単一鍵構成では選択結果が active key と一致するため挙動不変）
  - [ ] authorize ルート側の `jarmResponse` 組み立て（同ファイル L1918 付近）も同じ形に揃える

  ```ts
  // 変更後のイメージ（生成コード側）
  const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
  const jarmSigningKey = jarmSigningKeys.length > 0
    // JARM §3: この OP は常に RS256 で署名すると表明しているので、
    // active key ではなく登録鍵セットから RS256 鍵を選ぶ。
    // RS256 鍵が無ければ selectSigningKeyByAlg が throw し、設定ミスとして露見する。
    ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
    : { privateKey: c.get('privateKey'), publicJwk: c.get('publicJwk'), keyId: c.get('keyId') };
  ```

- [ ] `createJarmResponseJwt` の JSDoc に
      「`signingKey` は RS256 鍵でなければならない（JARM §3 の既定 alg に合わせる）」旨を明記する
- [ ] `resolveJarmResponse` のコメントを実態に合わせて修正する
      （現在の「signed with the OP's general-purpose **active** signing key」は変更後に不正確になる）
- [ ] RS256 鍵が登録されていない構成で JARM を有効にした場合、
      `selectSigningKeyByAlg` の throw が**認可フローの途中ではなく明示的な設定エラー**として
      扱われる経路を確認する（authorize ルートの catch がサーバエラーとして描画するかを確認）

### 目的としないこと（スコープ外）

- JARM の署名 alg を RS256 以外へ拡張すること（alg agility）。
  クライアントメタデータ `authorization_signed_response_alg` の受け入れとセットで
  検討すべきであり、`study-material/done/jarm-response-jwt-signing-alg-vs-active-key.md` の
  方針B として保留する。
- `authorization_signing_alg_values_supported` を鍵から導出する形に変えること。
  本タスク完了後は `['RS256']` の広告が**真になる**ため、導出への変更は alg agility 対応時でよい。

## テスト要件

- [ ] `createJarmResponseJwt` の単体テスト
  - [ ] RS256 鍵を渡したとき、JOSE ヘッダが `{ alg: 'RS256', kid: <keyId> }` であることを
        `toEqual` で固定する
  - [ ] ES256 鍵を渡したときに署名が成功しないこと（例外になること）を固定し、
        「この関数は RS256 鍵専用である」という契約をテストで表明する
- [ ] 鍵選択の統合テスト（生成コードのテンプレート出力に対して）
  - [ ] `getSigningKey()` が ES256、`getSigningKeys()` が `[RS256, ES256]` を返す provider で
        JARM 認可レスポンスが**成功**し、応答 JWT のヘッダ `alg` が `RS256`、
        `kid` が RS256 鍵の kid であることを検証する
  - [ ] 同構成で、応答 JWT が `/.well-known/jwks.json` の同 `kid` の公開鍵で検証できることを確認する
  - [ ] `getSigningKeys()` が RS256 鍵を含まない構成で JARM を有効にしたとき、
        認可レスポンスの署名ではなく**明示的なエラー**として失敗することを確認する
- [ ] 回帰テスト
  - [ ] 既定の RS256 単一鍵構成で、生成される応答 JWT が**変更前と同一**であることを固定する
        （ヘッダ・クレーム集合・`kid`）
  - [ ] `--enable jarm` を付けない生成物がバイト単位で変わらないことを確認する
        （`packages/cli/src/__tests__/jarm-feature.test.ts` の既存方針に従う）
- [ ] 生成される `conformance.test.ts`（JARM 有効時）に、
      応答 JWT の `alg` が `RS256` であることを固定するケースを追加する
      — `CLAUDE.md` の方針どおり、`conformance.test.ts` を直接編集せず
        `packages/cli` の生成コード側を変更すること

## 完了条件

- [ ] 混在鍵セット（active = ES256、登録 = RS256 + ES256）で JARM 認可レスポンスが成功する
- [ ] 既定の RS256 単一鍵構成で、応答 JWT が変更前とバイト単位で同一である
- [ ] `--enable jarm` 無しの生成物に差分が無い
- [ ] Discovery の `authorization_signing_alg_values_supported: ['RS256']` が
      実際に署名へ使う鍵の alg と一致する状態になっている
- [ ] 以下がすべて通る

```bash
pnpm --filter @maronn-openid-connect/experimental test
pnpm --filter @maronn-openid-connect/cli test
pnpm test
```
