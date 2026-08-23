# 参照資料: JWT Secured Authorization Response Mode (JARM)

## Normative（規範的一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| JWT Secured Authorization Response Mode for OAuth 2.0 (JARM) | OpenID Foundation（Lodderstedt / Campbell） | https://openid.net/specs/oauth-v2-jarm-final.html | 標準仕様（Final） | §2.1（応答 JWT クレーム: iss/aud/exp、最大寿命 10 分 RECOMMENDED、成功・エラー実例）/ §2.2（署名 alg の決定はクライアントメタデータ基準）/ §2.3.1（query.jwt: `response` パラメータのみで運搬）/ §2.3.4（`jwt` 省略形: code のデフォルトは query.jwt）/ §2.4（クライアント処理規則: kid による鍵特定・`alg: none` 拒否 MUST）/ §3（`authorization_signed_response_alg` 未登録時デフォルト RS256）/ §4（AS メタデータ: `authorization_signing_alg_values_supported` / `response_modes_supported`）/ §5.1〜5.4（セキュリティ: DoS・完全性・mix-up・code 漏えい） | 応答 JWT の構造・response_mode 値・メタデータ・セキュリティ要件の全根拠 | 2026-08-02 | Final（2022-11-09） |
| OAuth 2.0 Multiple Response Type Encoding Practices | OpenID Foundation | https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html | 標準仕様（Final） | §2.1（response_mode パラメータの定義）/ §2（code の応答は query） | `response_mode` パラメータそのものの定義。既存 discovery が `response_modes_supported: ['query']` を固定している根拠でもある | 2026-08-02 | 1.0 |
| The OAuth 2.0 Authorization Framework (RFC 6749) | IETF | https://datatracker.ietf.org/doc/html/rfc6749 | 標準仕様（RFC） | §4.1.2（認可レスポンス）/ §4.1.2.1（エラーレスポンス） | JWT クレームに詰め替える応答パラメータ（code / state / error 系）の原典 | 2026-08-02 | RFC 6749 |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | 標準仕様（Final） | §3.1.2.5（成功応答）/ §3.1.2.6（エラー応答）/ §6.1（Request Object の supersede 規則） | 応答パラメータの意味・Request Object 内 response_mode の優先規則 | 2026-08-02 | 1.0 (incorporating errata set 2) |
| JSON Web Signature (RFC 7515) / JSON Web Token (RFC 7519) | IETF | https://datatracker.ietf.org/doc/html/rfc7515 / https://datatracker.ietf.org/doc/html/rfc7519 | 標準仕様（RFC） | RFC 7515 §3（compact serialization）/ RFC 7519 §4.1（iss/aud/exp 登録クレーム） | 応答 JWT の生成形式（experimental 内の自前 JWS 実装の準拠先） | 2026-08-02 | RFC 7515 / 7519 |

## セキュリティガイダンス

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 |
|---|---|---|---|---|---|---|
| Best Current Practice for OAuth 2.0 Security (RFC 9700) | IETF | https://datatracker.ietf.org/doc/html/rfc9700 | BCP | §2.1（issuer 識別の手段として JARM を明示: "or through OAuth 2.0 JARM responses"）/ §4.4（mix-up 攻撃: クライアントは対策 MUST。対策 1 = issuer 識別、対策 2 = OP ごとの distinct redirect URI） | JARM 採用理由（mix-up 対策としての位置付け）とセキュリティ要件の根拠 | 2026-08-02 |
| OAuth 2.0 Authorization Server Issuer Identification (RFC 9207) | IETF | https://datatracker.ietf.org/doc/html/rfc9207 | 標準仕様（RFC） | §2（iss パラメータ） | 平文応答での issuer 識別（既存実装）。JARM モードで素の `iss` パラメータを付けない設計判断の対比先 | 2026-08-02 |
| Proof Key for Code Exchange (RFC 7636) | IETF | https://datatracker.ietf.org/doc/html/rfc7636 | 標準仕様（RFC） | 全体 | JARM が防がない code リプレイ・漏えいの補完策（JARM §5.2 / §5.4 が参照） | 2026-08-02 |

