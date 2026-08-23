# OIDC/OAuth 改善タスク (2026-05)

調査範囲: `packages/core` および `packages/cli`。Basic OP 準拠と Authorization Code Flow / Refresh Token Flow の改善観点で抽出。

ステータス凡例:
- 🔴 Critical / 🟡 Major / 🟢 Minor
- ⏸ Hold (タスクとして残すが今回は修正禁止)
- ❓ Decision needed (実装方針について相談が必要)

---

## ❓ T-001 [Critical] Token Endpoint の `redirect_uri` バインディング検証方針の決定

**ファイル**: `packages/core/src/token-request.ts:407-416`

**現状**: Token リクエストに `redirect_uri` が送られて来た場合のみ、認可コードに保存された `redirectUri` と一致するかを照合している。

**論点**:
- OAuth 2.1: PKCE が認可コード〜トークンリクエストのバインディングを担保するため、Token Endpoint での `redirect_uri` は必須ではない (現状実装と整合)
- OIDC Core 1.0 §3.1.3.2: 認可リクエストに `redirect_uri` が含まれていた場合、Token リクエストでも MUST 一致

両者で要求が異なる。本ライブラリは OAuth 2.1 / OIDC Core 1.0 / OIDC Conformance Profiles v3.0 (Basic OP) すべてに準拠を謳っているため、どちらを採用するか方針決定が必要。

**判断材料**:
- Basic OP 認証を通すなら OIDC 寄りの「認可リクエストで明示された場合は MUST 一致」を採るのが安全
- 実装コスト: 認可コードに「redirect_uri が認可リクエストで明示されたか」のフラグを追加し、Token 側でフラグが true なら必須化

**TODO**:
- [ ] 方針決定（ユーザーと相談）
- [ ] 決定後、実装方針に従ってタスク追加

---

## ✅ T-002 [Critical] Refresh Token Flow で発行されるアクセストークンの `aud` 欠損

**ファイル**:
- `packages/core/src/token-request.ts:190-197` (ValidatedRefreshTokenRequest)
- `packages/core/src/token-response.ts:128, 136`
- `packages/sample/src/oidc-provider/routes/token.ts:127-129` (CLI テンプレート同じく)

**現状**: refresh_token grant では `audience: undefined` を渡すため、生成 JWT の `aud` が空配列になる。

**要件 (ユーザー指示)**:
- Refresh Token を最初に取得した時にアクセストークンへ設定された `audience` を、ローテーション後も継続適用する
- 拡大も欠損も許容しない

**修正方針**:
- [x] `RefreshTokenInfo` に `audience?: string[]` を追加
- [x] Refresh Token 発行時 (sample/CLI の `refreshTokenStore.set`) に元アクセストークンの `audience` を保存
- [x] `ValidatedRefreshTokenRequest` に `audience?: string[]` を追加し `RefreshTokenInfo.audience` を引き継ぐ
- [x] sample/CLI の `token.ts` で refresh_token grant 時に `validatedRequest.audience` を `generateTokenResponse` に渡す
- [x] テスト: refresh_token 発行 → ローテーション後の AT の `aud` が初回発行時と同一であることを検証

---

## ✅ T-003 [Major] Refresh Token 再利用検知時の cascade revocation 実装

**ファイル**: `packages/core/src/token-request.ts:296-301`

**現状**: `refreshTokenInfo.used` を検出すると `invalid_grant` を返すのみ。同 `grantId` の他トークンは失効しない。

**要件**: OAuth 2.1 §4.3.1: refresh token の再利用が検知された時は同 grant のトークンを全失効すべき (SHOULD)。認可コード再利用時には `revokeTokensByGrantId` を呼ぶ実装があるが、refresh token 再利用には未対応。

**修正方針**:
- [x] `RefreshTokenResolver` に `revokeTokensByGrantId?(grantId: string): Promise<void>` を追加
- [x] `validateTokenRequest` の `if (refreshTokenInfo.used)` 分岐で `revokeTokensByGrantId(refreshTokenInfo.grantId)` を呼ぶ
- [x] sample/CLI 側の `refreshTokenResolver` に実装を追加（既存の `accessTokenStore.revokeByGrantId` + `refreshTokenStore.revokeByGrantId` を呼ぶ）
- [x] テスト: 同一 RT を 2 回使用 → 同 grant の AT/RT がすべて失効されることを検証

---

