# `openid` scope の必須化ポリシーと「純 OAuth 2.1 認可サーバー」としての利用可否

## ステータス

🟡 Major（設計判断・適用範囲・拡張性）/ 未着手（人間の方針決定が必要）

## 1. このトピックで確認したいこと

本リポジトリの Authorization Endpoint は、`scope` に `openid` が含まれないリクエストを
**`invalid_scope` で無条件に拒否**する（`packages/core/src/authorization-request.ts:1018-1025`）。
また Refresh Token の発行は `offline_access` scope の付与を条件としている（生成 OP の token ルート）。
`offline_access` は OIDC Core 1.0 §11 が定義する **OIDC 固有の scope** である。

結果として、本 OP は次の 2 点が構造的に成立しない。

1. **`openid` を要求しない純粋な OAuth 2.1 認可リクエスト**（API 認可のみを目的とするクライアント）
2. **`offline_access` の概念を持たないクライアントへの Refresh Token 発行**

これは「OIDC 専用の OP である」という設計判断としては一貫している。
一方でリポジトリのコンセプトは「**最新の OIDC/OAuth 仕様**を誰よりも早く・忠実に検証できる」ことであり、
CLAUDE.md の準拠仕様にも **OAuth 2.1（PKCE 必須）**が明記されている。
OAuth 2.1 側の検証用途を対象に含めるかどうかは、明示的に決めておく価値のある**適用範囲の設計判断**である。

本ファイルでは以下を整理する。

- `openid` 必須化が仕様上どこまで要求されているのか（MUST なのか、実装判断なのか）
- 非 OIDC リクエストを受理する場合に、Basic OP 認定への影響があるか
- Refresh Token 発行ポリシーを `offline_access` から切り離す場合の設計
- 拡張機能（Token Exchange / Device Grant / PAR / MCP 認可）との接続点

### 既存ファイルとの差分（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| `openid` が無いのに ID Token を発行してしまう core API の隙間 | `study-material/id-token-issuance-openid-scope-core-guard.md` |
| `offline_access` の**付与条件**（`prompt=consent` と代替条件の設計） | `study-material/offline-access-scope-grant-policy.md`、`tasks/done/p0-offline-access-prompt-consent.md` |
| `offline_access` を落とした scope 縮小時の rotation 可否 | `tasks/p1-refresh-scope-offline-access-rotation.md`、`study-material/done/refresh-scope-narrowing-offline-access-asymmetry.md` |
| クライアント登録の `grant_types` と Refresh Token 発行の整合 | `tasks/p1-refresh-token-issuance-requires-refresh-grant-registration.md`、`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` |
| 未知 scope の扱い・付与 scope の通知（RFC 6749 §3.3） | `study-material/scope-handling-validation-and-granted-scope.md` |
| RFC 8414（OAuth AS Metadata）を別 well-known で出す話 | `study-material/oauth-authorization-server-metadata-rfc8414.md` |

上記はいずれも「**OIDC リクエストであることを前提とした上での**」論点である。
本ファイルは「**そもそも OIDC リクエストでないものを受理するか**」という前段の適用範囲を扱う点で独立している。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §3.1.2.1 — `openid` 必須は「認証リクエストの定義」であって「拒否義務」ではない

§3.1.2.1 は Authentication Request のパラメータ定義として次を述べる。

> `scope` — REQUIRED. OpenID Connect requests MUST contain the `openid` scope value.
> If the `openid` scope value is not present, the behavior is entirely unspecified.

読み取るべきは最後の一文である。`openid` が無い場合の挙動は **"entirely unspecified"**（完全に未規定）であり、
「拒否しなければならない」とは書かれていない。同じエンドポイントを OAuth 2.0 の認可リクエストとして扱うことは、
OIDC 仕様が禁止しているのではなく、**OIDC 仕様の管轄外**というだけである。

OIDC Core §1 が「OIDC は OAuth 2.0 の上の薄いアイデンティティレイヤである」と位置づけていることとも整合する。
現実の主要 OP（Auth0 / Keycloak / Okta / Microsoft Entra ID など）はいずれも
同一の Authorization Endpoint で `openid` 無しの純 OAuth リクエストを処理する。

### 2.2 OIDC Conformance Profiles（Basic OP）— 非 OIDC リクエストは検査対象外

