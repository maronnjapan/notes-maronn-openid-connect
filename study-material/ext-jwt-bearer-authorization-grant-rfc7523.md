# 拡張: JWT Bearer 認可グラント（RFC 7523 §2.1）

## ステータス

🟢 拡張機能 / 未着手（検討段階・優先度低。`client_credentials`（`study-material/ext-oauth-client-credentials-grant.md`）の方針判断と合わせて検討するのが自然）

## 1. このトピックで確認したいこと

RFC 7523 は JWT を 2 つの用途で使う:

1. **クライアント認証**（`client_assertion` / `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`）
2. **認可グラント**（`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`）

このうち **(1) クライアント認証は別ファイルで既に扱っている**（`study-material/ext-private-key-jwt-client-auth.md`）。
本ファイルは **重複を避け、(2) の「JWT を認可グラントとして使う」用途のみ**に絞る。

JWT Bearer 認可グラントは、信頼された発行者（trusted issuer）が署名した JWT アサーションを提示することで、
**ブラウザ・ユーザ介在なしにアクセストークンを取得する**フロー。代表的なユースケース:

- **サービスアカウント**（Google サービスアカウントが採用。秘密鍵で署名した JWT を提示して OAuth トークンを取得）
- **トラストフェデレーション**（別ドメインの IdP が署名したアサーションを信頼して OP がトークンを発行）
- レガシー / 非ブラウザのシステム間連携

Basic OP の必須範囲ではなく、ドメイン横断の信頼確立を伴うため `client_credentials` より導入難度が高い。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 7523 §2.1（Using JWTs as Authorization Grants）**:
  - `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`、`assertion=<JWT>`。
  - JWT のクレーム要件（§3）:
    - `iss`（必須）: アサーション発行者。OP が信頼する発行者か検証。
    - `sub`（必須）: トークンの主体。サービスアカウント識別子やユーザ識別子。
    - `aud`（必須）: **OP の Token Endpoint（または issuer）でなければならない**。audience 不一致は拒否。
    - `exp`（必須）/ `nbf`・`iat`（任意）: 期限検証。
    - `jti`（任意）: リプレイ防止（一度使った jti を拒否するなら OP 側で記録）。
  - 署名検証は、発行者ごとに登録された鍵（JWKS / 事前共有鍵）で行う。
- **RFC 7521（Assertion Framework）**: 7523 の上位フレームワーク。エラーは `invalid_grant`（アサーション不正）/ `invalid_client` を使い分ける。
- **OAuth 2.1**: jwt-bearer グラントは OAuth 2.1 本体には取り込まれていない独立拡張（implicit/password のような「削除」対象ではなく、別仕様として併存）。
- **セキュリティ（RFC 7523 §8 / RFC 9700）**:
  - `aud` を Token Endpoint に固定し、トークンの**転送（aud 取り違え）攻撃**を防ぐ。
  - 信頼する `iss` のホワイトリストと鍵管理が肝。任意の JWT を受け入れてはならない。
  - リプレイ防止（`jti` + `exp` 短命化）。
  - **スコープ拡大の禁止**: アサーションが表す主体の権限を超えるトークンを出さない。

## 3. 参照資料

- RFC 7523 JSON Web Token (JWT) Profile for OAuth 2.0 Client Authentication and Authorization Grants: https://www.rfc-editor.org/rfc/rfc7523
- RFC 7523 §2.1（JWT を認可グラントとして使う）: https://www.rfc-editor.org/rfc/rfc7523#section-2.1
- RFC 7523 §3（JWT Format and Processing Requirements）: https://www.rfc-editor.org/rfc/rfc7523#section-3
- RFC 7521 Assertion Framework for OAuth 2.0: https://www.rfc-editor.org/rfc/rfc7521
- 関連既存ファイル（クライアント認証用途）: `study-material/ext-private-key-jwt-client-auth.md`

## 4. 現在の実装確認

- **未実装**。`packages/core/src/token-request.ts:403` で `authorization_code` / `refresh_token` 以外は `unsupported_grant_type`。
- JWT 署名検証の基盤は存在: `packages/core/src/id-token.ts` の `validateIdTokenHint` が「複数鍵・kid/alg マッチ・iss/aud/exp 検証・`alg:none` 拒否」を実装済みで、アサーション検証ロジックの参考・流用が可能。
- 鍵セット表現は `packages/core/src/jwks.ts`（`JwkSet`）が利用可能。発行者ごとの JWKS を持てば検証鍵を引ける。
- リプレイ防止用の `jti` 記録ストアは無い（Refresh Token 等の used フラグ機構 `token-request.ts` を流用可能）。

