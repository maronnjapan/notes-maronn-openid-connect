# JARM だけがクライアント登録の署名アルゴリズムを読まない（`authorization_signed_response_alg` 非対応）

## ステータス

🟡 Medium（相互運用性 / 一貫性）/ 未着手

## 1. タイトル

JARM の応答 JWT が RS256 固定であり、クライアント登録メタデータ `authorization_signed_response_alg` を参照しない点の確認。ID Token / 署名付き UserInfo はクライアント登録の alg を honor しているため、生成 OP の中でこの経路だけが非対称になっている。

## 2. このトピックで確認したいこと

生成 OP は、クライアントが登録した署名アルゴリズムを次の 2 経路では honor している。

- ID Token: `RegisteredClient.idTokenSignedResponseAlg` を読み、`selectSigningKeyByAlg` で一致する鍵を選ぶ。登録鍵が無ければ `server_error` を返す
- 署名付き UserInfo: `userinfo_signed_response_alg` に対して同じ選択を行う

JARM の応答 JWT だけは `RESPONSE_SIGNING_ALG = 'RS256'` のハードコードで、クライアント登録を一切読まない。
確認したいのは次の三点である。

- JARM 仕様が `authorization_signed_response_alg` に対して OP へ何を課しているか
- RS256 固定のまま ES256 等を登録したクライアントが来たとき、生成 OP がどう振る舞うか
- Discovery の広告（`authorization_signing_alg_values_supported: ['RS256']`）との整合が取れているか

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| JARM 導入の是非、仕様の全体像、`response_mode` の 3 値 | `study-material/ext-jarm-jwt-secured-authorization-response.md` |
| 応答 JWT の署名鍵として active key ではなく RS256 鍵を選ぶこと | `study-material/done/jarm-response-jwt-signing-alg-vs-active-key.md`、`tasks/done/p2-jarm-response-jwt-rs256-key-selection.md` |
| ID Token の alg アジリティと `at_hash` のハッシュ追従 | `study-material/done/id-token-at-hash-algorithm-agility.md` |
| 複数鍵登録時の `kid` 必須化 | `study-material/done/id-token-kid-presence-under-multiple-keys.md` |
| EdDSA / PS256 の対応可否 | `study-material/done/signing-alg-eddsa-ps256-interop.md`、`tasks/p2-signing-alg-ps256.md` |
| experimental 機能の Discovery 表現力 | `study-material/done/discovery-metadata-experimental-features-core-expressibility.md` |
| ID Token / UserInfo の JWE 暗号化 | `study-material/id-token-and-userinfo-encryption-jwe.md` |

`done/jarm-response-jwt-signing-alg-vs-active-key.md` は「RS256 と決め打った以上、active key ではなく RS256 鍵を選べ」という**鍵選択**の話である。
本ファイルは「そもそも alg を RS256 に決め打ってよいのか」という**アルゴリズム選択**の話であり、軸が違う。
`ext-jarm-jwt-secured-authorization-response.md` は JARM 実装前に書かれた導入検討であり、クライアントメタデータを仕様の背景として列挙するにとどまる。

## 3. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照する。

### 3.1 JARM §3（クライアントメタデータ）

JARM は 3 つのクライアント登録パラメータを定義する。

- **`authorization_signed_response_alg`**：認可レスポンスの署名に用いる JWS `alg`。省略時の既定は `RS256`。`none` は許されない
- **`authorization_encrypted_response_alg`**：認可レスポンスの暗号化に用いる JWE `alg`。省略時は暗号化しない
- **`authorization_encrypted_response_enc`**：JWE `enc`。指定するときは `authorization_encrypted_response_alg` も併せて指定する

仕様本文は「OP がこの登録値を honor しなければならない」とは明示していない。
とはいえ、クライアント側は登録した alg で検証するため、登録と実際の署名が食い違えば検証は失敗する。
登録メタデータを受け付けておいて別の alg で署名する状態は、クライアントから見て機能しない。

### 3.2 JARM §2.4（`alg: none` の禁止）

> the algorithm `none` (`"alg":"none"`) MUST NOT be accepted.

RS256 固定である限りこの要求は自動的に満たされる。

### 3.3 JARM §4（AS メタデータ）

`authorization_signing_alg_values_supported` は、認可エンドポイントがレスポンス署名に使える `alg` の一覧である。
暗号化に対応する場合は `authorization_encryption_alg_values_supported` / `authorization_encryption_enc_values_supported` を併せて広告する。

### 3.4 OIDC Dynamic Client Registration 1.0 §2 との関係

`id_token_signed_response_alg` / `userinfo_signed_response_alg` と `authorization_signed_response_alg` は、いずれも「クライアントが受け取る JWT の署名 alg」を表すクライアントメタデータであり、OP 側の扱いに差を設ける仕様上の根拠は無い。

## 4. 参照資料