## ✅ T-004 [Major] Refresh Token のローテーション順序を「新規発行成功後に旧トークンを失効」に変更

**ファイル**:
- `packages/core/src/token-request.ts:346` (revoke)
- `packages/sample/src/oidc-provider/routes/token.ts` (呼び出し側、CLI テンプレートも同様)

**現状**: `validateTokenRequest` 内で旧 RT を `revoke` してから戻す。呼び出し側で `generateTokenResponse` が失敗すると旧 RT は失効済みかつ新 RT は未発行で、ユーザーがリフレッシュ不能になる。

**要件 (ユーザー指示)**: CLI で生成するコードに「失敗時にトークンを失わない順序」を反映する。

**修正方針**:
- [x] `validateTokenRequest` から `revokeRefreshToken` 呼び出しを除去（検証だけ行う純関数に戻す）
- [x] CLI テンプレート `tokenRouteTemplate` の token.ts で、新トークン保存成功後に旧 RT を失効する順序に変更
  ```
  generateTokenResponse → accessTokenStore.set → refreshTokenStore.set → 旧RTのrevoke
  ```
- [x] sample 側の `token.ts` も同じ順序に修正
- [x] コメントに「OAuth 2.1 §4.3.1 のローテーションは新トークン保存成功後に旧 RT 失効する」旨を明記
- [x] テスト: 新トークン保存後に旧 RT が失効される順序を CLI 生成テストで検証（generateTokenResponse 失敗時に revoke されない事は順序保証から従属）

---

## ✅ T-005 [Major] Refresh Token Flow での ID Token 再発行

**ファイル**:
- `packages/core/src/token-request.ts:131-146` (RefreshTokenInfo)
- `packages/sample/src/oidc-provider/routes/token.ts:133-135` (issueIdToken: false 固定)

**論点**: OIDC Core 1.0 §12 における refresh_token grant での ID Token 発行は仕様上どう扱われているか。

**仕様調査ポイント**:
- OIDC Core 1.0 §12: "the response MAY include the following: id_token" (MAY)
- §12.1: refresh で返す ID Token は元の認可時の `auth_time` / `acr` / `amr` / `azp` を保持する MUST
- 検証ケース: モバイル等で AT 期限切れ後に RT で AT/IDT 両方更新するパターンは実運用で頻出

**TODO**:
- [x] ユーザー判断: 実装する方向で確定 (2026-05-06)
- [x] `RefreshTokenInfo` に `authTime: number` (必須)、`nonce?: string`、`acr?: string`、`amr?: string[]`、`azp?: string` を追加
- [x] sample/CLI の `refreshTokenStore.set` で元 IT の `authTime` / `nonce` 等を保存
- [x] `ValidatedRefreshTokenRequest` にこれらを伝播
- [x] sample/CLI の token.ts で refresh_token grant 時も `issueIdToken: true` (scope に openid 含む場合) に変更
- [x] テスト: refresh で発行する ID Token の `auth_time` / `nonce` / `acr` / `amr` / `azp` が初回認可時と同一であることを `validateTokenRequest` テストで検証
- [ ] (T-009 Hold 解除後) acr/amr に実際の認証コンテキストを populate する経路を追加
  - メモ: 現在は型上 acr/amr フィールドを保存・伝播するが、認可時に判定する仕組みがないため通常は undefined のまま。

---

## 🟡 T-006 [Major] JWT Access Token の `typ` を `at+jwt` に修正 (RFC 9068)

**ファイル**: `packages/core/src/access-token.ts:85`

**現状**: `typ: 'JWT'`

**要件**: RFC 9068 §2.1: JWT Profile for Access Tokens は `typ: at+jwt` が REQUIRED。ID Token と区別できるようにする。

**修正方針**:
- [ ] `access-token.ts` の JOSE Header で `typ: 'at+jwt'` に変更
- [ ] `id-token.ts` 側は `typ: 'JWT'` のまま（OIDC Core 1.0 §3.1.3.7: ID Token は JWT）
- [ ] テスト: 生成された AT の typ ヘッダが `at+jwt` であること
- [ ] テスト: ID Token の typ が `JWT` のままであること（regression 防止）

---

## ✅ T-007 [Major] Token / Discovery / Introspection / Revocation / JWKS / UserInfo エンドポイントの CORS 対応

