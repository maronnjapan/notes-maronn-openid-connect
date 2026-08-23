# Basic OP 要件確認とカバレッジ基準（インデックス）

## ステータス

🟢 調査ドキュメント / 継続更新

## 1. このトピックで確認したいこと

このリポジトリが OpenID Connect の **Basic OP（Basic OpenID Provider）認定プロファイル**として
提供すべき基準を満たしているかを、要件単位で俯瞰できる「カバレッジ基準表」を作る。

- Basic OP の正しい定義（誤解の補正を含む）
- Basic OP として MUST / SHOULD の機能一覧
- 各要件が「現在のコードで満たされているか」「既存タスクで扱われているか」の対応付け

このファイルは **インデックス（地図）**である。個別の改善内容は重複記載しない。
各要件の改善・実装の詳細は、本ファイルが指し示す既存タスク／新規タスクファイルを参照すること。

> 注記（調査環境の制約）: 本調査時、実行環境のネットワークポリシーにより
> `openid.net` の一次仕様への直接フェッチが 403 で遮断された。
> このため本ファイルの仕様記述は、確立された仕様知識＋章番号引用に基づく。
> 各記述は「参照資料」に挙げた公式 URL の該当章で人間が最終確認できる形にしてある。
> 一次資料で字句確認が望ましい箇所は「要一次資料確認」と明示した。

## 2. Basic OP の定義（補正済み）

「Basic OP」は、OpenID Foundation の **OpenID Connect Conformance Profiles v3.0** が定義する
OpenID Provider 認定プロファイルの一つ。位置づけは次のとおり。

- Basic OP は **Basic RP が必要とする機能**を提供する OP であり、
  **OpenID Connect Core 1.0 のすべての OP に対する Mandatory to Implement Features（§15.1）**を含む。
- 主たるフローは **Authorization Code Flow（`response_type=code`）**。
  Implicit / Hybrid は別プロファイル（Implicit OP / Hybrid OP）であり Basic OP の対象外。
- 認定時、Dynamic Client Registration をサポートしていればテストで利用してよいが、
  **Basic OP の必須要件ではない**。未対応なら手動でクライアント（最低 `client_secret_basic` 対応の 1 つ）を登録してテストする。
- PKCE 自体は OIDC Core では必須ではないが、本リポジトリは OAuth 2.1 準拠も掲げており
  OAuth 2.1 では PKCE（S256）が全クライアント必須。Basic OP 認定の観点では PKCE は
  「OP が拒否しない／正しく扱える」ことが重要。

CLAUDE.md に「`prompt` パラメータ対応（none, login, consent, select_account）」と記載があるが、
これは **OIDC Core §15.1 が全 OP に課す `prompt` 値サポート義務**に由来する（事実）。
一方、Basic OP **認定テストスイート**が専用テストで重点的に検証するのは
`prompt=login` / `prompt=none` / `max_age` / `id_token_hint` であり、
`prompt=select_account` の専用テストは Basic OP テストプランには通常含まれない（要一次資料確認）。
→ 詳細と差分は `tasks/prompt-select-account.md` を参照。

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0** §2（ID Token）, §3.1（Authorization Code Flow）,
  §3.1.2.1（Authentication Request / `prompt` / `max_age` / `id_token_hint`）,
  §5.3（UserInfo）, §5.4（Scope Claims）, §5.5（`claims` パラメータ）,
  §9（Client Authentication）, §12（Refresh）, **§15.1（Mandatory to Implement Features for All OpenID Providers）**
- **OpenID Connect Discovery 1.0** §3（Provider Metadata）
- **OpenID Connect Conformance Profiles v3.0**（Basic OP プロファイル定義）
- **OAuth 2.1 draft（draft-ietf-oauth-v2-1）** §1.5, §4.1, §4.3, §7（PKCE / Security）
- **RFC 6749 / RFC 6750 / RFC 7636 / RFC 8414**

### OIDC Core §15.1 の要旨（要一次資料確認: 字句）

全 OP が実装必須とされる主な機能（§15.1）:

- ID Token を **RS256** で署名できること（デフォルト署名アルゴリズム）。
- `nonce` を Authentication Request の任意パラメータとして受理し、ID Token に反映できること。
- `prompt` の値 **`none` / `login` / `consent` / `select_account`** をサポートすること。
- `display` パラメータを受理すること（未対応値は無視してよい）。
- `max_age` をサポートし、ID Token に `auth_time` を返せること。
- `ui_locales` / `claims_locales` / `id_token_hint` / `login_hint` / `acr_values` を受理できること。
- UserInfo Endpoint を提供すること。
- Discovery / Dynamic Registration は §15.1 の必須ではない（OPTIONAL、ただし対応すると相互運用性が高い）。

