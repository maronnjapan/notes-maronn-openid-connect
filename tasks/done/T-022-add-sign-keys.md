# T-022 [Major] 署名用の鍵を複数登録できるようにする

## ステータス

🟡 Major / 未着手

## 背景

T-016 により `buildProviderMetadata()` は `idTokenSigningKeys: CryptoKey[]` を受け取り、**複数の ID Token 署名鍵から `id_token_signing_alg_values_supported` を自動導出**できるようになった。

一方で runtime 側は依然として `SigningKeyProvider#getSigningKey(): Promise<SigningKey>` の単数 API のままであり、`createApp` / `applyOidc` / `jwks` / `discovery` も「各用途につき現在の鍵 1 本」しか扱えない。

そのため、ID Token 署名鍵をローテーションすると、新しい鍵で署名を始めた瞬間に**旧 kid の公開鍵を JWKS に残せず、まだ有効なトークンの検証が壊れる**。Discovery が複数鍵前提の設計になっていても、呼び出し側から複数鍵を渡せないため実質的に単一鍵運用に制限されている。

さらに、OIDC ではクライアントメタデータ `id_token_signed_response_alg` により、クライアントごとに ID Token の署名アルゴリズムを選択できる。しかし現状実装にはその選択ロジックがなく、**ID Token の `alg` はサーバ側が注入した鍵の種類から自動決定されるだけ**になっている。

その結果、たとえ JWKS に RS256 用鍵と ES256 用鍵を同時に公開できても、「どのクライアントにどの `alg` で ID Token を返すか」を標準仕様どおりに切り替えることができない。T-022 では複数鍵登録に加えて、この `id_token_signed_response_alg` による選択も実装対象に含める。

## 対象ファイル

- `packages/core/src/signing-key.ts`
- `packages/core/src/index.ts`
- `packages/core/src/token-response.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/sample/src/oidc-provider/config.ts`（生成結果確認用）
- `packages/sample/src/op/key-provider.ts`

## 生成コードに関する前提

`packages/sample/src/oidc-provider` 配下は `packages/cli` の生成物であるため、ここに問題が見えていても**修正対象はまず `packages/cli` 側**である。

- `packages/sample/src/oidc-provider/app.ts`
- `packages/sample/src/oidc-provider/apply.ts`
- `packages/sample/src/oidc-provider/routes/jwks.ts`
- `packages/sample/src/oidc-provider/routes/discovery.ts`

これらは「現状確認」と「生成結果の検証」には使うが、実装方針としては直接修正しない。必要な変更は `packages/cli/src/frameworks/hono/templates.ts` に入れ、sample 側は再生成後の期待結果として扱う。

## 仕様参照

- OIDC Core 1.0 Section 10.1: Signing Keys
- OIDC Dynamic Client Registration 1.0 Section 2: `id_token_signed_response_alg`
- OIDC Discovery 1.0 Section 3: `jwks_uri`, `id_token_signing_alg_values_supported`
- RFC 7517: JSON Web Key / JSON Web Key Set

## 現状の実装

- `packages/core/src/discovery.ts`
  - `buildProviderMetadata()` は `idTokenSigningKeys: CryptoKey[]` を受け取り、複数鍵からアルゴリズム一覧を導出できる
- `packages/core/src/signing-key.ts`
  - `SigningKeyProvider` は `getSigningKey()` しか持たず、`createCachedSigningKeyProvider()` も単一の `SigningKey` だけをキャッシュする
- `packages/cli/src/frameworks/hono/templates.ts`（生成元）
  - `signingKeyProvider` / `idTokenSigningKeyProvider` / `userinfoSigningKeyProvider` は用途別に分かれているが、それぞれ 1 本しか返せない
  - context にも `privateKey` / `idTokenPrivateKey` / `userinfoPrivateKey` など単数値しか入らない
- `packages/core/src/token-response.ts`
  - `idTokenPrivateKey` / `idTokenKeyId` は受け取れるが、「クライアントが要求した `id_token_signed_response_alg` に一致する鍵を選ぶ」責務は持っていない
- `packages/cli/src/frameworks/hono/templates.ts`（client metadata）
  - `userinfo_signed_response_alg` は生成コードにあるが、`id_token_signed_response_alg` は `RegisteredClient` に存在しない
- `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate`）
  - ID Token 用鍵は context の `idTokenPrivateKey` をそのまま使っており、client metadata に応じた `alg` 切り替えがない
- `packages/cli/src/frameworks/hono/templates.ts`（`discoveryRouteTemplate`）
  - `buildProviderMetadata()` へ渡している `idTokenSigningKeys` は `[idTokenPrivateKey]` の 1 要素配列のみ
- `packages/cli/src/frameworks/hono/templates.ts`（`jwksRouteTemplate`）
  - primary / ID Token / UserInfo の各用途から 1 本ずつ、最大 3 本までしか公開できない
  - 同一路用途の旧鍵を複数保持する経路がない
- `packages/sample/src/oidc-provider/app.ts`
  - コメントにも「JWKS serves only the current key. Tokens signed with a rotated-out key will fail verification」とあり、現状の制約が明示されている
- `packages/sample/src/op/key-provider.ts`
  - Env / KV / D1 すべて「現在の active key 1 本」を返す設計になっている

## 修正方針