**ファイル**:
- `packages/sample/src/oidc-provider/apply.ts`
- `packages/cli/src/frameworks/hono/templates.ts` (`applyTemplate`)

**現状**: CORS middleware が一切設定されていない。

**要件**: OAuth 2.1 §4.2: browser-based client が必要とするため、Token Endpoint 等は CORS 対応必須。Discovery / JWKS は `Access-Control-Allow-Origin: *` 推奨。

**修正方針**:
- [x] CLI テンプレート `applyTemplate` に Hono の `cors()` middleware を追加
  - `/.well-known/openid-configuration`, `/.well-known/jwks.json`: `origin: '*'` 固定 (publicCors)
  - `/token`, `/userinfo`, `/introspect`, `/revoke`: protectedCors（デフォルト `'*'`、`corsOrigins` で差し替え可）
- [x] sample 側 `apply.ts` も同期（introspect/revoke は sample 未マウントのため Token/UserInfo/Discovery/JWKS のみ）
- [x] CORS 許可 origin を `ApplyOidcOptions.corsOrigins` から差し替え可能にする
- [x] テスト: CLI 生成テストで cors import と各エンドポイントへの装着・カスタマイズ点を検証（hono/cors が preflight を自動処理）

---

## 🟡 T-008 [Major] JWKS エンドポイントの署名アルゴリズム動的解決

**ファイル**:
- `packages/sample/src/oidc-provider/routes/jwks.ts:42-47`
- `packages/cli/src/frameworks/hono/templates.ts` (`jwksRouteTemplate`)

**現状**: `crypto.subtle.importKey` で `RSASSA-PKCS1-v1_5 / SHA-256` をハードコード。ES256 等の鍵を使うと破綻する。

**修正方針**:
- [ ] `publicJwk.alg` / `publicJwk.kty` から動的にインポートパラメータを構築するヘルパーを `packages/core/src/crypto-utils.ts` に追加（既存の `extractAlgorithmParams` の JWK 版）
- [ ] `jwks.ts` ルートで上記ヘルパー経由でインポート
- [ ] CLI テンプレートも同期
- [ ] テスト: ES256 鍵で JWKS が正しく公開されること

---

## ⏸ T-009 [Major] acr_values を ID Token の `acr` / `amr` クレームに伝播 (Hold)

**ファイル**: `packages/core/src/authorization-request.ts:480`、`packages/core/src/token-response.ts`

**状態**: 修正禁止。タスクとして記録のみ。

**メモ**: `acr_values` をリクエストパラメータとして受領するが、認可サーバ側に「どの ACR を満たしたか」の判定機構がないため伝播できない。Basic OP では OPTIONAL。仕様準拠と利用者の責務分界（誰が ACR を判定するか）を整理した上で再評価する。

---

## 🟢 T-010 [Minor] error_description のサニタイズ (RFC 6749 §5.2)

**ファイル**: `packages/core/src/authorization-request.ts:267, 343`、`packages/core/src/token-request.ts` 等

**現状**: `Invalid prompt value: ${value}` のようにユーザー入力をそのまま埋め込み。

**要件**: RFC 6749 §5.2: `error_description` は `%x20-21 / %x23-5B / %x5D-7E` のみ許容。

**修正方針**:
- [ ] サニタイザヘルパーを `packages/core/src/error-utils.ts` (新規) に追加
  - 許容文字以外を `?` 等に置換、または完全に除去
- [ ] 各 Error クラスのコンストラクタでサニタイズを通す
- [ ] テスト: 制御文字 / 非ASCII 文字を含む値が混入してもレスポンスは仕様準拠

---

## ⏸ T-011 [Minor] Discovery エンドポイントの Cache-Control 設定 (Hold)

**ファイル**: `packages/sample/src/oidc-provider/routes/discovery.ts`

**状態**: 修正禁止。タスクとして記録のみ。

**メモ**: OIDC Discovery 1.0 §3 SHOULD だが、PoC 用途では設定変更を即時反映したいケースもある。キャッシュ戦略は利用者責務とすべきか、ライブラリで指定するか整理が必要。

---

## 🟢 T-012 [Minor] `ProviderMetadataConfig.responseModeSupported` の命名 typo 修正

**ファイル**: `packages/core/src/discovery.ts:35`

**現状**: 単数形 `responseModeSupported`。仕様の正名は `response_modes_supported` (複数形)。出力フィールド名は正しい。