- JWT Secured Authorization Response Mode for OAuth 2.0 (JARM) §2.1 / §2.4 / §3 / §4 — https://openid.net/specs/oauth-v2-jarm.html
  - §3 の "If unspecified, the default algorithm to use for signing authorization responses is `RS256`. The algorithm `none` is not allowed." を根拠にしている
- OpenID Connect Dynamic Client Registration 1.0 §2 — https://openid.net/specs/openid-connect-registration-1_0.html
- RFC 7515 JSON Web Signature §4.1.1（`alg` ヘッダの意味） — https://www.rfc-editor.org/rfc/rfc7515
- FAPI 2.0 Security Profile — https://openid.net/specs/fapi-security-profile-2_0.html

## 5. 現在の実装確認

### 5.1 JARM 側（RS256 固定）

`packages/experimental/src/jarm/response-jwt.ts`:

```ts
const RESPONSE_SIGNING_ALG = 'RS256';
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';
```

`createJarmResponseJwt` は JOSE ヘッダに `{ alg: 'RS256', kid }` を書き、Web Crypto の `RSASSA-PKCS1-v1_5` で署名する。
`options` にクライアント情報は渡らない。JSDoc は固定である旨と、RS256 鍵を渡す責務が呼び出し側にあることを明記している。

生成 OP（`packages/cli/src/frameworks/hono/templates.ts`）は次のように鍵を選ぶ。

```ts
const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
...
  signingKey: jarmSigningKeys.length > 0
    ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
    : ...
```

第 2 引数が `'RS256'` のリテラルであり、クライアント登録は参照されない。

### 5.2 ID Token 側（登録値を honor）

同じテンプレートの Token ルートでは、登録クライアントから alg を読んでいる。

```ts
const requestedIdTokenAlg = registeredClient?.idTokenSignedResponseAlg;
...
selectedIdTokenKey = selectSigningKeyByAlg(idTokenSigningKeys, requestedIdTokenAlg);
```

一致する鍵が無ければ `server_error` を返し、黙って別の alg で署名することはない。
署名付き UserInfo も `requestedUserinfoAlg` で同じ構造を持つ。

### 5.3 クライアント登録型

生成 OP の `RegisteredClient` 型は、署名 alg を 2 つだけ持つ。

```ts
  userinfoSignedResponseAlg?: 'RS256' | 'ES256';
  idTokenSignedResponseAlg?: 'RS256' | 'ES256';
```

`authorization_signed_response_alg` に相当する項目は存在しない。
したがって現状は「登録値を無視している」のではなく、**登録する手段そのものが無い**。
ES256 は ID Token と UserInfo では既に選べるため、JARM だけが RS256 に閉じている。

### 5.4 Discovery

JARM 有効時、生成 OP は次を広告する。

```
response_modes_supported: ['query', 'query.jwt', 'jwt']
authorization_signing_alg_values_supported: ['RS256']
```

暗号化系のメタデータは広告しない。
実際に RS256 しか署名できず、暗号化もできないので、**広告そのものは正直である**。

## 6. 現在の実装との差分

### 満たしていること

- JARM §2.4 の `alg: none` 禁止（構造上、生成されない）
- JARM §4 の `authorization_signing_alg_values_supported` を実能力どおりに広告している
- JARM §2.1 の必須クレーム（`iss` / `aud` / `exp`）を、応答パラメータから上書きできない順序で設定している
- 暗号化非対応を広告しないことで、能力の過大広告を避けている

### 不足している可能性があること

- `authorization_signed_response_alg` を登録する手段が無いため、ES256 での応答 JWT を要求するクライアントを収容できない。ID Token と UserInfo では ES256 を選べるので、同じクライアントが ID Token は ES256、認可レスポンスは RS256 という混在を強いられる
- `authorization_encrypted_response_alg` / `_enc` に対応せず、暗号化された認可レスポンスを検証できない

### 実装はあるが仕様上の確認が必要なこと

- 登録値が広告した一覧に無い場合、クライアント登録時に弾くか、認可リクエスト時に `invalid_request` を返すかの選択
- 暗号化まで踏み込む場合、JWE の適用範囲を JARM だけにするか ID Token / UserInfo と揃えるか

### セキュリティ上、改善した方がよいこと

- 署名検証の失敗は攻撃ではなく設定ミスとして現れるため、直接の脆弱性ではない。ただし、OP が登録値を無視する挙動そのものが「メタデータを設定しても効かない」という誤った安心を利用者に与える

### 相互運用性の観点で改善した方がよいこと

- FAPI 系プロファイルは ES256 または PS256 を要求することが多い。RS256 固定のままでは、JARM を有効にしても FAPI 相当の構成を検証できない。PS256 対応は `tasks/p2-signing-alg-ps256.md` で別途追跡されており、そちらが入れば JARM 側の固定が唯一の制約になる

### Basic OP として提供する上で確認すべきこと