## 5. 現在の実装との差分

- 🟢 **Basic OP 認定要件ではない**: 未対応でも仕様違反ではない。
- 🟡 **JWT 検証部品は流用可能**だが、**「信頼する発行者の登録・鍵管理」という新しい概念**が必要になる。これは現状のクライアント定義（client_id / secret / redirect_uri / grant_types）には無い軸。
- 🔴 **不足**: jwt-bearer グラント分岐、アサーション検証（iss ホワイトリスト・aud 固定・署名・exp・jti リプレイ）、信頼発行者の登録機構。
- 🟡 **`client_credentials` との関係**: どちらも非対話・サービス間トークン取得だが、client_credentials は「クライアント自身の権限」、jwt-bearer は「アサーションが表す任意の主体（sub）の権限」を扱う点が異なる。導入するなら client_credentials を先に入れる方が段階的。

## 6. 改善・追加を検討する理由

価値:

- Google サービスアカウント方式の検証ができる。クラウド連携 PoC で「サービスアカウント JWT → アクセストークン」を再現したい需要がある。
- ドメイン横断トラスト（簡易フェデレーション）の検証に使える。フルの OpenID Federation（`study-material/ext-oidc-federation.md`）より軽量に「外部発行 JWT を信頼してトークン発行」を試せる。

Basic OP として必要か、拡張機能か:

- **拡張機能**。Basic OP 範囲外。`client_credentials` よりさらにオプショナル度が高い（信頼発行者管理という運用前提が増えるため）。

導入しない場合のリスク・制約:

- サービスアカウント / アサーション連携の PoC ができない。ただし一般的な OIDC ユーザ認証・M2M（client_credentials）には影響しない。

## 7. 実装方針の候補

最終判断は人間が行う。判断材料:

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` にスコープ外を明記。現状の `unsupported_grant_type` を意図的挙動として固定。

### 方針B（最小：同一 OP / 単一信頼発行者）

- 信頼発行者を 1 つ（OP 自身、または設定で 1 つ）に限定し、その JWKS で `assertion` を検証。
- `aud` を Token Endpoint に固定。`exp` 必須・`jti` リプレイ拒否は任意でも可。
- スコープは要求値をそのまま、または許可リストでフィルタ。

### 方針C（フェデレーション志向）

- 複数の信頼発行者を登録（`iss → JWKS URI` のマップ + 鍵キャッシュ）。
- `TrustedIssuerResolver` 等の resolver 注入でホワイトリスト・鍵取得・ポリシーを委譲。
- `jti` リプレイ防止ストアを必須化。

判断材料:

- jwt-bearer は **信頼発行者の鍵管理**が本質的コスト。ここを resolver 注入にすれば core は検証機構だけ提供でき、ライブラリとして自然。
- 需要は client_credentials より限定的。まず client_credentials の方針を固め、その後に検討するのが堅実。

## 8. タスク案

- [ ] そもそも本グラントを対象にするかを人間が判断（`client_credentials` の方針決定後に再評価するのが妥当）
- [ ] 採用時（方針 B/C）:
  - [ ] `packages/cli` テンプレート + `packages/core` を変更（生成 OP の挙動変更のため CLI 側で対応、`samples/*/conformance.test.ts` は CLI 経由で更新）
  - [ ] `token-request.ts` に `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` 分岐を追加
  - [ ] アサーション検証（`validateIdTokenHint` 相当を流用：iss ホワイトリスト・aud=Token Endpoint 固定・署名・exp・`alg:none` 拒否）
  - [ ] `jti` リプレイ防止（used フラグ機構の流用）
  - [ ] Discovery `grant_types_supported` に jwt-bearer を追加
  - [ ] テスト: 正当なアサーションで AT 取得 / aud 不一致・期限切れ・改ざん・未登録 iss を拒否 / 同一 jti 再提示を拒否
- [ ] 方針 C 採用時: 複数信頼発行者の登録機構と `TrustedIssuerResolver` のテスト

> 注: 信頼発行者管理という運用前提を伴うため、`client_credentials` 同様に方針が確定するまで検討段階（study-material）に留める。