**修正方針**:
- [ ] フィールド名を `responseModesSupported` にリネーム
- [ ] `buildProviderMetadata` 内の参照箇所も更新
- [ ] sample/CLI で利用箇所がないか確認 (現状未使用と思われる)
- [ ] テストの命名も修正

---

## 🟢 T-013 [Minor] ループバックアドレスのポート許容を public client 限定に

**ファイル**: `packages/core/src/authorization-request.ts:170-186` (`matchRedirectUri`)

**現状**: クライアント種別に関係なくループバックホストならポート違いを許容している。

**要件**: OAuth 2.1 §10.3.3: ポート許容は native (public) client 限定であるべき。confidential client は厳格一致。

**修正方針**:
- [ ] `ClientInfo` に `clientType?: 'confidential' | 'public'` を追加 (既に sample の `RegisteredClient` 型では使われているので core 側にも昇格)
- [ ] `matchRedirectUri` (または `resolveRedirectUri`) に `clientType` を渡し、`clientType === 'public'` のときのみループバック緩和を有効化
- [ ] テスト: confidential client + ループバック + ポート違い → 不一致でエラー
- [ ] テスト: public client + ループバック + ポート違い → 一致

---

## 🟢 T-014 [Minor] JWKS で kid 未指定時は最新の鍵を採用

**ファイル**:
- `packages/sample/src/oidc-provider/routes/jwks.ts:36-49`
- `packages/cli/src/frameworks/hono/templates.ts` (`jwksRouteTemplate`)

**現状**: `seen` Set のキーが kid。kid 未指定 (`undefined`) の鍵が複数あると 1 個目しか出力されない。

**要件 (ユーザー指示)**: kid 未指定時は jwks にある一番最新の鍵を用いる。

**修正方針**:
- [ ] candidates の各エントリに「投入順 (= 最新性)」のメタを持たせ、kid 未指定の場合は最後に投入されたものを採用するロジックに変更
  - 具体例: `candidates` を逆順走査し、`kid === undefined` の鍵は最初に見つかった 1 個のみ採用
- [ ] kid 指定がある鍵は従来どおり kid で重複排除
- [ ] テスト: kid 未指定鍵が 2 件 + kid 指定鍵が 1 件 → 出力は最新の kid 未指定鍵 1 件 + kid 指定鍵 1 件

---

## 🟡 T-015 [Major] acr/amr resolver 注入機構の追加

**ファイル**:
- `packages/core/src/authorization-request.ts`
- `packages/core/src/auth-transaction.ts`
- `packages/core/src/token-response.ts`
- `packages/cli/src/frameworks/hono/templates.ts`

**背景**: T-009（Hold）では「acr の判定機構は未実装」としたが、Core が判定ロジックを持つのではなく、**呼び出し側から resolver として注入できるインタフェースを追加する**のが本タスクの目的。判定ロジック自体は各プロジェクトの要件によるため Core には書かない。

**要件**:
- `AcrResolver` 型を定義し、認可時のコンテキスト（`userId`, `clientId`, `acrValues` リクエスト値）を受け取り `{ acr: string; amr: string[] }` を返す callback インタフェースを作る
- `createTokenResponse` / `buildIdToken` 呼び出し時に resolver があれば呼び出し、返された acr/amr を ID Token に反映する
- resolver がない場合は従来通り `undefined`（T-009 hold 相当の動作）

**修正方針**:
- [ ] `packages/core/src/types.ts`（もしくは適切なファイル）に `AcrResolver` インタフェースを定義
  ```typescript
  export type AcrResolver = (context: {
    userId: string;
    clientId: string;
    requestedAcrValues?: string;
  }) => Promise<{ acr: string; amr: string[] } | undefined>;
  ```
- [ ] `generateTokenResponse` の options に `acrResolver?: AcrResolver` を追加
- [ ] `generateTokenResponse` 内で resolver を呼び出し、結果を `IdTokenPayload.acr` / `amr` に渡す
- [ ] CLI テンプレートで `acrResolver` を外部注入できる型を生成コードに反映（stub として `undefined` を渡す形）
- [ ] テスト: resolver が返す acr/amr が ID Token に反映されること / resolver が undefined なら acr/amr は undefined のまま

---

## 🔴 T-016 [Critical] RS256 キー存在チェック（Discovery との整合性保証）

**ファイル**:
- `packages/core/src/signing-key.ts`
- `packages/core/src/discovery.ts`
- `packages/core/src/id-token.ts`