Basic OP の認定テストはすべて `openid` scope を含む認証リクエストを送る。
`openid` 無しのリクエストに対する OP の挙動を検査するテストモジュールは存在しない。
したがって **「`openid` 無しを受理する」ことが認定を妨げることはない**（逆も同様）。

ただし、受理する場合は次の不変条件を壊さないことが必要である。

- `openid` が無いリクエストで得たトークンでは **ID Token を発行しない**（`study-material/id-token-issuance-openid-scope-core-guard.md`）
- `openid` が無いアクセストークンでは **UserInfo が `insufficient_scope` を返す**（既に `validateUserInfoScope` で実装済み）

この 2 点は既に片方が実装済み・片方が study-material 化されており、**受理を許す前提はほぼ整っている**。

### 2.3 OIDC Core 1.0 §11 — `offline_access` は OIDC の概念

§11 は `offline_access` を「End-User が居ない状態でのアクセスを要求する scope」として定義し、
その付与条件（`prompt=consent` 等）を規定する。
一方 OAuth 2.1 §4.3 / RFC 6749 §1.5 の Refresh Token には、そのような scope による前提条件は無い。
Refresh Token の発行可否は AS のポリシーであり、`grant_types` にクライアントが `refresh_token` を登録しているかで判断するのが
OAuth 側の素直な設計である（RFC 7591 §2）。

現在の生成 OP は Refresh Token 発行を `offline_access` に一本化しているため、
**OIDC の概念が OAuth 側の機能の前提条件になっている**。

### 2.4 OAuth 2.1 §1.4 / RFC 6749 §3.3 — `scope` は AS 定義

OAuth 2.1 において `scope` の値集合は AS が定義するものであり、必須の値は存在しない。
`scope` 自体が OPTIONAL である（AS が既定 scope を決めてよい）。
現在の実装は `scope` パラメータの欠落も `invalid_request` で拒否しているが、
これは OIDC Core §3.1.2.1 の REQUIRED に基づく正しい実装である（OIDC リクエストである限り）。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`scope` の定義と "the behavior is entirely unspecified"） — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §1 Introduction（OAuth 2.0 上のレイヤという位置づけ） — https://openid.net/specs/openid-connect-core-1_0.html#Introduction
- OpenID Connect Core 1.0 §11 Offline Access — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- OpenID Connect Core 1.0 §5.3.1 UserInfo Request（`openid` scope 必須） — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoRequest
- OAuth 2.1 Authorization Framework（draft-ietf-oauth-v2-1）§1.4 Scope / §4.3 Refresh Token — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 6749 §3.3 Access Token Scope — https://www.rfc-editor.org/rfc/rfc6749#section-3.3
- RFC 7591 §2 Client Metadata（`grant_types` の既定と意味） — https://www.rfc-editor.org/rfc/rfc7591#section-2
- OpenID Connect Conformance Profiles（Basic OP のテスト範囲確認） — https://openid.net/certification/

## 4. 現在の実装確認

### 4.1 Authorization Endpoint：`openid` 必須

`packages/core/src/authorization-request.ts:996-1027`

```ts
export function validateAuthorizationScope(
  queryParams, effectiveParams, redirectUri, state?,
): string[] {
  const queryScopeValue = queryParams.scope;
  if (!queryScopeValue) {
    throw new AuthorizationError(AuthorizationErrorCode.InvalidRequest,
      'Missing required parameter: scope', redirectUri, state);
  }
  const scopeValue = effectiveParams.scope ?? queryScopeValue;
  const scope = [...new Set(scopeValue.split(' ').filter((s) => s.length > 0))];
  if (!scope.includes('openid')) {
    throw new AuthorizationError(AuthorizationErrorCode.InvalidScope,
      'scope must include openid', redirectUri, state);   // ← 無条件拒否
  }
  return scope;
}
```

この関数は core の**機能単位のステップ関数**であり、生成 OP はこれを直接呼ぶ。
利用者が生成コードから取り除けば `openid` 無しも通せるが、その場合は下流の不変条件
（ID Token 発行、UserInfo、`offline_access`）を自力で整合させる必要がある。

### 4.2 Token Endpoint：Refresh Token 発行は `offline_access` 依存

生成 OP の token ルート（`samples/*/src/oidc-provider/routes/token.ts`）

```ts
refresh_token: grantHasOfflineAccess ? generateRandomString(32) : undefined,
```