## 4. 参照資料

- OpenID Connect Core 1.0: https://openid.net/specs/openid-connect-core-1_0.html
  - §15.1 Mandatory to Implement Features for All OpenID Providers
  - §3.1.2.1 Authentication Request（`prompt`, `max_age`, `id_token_hint`）
- OpenID Connect Discovery 1.0: https://openid.net/specs/openid-connect-discovery-1_0.html
- OpenID Connect Conformance Profiles v3.0:
  https://openid.net/wordpress-content/uploads/2018/06/OpenID-Connect-Conformance-Profiles.pdf
- OpenID 認定（OP テスト手順）: https://openid.net/certification/connect_op_testing/
- OAuth 2.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 8414（AS Metadata）: https://www.rfc-editor.org/rfc/rfc8414

## 5. 現在の実装確認（要件 → 実装箇所）

| Basic OP 要件 | 実装箇所 | 状態 |
|---|---|---|
| Authorization Code Flow / `response_type=code` 限定 | `packages/core/src/authorization-request.ts:496` | 実装済 |
| `scope` に `openid` 必須 | `authorization-request.ts:517` | 実装済 |
| PKCE S256 必須・plain 拒否 | `authorization-request.ts:387-427`, `token-request.ts:531-557` | 実装済 |
| ID Token RS256 署名・JWKS 公開 | `id-token.ts`, `jwks.ts`, `signing-key.ts`（RS256 強制は done T-016） | 実装済 |
| `nonce` を ID Token に反映 | `token-response.ts:267-269` | 実装済 |
| `auth_time` / `max_age` | `auth-transaction.ts:410`、sample authorize route（done 04） | 実装済 |
| `prompt=none`（login_required/consent_required） | `auth-transaction.ts:351-400`（done 02, p0-consent-resolver） | 実装済 |
| `prompt=login` 強制再認証 | sample `routes/login.ts:79-82`（done 03） | 実装済 |
| `prompt=consent` | sample `routes/consent.ts`（同意画面を常時表示） | 実装済（暗黙） |
| `prompt=select_account` | 値は受理するが挙動なし | **未対応** → `tasks/prompt-select-account.md` |
| `id_token_hint` 検証 | `id-token.ts:198`（done T-017） | 実装済 |
| `claims` リクエストパラメータ | `authorization-request.ts:612`, `userinfo.ts`（done p0-claims-id-token-support） | 実装済 |
| UserInfo Endpoint（scope フィルタ／署名応答） | `userinfo.ts`, sample `routes/userinfo.ts`（done p2/p0-userinfo） | 実装済 |
| Discovery Endpoint | `discovery.ts`, sample `routes/discovery.ts` | 実装済（不足フィールドは別タスク） |
| Token Endpoint（`client_secret_basic`/`post`） | `client-auth.ts`, `token-request.ts` | 実装済 |
| Token Endpoint `Cache-Control: no-store` | sample `routes/token.ts:260-261` | 実装済 |
| Refresh Token（rotation / 再利用検知 cascade） | `token-request.ts`（done T-002〜T-005） | 実装済 |
| redirect_uri 完全一致 / fragment 拒否 | `authorization-request.ts:226-323`（done p0-redirect-uri-fragment-rejection） | 実装済 |
| `error_description` サニタイズ | `error-utils.ts`（done oidc-improvements T-010） | 実装済 |

## 6. 現在の実装との差分（Basic OP / 周辺仕様の未充足・要確認）

「満たしていること」は §5 のとおり主要 Basic OP フローは概ね実装済み。
以下は **未充足／要確認**で、それぞれ専用ファイルへ委譲する（本ファイルでは詳細を繰り返さない）。

### 6.1 Basic OP 認定に直接効く可能性が高いもの

- `prompt=select_account` の挙動と `account_selection_required`
  → `tasks/prompt-select-account.md`
- Discovery の `code_challenge_methods_supported` を **core builder** で表現できない
  （CLI テンプレートが応答に後付けしているのみ。OAuth 2.1/RFC 8414 観点で重要）
  → `tasks/discovery-code-challenge-methods-supported.md`