**現状**: `id-token.ts` は `getJwaAlgorithm(privateKey)` で鍵から alg を自動判定（RS256/ES256 等）。`discovery.ts` は `idTokenSigningAlgValuesSupported` に RS256 が含まれることを必須チェックするが、**実際に渡される鍵が RS256 対応でない場合でも通過する**。EC 鍵のみが渡されると、Discovery では RS256 を advertise しながら ES256 で署名する矛盾が生じる。

**仕様**: OIDC Core 1.0 §15.1: RS256 はデフォルトアルゴリズム（MUST be supported）。Basic OP は RS256 必須。

**修正方針**:
- [ ] `packages/core/src/signing-key.ts` に「配布された鍵群の中に RS256 対応の RSA 鍵が 1 本以上あるか」を検証するヘルパー `assertRs256KeyPresent(keys: CryptoKeyPair[])` を追加
- [ ] `generateIdToken` の先頭で、使用しようとしている鍵が RS256（RSASSA-PKCS1-v1_5 / SHA-256）であることを assert する
- [ ] Discovery `buildProviderMetadata` で既存の RS256 必須チェックに加え、渡された鍵のアルゴリズムと advertised alg が一致するかの検証も追加
- [ ] テスト: EC 鍵のみ渡した場合に `generateIdToken` でエラーが投げられること

---

## 🟡 T-017 [Major] `id_token_hint` 検証ヘルパーの追加

**ファイル**: `packages/core/src/id-token.ts`（新規関数）

**背景**: `authorization-request.ts` は `id_token_hint` パラメータを受け取るが、Core が検証ヘルパーを提供していないため、呼び出し側（CLI 生成コード）が `prompt=none` や re-authentication フローで hint の有効性を判定できない。

**仕様**: OIDC Core 1.0 §3.1.2.1: id_token_hint が提供された場合、OP は hint の署名・iss・aud・exp を検証し、sub を信頼すること。

**修正方針**:
- [ ] `packages/core/src/id-token.ts` に以下のシグネチャでヘルパーを追加:
  ```typescript
  export async function validateIdTokenHint(
    hint: string,
    options: {
      expectedIss: string;
      expectedAud: string;
      jwks: JsonWebKeySet;
    }
  ): Promise<{ sub: string; [key: string]: unknown }>;
  ```
- [ ] 検証内容: JWT のデコード → alg 取得 → JWKS から kid 一致鍵を選択 → 署名検証 → `iss` / `aud` / `exp` 検証
- [ ] 検証失敗時は `login_required` エラーに相当する Error を投げる（`prompt=none` 失敗と区別しやすい型付き Error）
- [ ] CLI テンプレートの authorize ハンドラで `id_token_hint` が存在するとき `validateIdTokenHint` を呼び出すコードを生成
- [ ] テスト: 有効な id_token_hint → sub 返却 / 期限切れ → エラー / iss 不一致 → エラー / 署名不正 → エラー

---

## 🟡 T-018 [Major] `request` / `request_uri` 非サポート宣言と Discovery メタデータ追加

**ファイル**:
- `packages/core/src/authorization-request.ts`
- `packages/core/src/discovery.ts`

**仕様調査結果** (OIDC Core 1.0 §6):
- `request` / `request_uri` パラメータは JWT 形式で認可リクエストをカプセル化する Request Object 機能
- サポートしない OP がこれらのパラメータを受け取った場合、以下を redirect_uri にリダイレクトで返す **MUST**:
  - `request` を受け取った場合: `error=request_not_supported`
  - `request_uri` を受け取った場合: `error=request_uri_not_supported`
- Discovery のデフォルト値（項目が存在しない場合）: 両方とも `false`
- Basic OP 認定テスト: これらパラメータのサポートは OPTIONAL であり Basic OP テストでは送信されない

**修正方針**:
- [ ] `validateAuthorizationRequest` に `request` / `request_uri` パラメータの検知を追加し、それぞれ `request_not_supported` / `request_uri_not_supported` エラーを返す
- [ ] `ProviderMetadataConfig` に `requestParameterSupported?: boolean` / `requestUriParameterSupported?: boolean` を追加（デフォルト `false`）
- [ ] `buildProviderMetadata` で両フィールドを出力（`false` でも明示的に出力する）
- [ ] テスト: request パラメータを含む認可リクエスト → `request_not_supported` エラー
- [ ] テスト: Discovery に `request_parameter_supported: false` / `request_uri_parameter_supported: false` が含まれること