`grantHasOfflineAccess` は authorization_code grant では付与 scope に `offline_access` があるか、
refresh_token grant では `validatedRequest.hadOfflineAccess`（元 grant の scope）で決まる。
`openid` 無しのリクエストは §4.1 で弾かれるため、`offline_access` 単独の grant は**そもそも成立しない**。

### 4.3 UserInfo / ID Token 側の整合

- `validateUserInfoScope`（`userinfo.ts:400-407`）は `openid` を含まないアクセストークンを
  `insufficient_scope`（403）で拒否する。**非 OIDC トークンで UserInfo が漏れることはない**。
- ID Token 側は生成 OP が `issueIdToken: validatedRequest.scope.includes('openid')` を渡すため正しいが、
  core 自身はガードしていない（`study-material/id-token-issuance-openid-scope-core-guard.md`）。

### 4.4 Discovery の広告

`buildProviderMetadata` の `scopes_supported` は利用者が渡す値をそのまま出力する。
`openid` 必須という実行時ポリシーはメタデータに現れない
（OIDC Discovery に「`openid` 必須」を表す項目自体が無いため、これは仕様上正しい）。

## 5. 現在の実装との差分

### 満たしていること

- OIDC リクエストとしての `scope` 検証は §3.1.2.1 に忠実（`scope` 必須、`openid` 必須、Request Object 使用時もクエリ側に必須）。
- 非 OIDC トークンでの UserInfo アクセスは既に塞がれている。
- 重複除去（dedup）が Authorization / Token 両エンドポイントで揃えられている。

### 不足している可能性があること

- **適用範囲の宣言が無い**。README / CLAUDE.md は「OAuth 2.1（PKCE 必須）」を準拠仕様に挙げているが、
  実装は「OIDC 認証リクエストのみ受理する」であり、両者の関係が明文化されていない。
  利用者が「OAuth 2.1 の AS として使えるはず」と誤解する余地がある。
- **純 OAuth クライアントへの Refresh Token 発行経路が無い**。OAuth 2.1 §4.3 のみを検証したい利用者は、
  `offline_access` という OIDC 概念を経由させられる。
- **拡張機能との整合が未確認**。experimental の Device Authorization Grant（RFC 8628）と Token Exchange（RFC 8693）は
  本来 `openid` を必須としないユースケースを含む。現在の Authorization Endpoint ポリシーと
  これらの経路の scope 要件が揃っているかは棚卸しされていない。

### 実装はあるが仕様上の確認が必要なこと

- `openid` 無しを受理する方針を採る場合、`invalid_scope` を返していた挙動が変わる。
  既存の `conformance.test.ts` / `authorization-request.test.ts` にこの拒否を固定したケースがあるため、
  「意図的に OIDC 専用にしている」のか「単に未検討」なのかを文書として確定させる必要がある。

### Basic OP として提供する上で確認すべきこと

- どちらの方針でも Basic OP 認定には影響しない（§2.2）。
- 受理する方針を採る場合、`study-material/id-token-issuance-openid-scope-core-guard.md` の
  core ガードを**先に**入れておくことが安全側の順序になる。

## 6. 改善・追加を検討する理由

- **コンセプトとの整合**: 「最新の OIDC/OAuth 仕様を最速で検証できる」を掲げる以上、
  OAuth 2.1 単体の検証（API 認可、machine-to-machine 近傍、リソース指標）を受け付けるかどうかは
  利用者の期待に直結する。方針を決めて明記すること自体に価値がある（実装を変えない結論でもよい）。
- **拡張機能の受け皿になる**: 既に study-material 化されている拡張のうち、
  Client Credentials Grant、Token Exchange、Resource Indicators（RFC 8707）、Device Grant、
  そして MCP 認可（`study-material/ext-mcp-authorization-op-readiness.md`）は
  いずれも `openid` を前提としない。個別に例外を作るより、**適用範囲を先に決める方が設計が破綻しにくい**。
- **Refresh Token フローの素直さ**: 発行条件を「クライアントの `grant_types` に `refresh_token` があること
  ＋（OIDC リクエストなら）`offline_access` の付与条件を満たすこと」と二段に分けると、
  OAuth 側と OIDC 側の要件が混ざらない。現在の一本化は OIDC 側の条件が OAuth 側を支配している構造。