## 相互運用性情報

- JARM は FAPI 1.0 Advanced（Part 2）および FAPI 2.0 Message Signing で採用されており、Auth0 / Keycloak / Authlete 等の主要実装が対応済み。相互運用実績は十分（実装状況の個別確認は実装 Routine のスコープ外とし、本リポジトリの結合テストは JARM Final の実例との突き合わせで担保する）
- JARM §2.1 の成功・エラー実例（iss / aud / exp / code / state 構造）を conformance テストの期待値として使用する

## リポジトリ内参照

| パス | 確認内容 | 確認日 |
|---|---|---|
| `packages/core/src/authorization-request.ts:853-888` | `rejectUnsupportedRequestParams` の拒否対象は request / request_uri / registration のみで、`response_mode` は解釈されず無視される（core 無変更で JARM を差し込める根拠） | 2026-08-02 |
| `packages/core/src/authorization-request.ts:105-132` | `ClientInfo` が closed interface で `authorization_signed_response_alg` を追加できない（RS256 固定・クライアント別 alg 非目標の根拠） | 2026-08-02 |
| `packages/core/src/auth-transaction.ts:96-141` | `AuthTransaction` interface と `AuthTransactionStore`（get/put/delete）。拡張フィールド `jarmResponseMode` の相乗り先と round-trip 契約の対象 | 2026-08-02 |
| `packages/core/src/signing-key.ts:4-26` | `SigningKey { privateKey, publicJwk, keyId }` / `SigningKeyProvider`。応答 JWT の署名鍵として再利用 | 2026-08-02 |
| `packages/core/src/index.ts:27,150,170,229-230` | `AuthorizationError` / `sanitizeErrorDescription` / `AuthTransaction` / `SigningKey(Provider)` が公開済み。低レベル署名ヘルパー（`sign` / `arrayBufferToBase64Url`）は非公開（JWS 自前実装の根拠） | 2026-08-02 |
| `packages/cli/src/features.ts:44, 59` | `EXPERIMENTAL_FEATURES = ['par', 'token-exchange']`（jarm 追加先の機構）。Review 3 時点で `OPTIONAL_FEATURES = ['transaction-binding']` が追加されている（experimental とは別カテゴリ・デフォルト無効） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:1780` | `effectiveParams` の束縛位置（request object マージ後。response_mode の読み出し元） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:1949-1964, 2139-2228` | `buildErrorRedirect` ヘルパーと 8 呼び出しサイト（:2139, 2155, 2168, 2181, 2188, 2215, 2221, 2228。応答構築サイト棚卸し #1）。Review 2（当時 :1829-1844, :2019-2108）で 8 サイト全件がローカル変数参照であることを通読確認（U1 解決）、Review 3 で transaction-binding マージ後もサイト数・構造が不変であることを再確認 | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:1725-1743` | transaction-binding の条件付き補間 `bindingSecretStep`（`const transaction = createAuthTransaction(...)` の作成文を所有）。JARM がこの文に変種を追加せず put 引数でマージする判断の根拠（記録 9） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:2122-2131` | auth transaction の put サイト（`transactionStore.put('auth_txn:' + transactionId, transaction, transactionTtlSeconds)`）。`jarmResponseMode` のマージ位置 | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:227, 257-259` | 全ルート共通 context ミドルウェア（`app.use('*')`）が `signingKeyProvider` 由来の `privateKey` / `publicJwk` / `keyId` を全ルートへ公開（authorize / consent ルートでの応答 JWT 署名鍵の取得元）。Review 3 時点では T-022 により `idToken*` / `userinfo*` の per-purpose 鍵も併設（:261-268）— JARM は汎用鍵を使用（記録 8） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:3609-3660` | jwks ルートが汎用 `signingKeys` 配列（無ければ `publicJwk` / `keyId` フォールバック）を `/.well-known/jwks.json` に公開 → JARM 応答 JWT の `kid` が jwks_uri で解決可能（T-022 の複数鍵対応後も成立） | 2026-08-04 |
| `packages/core/src/authorization-request.ts:286-313` | `AuthorizationError` コンストラクタが `errorDescription` を `sanitizeErrorDescription` で必ずサニタイズ → 攻撃者制御の `response_mode` 値を invalid_request の文言にエコーしてもリダイレクト URL への注入は成立しない（Review 2 のインジェクション確認） | 2026-08-03 |
| `packages/cli/src/frameworks/hono/templates.ts:1812` | PAR の `parParamsBinding`（try 前の `let` 宣言）— catch 節から参照する JARM モード変数の宣言位置の先例 | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:2060-2062` | `redirectUri` / `state` の確定位置（response_mode 検証の挿入点） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:2258-2263, 2331-2336, 2356-2373, 4259-4267, 4317-4324` | 成功・エラーのインライン応答構築サイト（棚卸し #2〜#6）。consent 承認（#6）は core の `completeAuthTransaction`（:4278）が返す `responseParams` からリダイレクト URL を構築する | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:3771-3781` | PAR の discovery スプレッドマージ実装（jarm のメタデータ追加が踏襲するパターン） | 2026-08-04 |
| `packages/cli/src/frameworks/hono/templates.ts:3828-3830` | discovery 設定の `responseModesSupported: ['query']` 固定値（jarm 有効時に差し替える箇所） | 2026-08-04 |
| `packages/core/src/discovery.ts:56, 104, 242-243` | `responseModesSupported` が core の既存 `DiscoveryConfig` フィールドであること（core 無変更で response_modes_supported を拡張できる根拠）。`authorization_signing_alg_values_supported` は存在しないためスプレッドマージで追加 | 2026-08-02 |
| `packages/cli/src/frameworks/hono/templates.ts:8984-8985` / `web-standard/templates.ts:2079-2080` | conformance テストテンプレートの `response_modes_supported: ['query']` 期待値（jarm 有効時に更新が必要な箇所） | 2026-08-04 |
| `packages/cli/src/frameworks/web-standard/templates.ts:2345-2360` | authorize / login / consent / discovery / conformance の全ルートが hono テンプレートを共有（テンプレート変更が単一ファイルに閉じる根拠） | 2026-08-04 |
| `packages/core/src/auth-transaction.ts`（transaction-binding 差分） | `AuthTransaction` に optional `bindingHash?` が追加され、`createAuthTransaction` が options シグネチャ（後方互換）を得た。core 自身が optional フィールドを扱う先例だが、JARM は core の型に触れず交差型で相乗りする方針を維持 | 2026-08-04 |
| `RELEASE.md`「experimental の bump は常に patch に固定する」 | experimental は手書き changeset 禁止・CI が patch を自動生成・minor/major は release contract 違反（Changeset 要件の修正根拠） | 2026-08-04 |
| `.github/scripts/ensure-experimental-changeset.mjs` / `.github/scripts/verify-release-contract.mjs` | experimental changeset の自動生成と patch 固定の機械的強制（`pnpm run test:release-contract` が検証） | 2026-08-04 |
| `tests/e2e/playwright.config.ts` | webServer が `pnpm --filter @maronn-openid-connect/sample-hono-cloudflare start` で OP を起動（`E2E_OP_PACKAGE` で差し替え可）。e2e-client の登録クライアント定義もここ（U3 解決） | 2026-08-04 |
| `tests/e2e/apps/client.mjs` | E2E 専用クライアント。Node 組み込みのみ・experimental 機能ごとの `/start-*` ルート追加パターン（`/start-par` / `/start-exchange`）と `/callback` の共通処理（U3 解決: `/start-jarm` と JARM 分岐の追加先） | 2026-08-04 |
| `tests/e2e/specs/pushed-authorization-requests.spec.ts:26` | discovery ベースの自己スキップパターン（`--enable` なしサンプルでは skip）。`jarm.spec.ts` が踏襲 | 2026-08-04 |
| `samples/hono-cloudflare/package.json:8` | サンプルの `generate` スクリプト（`--enable par --enable token-exchange --enable transaction-binding`）。実装時に `--enable jarm` を追加する箇所 | 2026-08-04 |
| `tasks/experimental/done/par/` / `tasks/experimental/done/token-exchange/` | 前サイクルの候補評価（JARM 見送り理由）・条件付き補間・discovery マージ・「分岐内で独自に取得」方式の引き継ぎ | 2026-08-02 |
| `tasks/T-019-dpop.md` | 重複回避（DPoP は sender-constrained token で保護対象が異なる） | 2026-08-02 |
| `tasks/p2-signing-alg-ps256.md` | PS256 対応タスクとの連動（alg 拡張は昇格時に歩調を合わせる） | 2026-08-02 |