---

## 🔴 T-019 [Major] DPoP (RFC 9449) sender-constrained トークン実装

**ファイル**:
- `packages/core/src/access-token.ts`（新規: DPoP proof 検証・cnf クレーム）
- `packages/core/src/token-request.ts`（DPoP-bound AT 発行）
- `packages/core/src/discovery.ts`（メタデータ追加）
- `packages/cli/src/frameworks/hono/templates.ts`（Token / UserInfo エンドポイント更新）

**仕様調査結果** (RFC 9449):

**DPoP の仕組み**:
1. クライアントが非対称鍵ペアを生成し、リクエスト毎に DPoP Proof JWT を生成
2. Token endpoint に `DPoP: <proof_jwt>` ヘッダを付与してリクエスト
3. AT に `cnf.jkt`（公開鍵の JWK thumbprint）を含め、鍵に紐付ける
4. Resource server はAT の `cnf.jkt` と DPoP proof の公開鍵サムプリントが一致することを確認

**DPoP Proof JWT の検証（§4.3）**:
- ヘッダ: `typ=dpop+jwt`, `alg` は `none` 以外の非対称アルゴリズム, `jwk` に送信者公開鍵
- ペイロード必須クレーム:
  - `jti`: リプレイ防止。短時間（推奨: 数分）以内でユニークであること
  - `htm`: HTTP メソッド（Token endpoint では `POST`）
  - `htu`: HTTP URI（Token endpoint の完全 URL）
  - `iat`: 発行時刻（サーバ時刻との許容ずれ: ±60秒推奨）
  - `ath`: アクセストークンのハッシュ（Resource Server 側でのみ検証、Token endpoint では不要）
- リプレイ防止: `jti` を短時間ストアで管理し重複拒否

**AT の `cnf` クレーム形式**:
```json
{ "cnf": { "jkt": "<base64url(SHA-256(JWK thumbprint))>" } }
```

**Refresh Token + DPoP（§5）**:
- refresh_token grant でも DPoP Proof を必須とし、新しく発行する AT に新 proof の公開鍵を紐付ける

**Discovery メタデータ**:
- `dpop_signing_alg_values_supported`: サポートするアルゴリズムの配列（例: `["ES256", "PS256"]`）

**修正方針**:
- [ ] `packages/core/src/crypto-utils.ts` に JWK thumbprint 計算ヘルパー（RFC 7638）を追加
- [ ] `packages/core/src/access-token.ts` に DPoP Proof 検証関数 `validateDpopProof(proof: string, options: { htm, htu, jwkThumbprintStore })` を追加
  - typ / alg チェック
  - jti リプレイ防止（ストア注入）
  - htm / htu / iat 検証
  - JWK 公開鍵で署名検証
- [ ] `generateAccessToken` に `cnf?: { jkt: string }` を渡せるオプションを追加
- [ ] `validateTokenRequest` で `DPoP` ヘッダが存在した場合: proof 検証 → jkt 計算 → AT に `cnf.jkt` を付与
- [ ] `validateTokenRequest` の refresh_token grant でも DPoP proof 検証を実施
- [ ] `ProviderMetadataConfig` に `dpopSigningAlgValuesSupported?: string[]` を追加、`buildProviderMetadata` で出力
- [ ] CLI テンプレートで Token endpoint に `DPoP` ヘッダを読み取り `validateTokenRequest` に渡す
- [ ] CLI テンプレートで UserInfo endpoint に `jti` リプレイストアを注入
- [ ] テスト:
  - DPoP Proof 付き → `cnf.jkt` を含む AT が発行される
  - jti 重複 → エラー
  - htm/htu 不一致 → エラー
  - iat 古すぎ → エラー
  - DPoP Proof なし → 通常 Bearer AT（DPoP は optional）

---

## 🟡 T-020 [Major] Refresh Token grant でのスコープ削減時 ID Token / AT クレームフィルタ

**ファイル**:
- `packages/core/src/token-request.ts`
- `packages/core/src/token-response.ts`

**現状**: refresh_token grant でスコープ削減（初回 scope より小さい scope を要求）は許可しているが、削減後の scope に対応するクレームセットが ID Token に反映されていない。例えば `profile` scope を落とした場合でも、ID Token が初回と同じクレームを持つ可能性がある。