- JARM は Basic OP 認定の対象外であり、この差分は認定可否に影響しない

## 7. 改善・追加を検討する理由

生成 OP は、同じ性質のクライアントメタデータを経路ごとに違う扱いにしている。
ID Token と UserInfo は登録値を読み、一致する鍵が無ければ明示的に失敗する。
JARM だけが読まずに進む。
利用者が生成コードを読んで挙動を予測しようとしたとき、この非対称は説明を要する。

拡張機能としての価値は、JARM を有効にする動機がほぼ FAPI 系プロファイルの検証にある点から出てくる。
そのプロファイルが要求する alg を選べないなら、JARM を載せた意味が半分になる。

導入しやすさの面では、必要な部品が揃っている。
`selectSigningKeyByAlg` は既にクライアント登録の alg を引数に取る形で使われており、JARM 側の呼び出しをその形に揃えるだけで済む。
実装の中心は「`createJarmResponseJwt` が `alg` を引数で受け取り、JOSE ヘッダとWeb Crypto のアルゴリズム指定を連動させる」ことに絞られる。
`packages/core` の `getJwaAlgorithm` は CryptoKey から JWA 名を導出するため、鍵から alg を決める形にすれば分岐を増やさずに済む。

実装しない場合に残る制約は、ES256 / PS256 を要求するプロファイルの検証不能と、上記の非対称が生成コードに残ることである。
暗号化（JWE）まで踏み込むかは別の判断であり、`study-material/id-token-and-userinfo-encryption-jwe.md` と足並みを揃えるのが自然である。

## 8. 実装方針の候補

最終的にどれを採るかは人間が判断する。

### 方針A: 署名鍵から alg を導出する

`createJarmResponseJwt` の JOSE ヘッダ `alg` を、渡された `SigningKey` から `getJwaAlgorithm` で導出する。
生成 OP 側は `selectSigningKeyByAlg(jarmSigningKeys, client.authorizationSignedResponseAlg)` に変える。
Web Crypto の署名パラメータは core の `sign` を使うか、鍵の `algorithm` から組み立てる。

- 利点: ID Token / UserInfo と同じ構造になり、非対称が消える。Discovery の広告も登録鍵から導出できるようになる
- 欠点: experimental パッケージが core の署名ヘルパーに寄る。現在の JARM 実装は「core の非公開ヘルパーに依存しない」方針で自前の compact JWS 組み立てを持っており、その方針の見直しになる
- 確認が必要な点: `SigningKey` から公開されている情報だけで JWA 名を決められるか。`getJwaAlgorithm` は core から export されている

### 方針B: 登録値を検証だけして、非対応なら明示的に失敗する

alg 固定は維持しつつ、クライアント登録に `authorization_signed_response_alg` を追加し、`RS256` 以外が登録されている場合は認可リクエストを `invalid_request` で拒否する。

- 利点: 変更量が小さい。黙って RS256 で署名する現状より、失敗の所在がはっきりする
- 欠点: ES256 / PS256 の検証はできないままで、FAPI 系の動機を満たさない

### 方針C: 現状維持のうえ、非対応を文書で明示する

生成 OP の README と JARM 解説（`docs/implementation-guides/experimental/`）に、RS256 固定でありクライアント登録の alg を読まないことを明記する。

- 利点: 変更なし
- 欠点: `RegisteredClient` に登録項目が存在するなら、「設定できるが効かない」状態が残る

## 9. タスク案

- [ ] 方針A / B / C のいずれで進めるかを決める
- [ ] 生成 OP の `RegisteredClient` 型に `authorizationSignedResponseAlg?: 'RS256' | 'ES256'` を追加する（方針A / B のいずれでも必要）
- [ ] 方針A を採る場合、`createJarmResponseJwt` の JOSE ヘッダ `alg` を署名鍵から導出する形に変え、`response-jwt.test.ts` に RS256 以外の鍵での生成ケースを追加する
- [ ] 生成 OP の JARM 分岐を `selectSigningKeyByAlg(keys, client の登録 alg)` に変え、一致する鍵が無い場合は ID Token 経路と同じく明示的なエラーにする
- [ ] Discovery の `authorization_signing_alg_values_supported` を、固定リテラルではなく登録鍵から導出する
- [ ] `tests/e2e` に「ES256 を登録したクライアントへ ES256 署名の応答 JWT が返る」E2E スペックを追加する（PS256 は `tasks/p2-signing-alg-ps256.md` の完了後）
- [ ] 各 sample の `conformance.test.ts` を `packages/cli` 側の生成コードごと更新し、alg 選択の契約を固定する
- [ ] `docs/implementation-guides/experimental/` の JARM 解説（日本語版・英語版の両方）の掲載コードと説明を同じ変更内で更新する
- [ ] `pnpm review:experimental jarm` でパケットを再生成し、同じコミットに含める