- **導入しやすさ**: core の該当ガードは 1 関数に閉じており、
  ステップ関数として切り出し済みなので、`requireOpenIdScope?: boolean`（既定 true）のような
  オプトインの緩和は後方互換を壊さずに入れられる。
- **実装しない場合に残る制約**: 純 OAuth 用途の PoC はこのライブラリでは検証できない。
  それ自体は妥当な割り切りだが、**割り切りであることが利用者に伝わっていない**のが現状の問題。

## 7. 実装方針の候補

### 方針 A：OIDC 専用であることを明文化し、実装は変えない

README / CLAUDE.md / Discovery のドキュメントに
「本 OP は OpenID Connect 認証リクエスト専用であり、`openid` を含まない認可リクエストは受理しない」と明記する。

- 利点: 挙動変更ゼロ。適用範囲が明確になり、利用者の誤解が減る。
- 欠点: 純 OAuth の検証用途と、`openid` を前提としない拡張（MCP / Token Exchange / Device Grant）が
  将来的にこの宣言と衝突する。

### 方針 B：core にオプトインの緩和フラグを追加する

`validateAuthorizationScope` に `options?: { requireOpenIdScope?: boolean }`（既定 `true`）を追加。
`false` のときは `openid` 検査をスキップし、以降の経路で
「`openid` が無いなら ID Token を発行しない・UserInfo を許可しない」を保証する。

- 利点: 既定の挙動は不変で後方互換。純 OAuth 検証を明示的なオプトインとして提供できる。
  `study-material/id-token-issuance-openid-scope-core-guard.md` の core ガードと組み合わせると安全に閉じる。
- 欠点: 「`openid` 無し」経路のテスト面積が増える（同意画面の表示内容、`claims` の扱い、Discovery の広告など）。

### 方針 C：Refresh Token 発行ポリシーだけを先に切り離す

`openid` 必須は維持したまま、Refresh Token 発行条件を
「クライアントの `grant_types` に `refresh_token` が含まれる」＋「OIDC リクエストなら `offline_access` の付与条件を満たす」
の二段構成に整理する。

- 利点: 変更が Token Endpoint に閉じる。OIDC の §11 要件を壊さずに、条件の由来が読める構造になる。
- 欠点: `openid` 必須が残るため、純 OAuth 用途の要望自体は解決しない。

### 方針 D：experimental で「OAuth 2.1 AS モード」として実装する

`packages/experimental` に、`openid` 非必須・ID Token 非発行の認可経路を実験的機能として置く。

- 利点: 安定版の挙動を一切変えずに検証できる。experimental の昇格レビュー機構
  （`tasks/experimental/README.md`）に乗せられるため、判断のプロセスが既にある。
- 欠点: Authorization Endpoint の分岐が二重管理になりやすい。core のステップ関数を共有する設計が必須。

**判断材料**: 現在 study-material にある拡張トピックのうち、`openid` を前提としないものが
既に複数（Client Credentials / Token Exchange / Device Grant / Resource Indicators / MCP）ある。
それらを将来実装する意思があるなら方針 B か D を先に決めておく方が設計が安定する。
実装意思が無いなら方針 A で確定させるのが最も誠実。
方針 C は A / B / D のいずれを選んでも独立に価値がある。最終判断は人間が行う。

## 8. タスク案

- [ ] 本 OP の適用範囲（OIDC 専用 / OAuth 2.1 AS も対象）を人間が決定し、README と CLAUDE.md に明記する
- [ ] `study-material` の `openid` を前提としない拡張トピック（Client Credentials / Token Exchange / Device Grant / Resource Indicators / MCP）を棚卸しし、決定した適用範囲との整合を確認する
- [ ] （方針 B / D を採る場合）`study-material/id-token-issuance-openid-scope-core-guard.md` の core ガードを先に実装する
- [ ] （方針 B を採る場合）`validateAuthorizationScope` に `requireOpenIdScope` オプション（既定 true）を追加し、既定挙動が不変であることをテストで固定する
- [ ] （方針 C を採る場合）Token Endpoint の Refresh Token 発行条件を「`grant_types` 由来」と「`offline_access` 由来」に分離し、生成テンプレートと `conformance.test.ts` を更新する
- [ ] `openid` 無しリクエストを受理する場合の同意画面表示（scope しか表示しない画面で `openid` が無い場合の文言）を設計する
- [ ] Discovery の `scopes_supported` と実行時ポリシーの整合をどう表現するかを整理する（`study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` と接続）