- Discovery 推奨フィールド不足（`grant_types_supported` 等）→ 既存 `tasks/T-021-discovery-metadata.md`（重複記載しない）
- Authorization Response の `iss`（RFC 9207）→ 既存 `tasks/p1-authorization-response-iss.md`
- redirect/deny エラーに `error_description` → 既存 `tasks/p1-authorization-error-description-redirect.md`
- 重複パラメータ拒否 → 既存 `tasks/p1-duplicate-parameter-rejection.md`
- Token Endpoint Content-Type 検証 → 既存 `tasks/p1-token-endpoint-content-type.md`
- public client の Token Endpoint 利用 → 既存 `tasks/p1-public-client-token-endpoint.md`
- JWT AT の `typ=at+jwt` / `jti` / 空 `aud` 防止
  → 既存 `tasks/p1-jwt-access-token-aud-default.md`, `tasks/p2-jwt-access-token-jti.md`,
  および `tasks/done/oidc-improvements-2026-05.md` T-006（未実装の記録）
- `request` / `request_uri` 非サポート宣言と Discovery メタデータ
  → `tasks/done/oidc-improvements-2026-05.md` T-018（一次記録あり・未実装）。
  実装着手時はこの記録をアクティブタスク化すること（本ファイルでは仕様を繰り返さない）。

### 6.2 セキュリティ上改善した方がよいもの

- client_secret の比較が非定数時間・平文保存前提
  → `tasks/security-client-secret-handling.md`

### 6.3 相互運用性・拡張（Basic OP 必須ではないが価値が高い）

- Resource Indicators（RFC 8707, `resource` パラメータ）→ `tasks/ext-resource-indicators-rfc8707.md`
- Pushed Authorization Requests（RFC 9126）→ `tasks/ext-pushed-authorization-requests-rfc9126.md`
- RP-Initiated Logout / Session Management → `tasks/ext-rp-initiated-logout.md`
- Dynamic Client Registration（OIDC DCR 1.0 / RFC 7591）→ `tasks/ext-dynamic-client-registration.md`
- mTLS クライアント認証・証明書バウンドトークン（RFC 8705）→ `tasks/ext-mtls-rfc8705.md`
- `private_key_jwt` / `client_secret_jwt` クライアント認証 → `tasks/ext-private-key-jwt-client-auth.md`
- JAR（Request Object, RFC 9101）の実装 → `tasks/ext-jar-request-object-rfc9101.md`

## 7. 改善・追加を検討する理由

- このリポジトリは「Fidelity（Conformance 準拠を信頼性シグナルとして維持）」を差別化軸に掲げている。
  Basic OP の主要フローはほぼ実装済みだが、**認定通過の確実性**は
  Discovery メタデータの整合・`select_account` の扱い・エラー応答の細部に左右される。
- 利用者（PoC 開発者）にとって、Discovery が実態と一致していないと
  クライアントライブラリの自動設定が壊れる。core builder が表現できないフィールドがあると
  「core を直接使う高度ユースケース」で不整合が出る。
- セキュリティ（client_secret 比較・保存）は Basic OP 認定の合否には直接出ないが、
  「本番導入を見据える開発者」をターゲットにする以上、早期に方針を決めておく価値が高い。

## 8. 実装方針の候補

このファイルは方針決定をしない。各専用ファイルの「実装方針の候補」を参照。
本ファイルの役割は、**着手順序の判断材料**を提供すること:

1. Basic OP 認定に直結（§6.1 群）を最優先で潰す
2. セキュリティ（§6.2）は本番志向ユーザー向けに方針だけ早期確定
3. 拡張（§6.3）はリリース後の継ぎ足し（CLAUDE.md のリリース方針に合致）

## 9. タスク案

- [ ] §6.1 の各既存タスク（T-021 / p1-* / p2-*）の実装状況を棚卸しし、Basic OP 認定ブロッカーを確定する
- [ ] `tasks/done/oidc-improvements-2026-05.md` の未実装項目（T-006/T-008/T-014/T-018）を
      アクティブタスクへ昇格するか判断する（本ファイルは判断材料の提示のみ）
- [ ] OpenID Conformance Suite の Basic OP テストプランを実際に流し、
      FAIL/INTERRUPTED が出るテストを列挙する（一次確認）
- [ ] `prompt=select_account` の方針を決める（`tasks/prompt-select-account.md`）
- [ ] このカバレッジ表を、各タスク完了時に更新し続ける