- [ ] `SigningKeyProvider` を後方互換で拡張し、「現在署名に使う鍵」と「登録済み鍵群」を区別できるようにする

  ```typescript
  export interface SigningKeyProvider {
    getSigningKey(): Promise<SigningKey>;
    getSigningKeys?(): Promise<SigningKey[]>;
  }
  ```

  - `getSigningKey()` は新規トークン署名に使う current key を返す
  - `getSigningKeys()` は JWKS / Discovery に公開する登録済み鍵群を返す
  - `getSigningKeys()` の配列順は「古い → 新しい」とし、末尾を最新鍵として扱う
  - `getSigningKeys` が未実装の既存 provider は `[await getSigningKey()]` にフォールバックする

- [ ] `createCachedSigningKeyProvider()` も `getSigningKeys()` を透過・キャッシュできるようにする
  - 単数 API だけの provider に対する従来動作は維持する

- [ ] `packages/sample/src/oidc-provider` 配下は生成物なので直接直さず、`packages/cli/src/frameworks/hono/templates.ts` を修正して `createApp` / `applyOidc` の生成コードが用途ごとに current key と registered keys の両方を context に載せるようにする
  - 例: `signingKeys`, `idTokenSigningKeys`, `userinfoSigningKeys`
  - 既存の `privateKey` / `publicJwk` / `keyId` など単数の context 値は後方互換のため維持する

- [ ] `discoveryRouteTemplate` は `idTokenSigningKeys.map((k) => k.privateKey)` を `buildProviderMetadata()` に渡す
  - T-016 の「実鍵から alg を導出する」設計を runtime までつなぐ
  - RS256 + ES256 のような混在鍵セットも正しく advertise できるようにする

- [ ] `jwksRouteTemplate` は用途ごとの複数鍵配列をフラットにして公開する
  - 同じ `kid` を持つ鍵は重複排除する
  - `kid` 未指定の鍵は既存ルールどおり最新 1 件のみ採用する
  - primary / ID Token / UserInfo のフォールバックで同じ鍵が重複しても 1 件に畳む

- [ ] `id_token_signed_response_alg` をクライアントメタデータとして生成コードに追加する
  - `userinfo_signed_response_alg` と同様に `RegisteredClient` へ `idTokenSignedResponseAlg?: 'RS256' | 'ES256'` を追加する
  - 値未指定時のデフォルトは OIDC 仕様どおり `RS256` として扱う

- [ ] `tokenRouteTemplate` でクライアントごとの `id_token_signed_response_alg` を見て、該当アルゴリズムの ID Token 署名鍵を選択する
  - `clientResolver` / `tokenClientResolver` から解決したクライアント情報をもとに判定する
  - 要求アルゴリズムに一致する鍵が登録済み鍵群に存在しない場合はサーバ設定エラーとして失敗させる
  - `generateTokenResponse()` には、選ばれた鍵を `idTokenPrivateKey` / `idTokenKeyId` として渡す

- [ ] 鍵選択ロジックは `packages/core` に寄せるか、少なくとも CLI テンプレート内でヘルパー化し、「alg に一致する鍵を選ぶ」「一致しなければエラー」の責務を明確にする
  - 例: `selectSigningKeyByAlg(keys, requestedAlg)` のような helper
  - デフォルトの `RS256` 選択と、将来的な `ES384` / `ES512` 拡張がしやすい形にする

- [ ] `packages/sample/src/op/key-provider.ts` の実装例も複数鍵 API を持てる形にする
  - 最小構成では `getSigningKeys(): Promise<[SigningKey]>` として current key 1 本を返せばよい
  - 利用者が独自 provider で active key + 旧 verification key を返せること、さらに RS256 / ES256 の両系列を返せることをコメントで示す

- [ ] CLI テンプレートにも同じ変更を反映し、生成コードと sample 実装の差分をなくす
- [ ] generator テストで生成コードの shape を固定し、sample 側は再生成結果の確認に留める

## テスト要件

- [ ] `getSigningKeys()` を実装しない既存 provider でも従来どおり 1 鍵で動作すること
- [ ] `createCachedSigningKeyProvider()` が `getSigningKeys()` の結果も TTL キャッシュすること
- [ ] `getSigningKeys()` が複数鍵を返す場合、JWKS に全 distinct key が含まれること
- [ ] 同じ `kid` の鍵が複数含まれる場合、JWKS では 1 件に重複排除されること
- [ ] `kid` 未指定の鍵が複数含まれる場合、最新 1 件だけが JWKS に残ること
- [ ] ID Token 署名には引き続き `getSigningKey()` が返した current key が使われること
- [ ] Discovery が登録済みの複数 ID Token 鍵から `id_token_signing_alg_values_supported` を導出できること
- [ ] `id_token_signed_response_alg=RS256` のクライアントには RS256 で署名された ID Token が返ること
- [ ] `id_token_signed_response_alg=ES256` のクライアントには ES256 で署名された ID Token が返ること
- [ ] `id_token_signed_response_alg` 未指定のクライアントにはデフォルトで RS256 の ID Token が返ること
- [ ] `id_token_signed_response_alg=ES256` を要求したクライアントに対して ES256 鍵が未登録ならエラーになること
- [ ] Discovery の `id_token_signing_alg_values_supported` に登録済みアルゴリズム（例: RS256, ES256）が含まれること
- [ ] CLI 生成テストで、複数鍵配列を context に載せて JWKS / Discovery へ渡すコードが出力されること
- [ ] CLI 生成テストで、`RegisteredClient` に `idTokenSignedResponseAlg` が追加され、token ルートでその値を見て鍵選択するコードが出力されること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