**仕様**: OIDC Core 1.0 §12: refresh で発行される ID Token のクレームセットは、削減後の scope に準拠すること。

**修正方針**:
- [ ] `ValidatedRefreshTokenRequest` に `effectiveScope: string` を持たせ、削減後の scope を保持する
- [ ] `generateTokenResponse` で ID Token を生成する際、`effectiveScope` を `scope` として使用
- [ ] UserInfo クレームフィルタ（`filterUserInfoClaims` 相当）を `generateIdToken` 側でも参照し、scope に応じてクレームを絞り込む
- [ ] テスト: 初回 `openid profile email` で取得 → refresh 時 `openid email` で要求 → 発行 ID Token に `name` 等 profile クレームが含まれないこと

---

## 🟡 T-021 [Major] Discovery メタデータの不足フィールド追加

**ファイル**: `packages/core/src/discovery.ts`

**現状**: 必須フィールドは揃っているが、Basic OP Conformance テストで参照される推奨フィールドが一部不足。

**追加すべきフィールド**（仕様: OIDC Discovery 1.0 §3、OAuth 2.1 §7.1）:

| フィールド | 値 | 仕様 |
|---|---|---|
| `grant_types_supported` | `["authorization_code", "refresh_token"]` | RFC 8414 §2 |
| `token_endpoint_auth_methods_supported` | `["client_secret_basic", "client_secret_post"]` | OIDC Discovery §3 |
| `claims_parameter_supported` | `true` | OIDC Core §5.5 対応済みのため |
| `request_parameter_supported` | `false` | OIDC Core §6 (T-018 で追加) |
| `request_uri_parameter_supported` | `false` | OIDC Core §6 (T-018 で追加) |
| `scopes_supported` | `["openid", "profile", "email", "address", "phone", "offline_access"]` | OIDC Discovery §3 推奨 |
| `claims_supported` | 標準クレーム一覧 | OIDC Discovery §3 推奨 |

**修正方針**:
- [ ] `ProviderMetadataConfig` に上記フィールドに対応する設定プロパティを追加（既存フィールドとの命名スタイルを統一）
- [ ] `buildProviderMetadata` で各フィールドを出力
- [ ] `scopes_supported` / `claims_supported` はデフォルト値を持つが config で上書き可能にする
- [ ] CLI テンプレートの Discovery config にデフォルト値を設定する箇所を追加
- [ ] テスト: 生成される Discovery レスポンスに各フィールドが含まれること

---

## スキップ (CLI 生成で吸収)

| 元の指摘 | 理由 |
|---------|------|
| C-1: sample apply.ts の introspection/revocation 未マウント | CLI テンプレートは正しい。sample は再生成で吸収可能。 |
| C-2: CLI Discovery で offline_access / auth_time / nonce 欠落 | 同上 (CLI 生成側で吸収する方針) |

## スキップ (仕様確認の結果・対応不要)

| 元の指摘 | 理由 |
|---------|------|
| #5 display パラメータの値検証 | OIDC Core 1.0 §3.1.2.1: 「If the display parameter value is not supported by the OP, the OP SHOULD ignore it.」とあり、現状実装（無視）は仕様通り正しい。エラーを返す実装は仕様非準拠になる。 |
| #1 c_hash | Authorization Code Flow のみを対象とする方針のため不要（Hybrid Flow 拡張時に検討） |
| #6 redirect_uri fragment 拒否 | redirect_uri の完全一致検証により結果的に fragment を含む URI は登録・一致ともに阻止できているため追加対応不要 |
| #8 Refresh Token TTL デフォルト戦略 | PoC 用途でデフォルト設定を持ちたくない。セキュリティ的に永続化を許容しない方針。 |
| #11 error_uri | 任意実装で Basic OP 認定に不要 |
| #12 UserInfo sub 一貫性チェック | OIDC Core §3.1.3.7 step 8 / §5.3.2: sub 一貫性はクライアント側の検証責務。Provider は AT の sub をそのまま UserInfo の sub として返せばよく（実装済み）、追加チェック不要 |
| #14 JWKS キーローテーション戦略 | Provider 責務を超えるため対象外 |

---

## 完了条件

- 各タスクごとに `pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- T-001 / T-005 は実装前にユーザーと方針確認を行うこと
- T-009 / T-011 は今回は修正禁止 (Hold)