## 二次資料

なし（本仕様の根拠はすべて上記の一次資料とリポジトリ実装で確認した。ブログ記事等を根拠として使用していない）。

## 記録（一次資料とリポジトリの照合で確定した設計判断）

1. **`typ` ヘッダーを付けない**: JARM は応答 JWT の `typ` を規定せず、§2.3.1 の実例ヘッダーも `{"kid":"laeb","alg":"ES256"}` と `typ` なし。実例に忠実な形を採る（2026-08-02 原文確認）
2. **JARM モードで素の `iss` パラメータを付けない**: §2.3.1 の応答パラメータは `response` のみ。RFC 9207 の役割は JWT の `iss` クレームが担う（RFC 9700 §2.1 が JARM を issuer 識別手段として明示）
3. **`unsupported-jwt-mode` のエラーは平文クエリで返す**: JARM は「AS が対応しない response_mode を要求された場合」の応答形式を規定していない（2026-08-02 原文確認: 該当する規範文言なし）。対応できないモードでは応答を組めないため平文とする設計判断
4. **`.jwt` 系以外の response_mode 値は従来どおり無視する**: response_mode の一般的な拒否規則は JARM のスコープ外。挙動変更を JARM 系列に限定する隔離原則による設計判断
5. **署名 alg は RS256 固定**: `ClientInfo` closed interface（core 無変更制約）＋ JARM §3 の未登録時デフォルトが RS256 であることの両立点
6. **JARM §5.1 の DoS はクライアント側の脅威**: §5.1 は「細工された JWT の `iss` が巨大・低速な JWKS URL を指し、鍵取得でクライアントの帯域・計算資源を消費させる」攻撃であり、「クライアントは鍵取得にこの JWT の情報を使う前に issuer が既知かつ期待どおりであることを確認 MUST」と規定する（2026-08-03 原文確認）。OP 実装には該当せず、クライアント向けドキュメント（understanding-guide の検証手順）に iss 確認→鍵取得の順序として反映。OP 側の署名コスト DoS は JARM 仕様外の観点として Review 2 で別途評価し、セキュリティ要件表に記録
7. **`typ` ヘッダー非定義・最大寿命 10 分 RECOMMENDED の再確認**: 2026-08-03 に原文へ再アクセスし、応答 JWT の `typ` を定義する規定が無いこと・§2.1 の「A maximum JWT lifetime of 10 minutes is RECOMMENDED」を再確認（Review 1 の読解に読み違いなし）
8. **応答 JWT は汎用 `signingKeyProvider` の active key で署名する**: T-022 の per-purpose 鍵対応（`idTokenSigningKeyProvider` / `userinfoSigningKeyProvider`）がテンプレートに入ったが、JARM は応答 JWT の鍵用途を別建てにしていない（§2.2 はクライアントメタデータで alg を決める規定のみで、鍵の用途分離を要求しない。2026-08-04 原文再確認）。よって汎用鍵を使い、JARM 専用 provider の追加は昇格時の検討事項とする（Review 3 の設計判断）
9. **`jarmResponseMode` のマージは put 引数で行う**: `const transaction` の作成文は transaction-binding の条件付き補間 `bindingSecretStep` が所有しており、そこに JARM の変種を足すと binding × jarm の 4 通りの補間分岐が生じる。put 呼び出しの第 2 引数を条件付き補間で差し替える方式なら 2 機能の補間が直交する（Review 3 の設計判断。authorize ルートの応答サイトは try 前の JARM モード変数を参照する形へ統一）
