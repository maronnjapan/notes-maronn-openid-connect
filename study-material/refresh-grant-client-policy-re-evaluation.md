# `refresh_token` グラント時にクライアント登録ポリシーが再評価されない（発行後のポリシー変更が最長 90 日効かない）

## ステータス

🟠 High（セキュリティ / 運用）/ 未着手

## 1. このトピックで確認したいこと

Refresh Token は本リポジトリの既定で **絶対有効期限 7,776,000 秒（90 日）** を持ち、ローテーションを跨いでも `originalIssuedAt` から起算した同じ失効時刻を保つ（`refreshTokenAbsoluteLifetime`）。すなわち一度発行された grant は、最長 90 日にわたってアクセストークンを取り直せる。

その 90 日の間に **クライアント登録やサーバ側ポリシーが変更された場合、refresh_token グラントはそれを反映するか** を確認したい。具体的には次の 5 つ。

| 発行後に変わりうるもの | refresh 時に再評価されるか |
|---|---|
| `grant_types` から `refresh_token` を外した | ✅ される（`validateClientGrantType`） |
| `token_endpoint_auth_method` を変更した | ✅ される（`validateClientAuthMethod`） |
| `client_secret` を回転した | ✅ される（`verifyClientSecret`） |
| ~~`offlineAccessAllowed` を `false` にした~~ | 独自フラグごと廃止済み（下記の追記を参照） |
| 同意（consent）を撤回した / 同意対象 scope を絞った | ❌ **されない**（明示的な revoke API を呼んだ場合を除く） |

前者 3 つはクライアント**認証・認可**の経路にあるため再評価される。後者 2 つは**認可時点でしか評価されない**ため、既存の Refresh Token には効かない。

> 追記: `offlineAccessAllowed` は廃止され、Refresh Token の可否は `grant_types` に一本化された。
> `grant_types` は refresh 時に `validateClientGrantType` が再評価するため、この行の
> 「されない」は解消している。あわせて online refresh token（`offline_access` を伴わない
> 付与で発行され、ログインセッションに束縛される Refresh Token）が入ったので、
> セッション終了という失効軸が 1 つ増えた。offline refresh token（`offline_access` あり）は
> 従来どおりセッションから独立しており、本ファイルの残る論点（同意撤回が既存 grant に
> 届かない）はそちらに当てはまる。
> 経緯は `study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` を参照。

本ファイルはこの「発行後のポリシー変更が、既存 grant に届かない」という差分を扱う。

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| ローテーション機構・再利用検知・family cascade | `study-material/refresh-token-rotation-replay-grace.md`、`study-material/revocation-refresh-token-family-cascade.md` |
| 絶対有効期限・idle timeout | `tasks/done/p1-refresh-token-absolute-lifetime.md`、`study-material/done/refresh-token-idle-inactivity-timeout.md` |
| `offline_access` の**付与条件**（§11、`prompt=consent`）と `offlineAccessAllowed` / `grant_types` の二重管理 | `study-material/offline-access-scope-grant-policy.md`、`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md`、`tasks/p1-refresh-token-issuance-requires-refresh-grant-registration.md` |
| クライアント登録メタデータの**入口での**強制（`grant_types` / `response_types` / `token_endpoint_auth_method`） | `study-material/done/client-metadata-enforcement.md` |
| 同意撤回時にトークンを明示的に失効する経路 | `study-material/done/consent-withdrawal-grant-token-revocation.md` |
| 資格情報変更時の subject 単位の一括失効 | `study-material/subject-wide-token-invalidation-on-credential-change.md` |
| refresh 時の scope 縮小と `offline_access` の非対称 | `study-material/done/refresh-scope-narrowing-offline-access-asymmetry.md`、`study-material/refresh-token-grant-scope-preservation.md` |

**本ファイル固有の差分**は「**明示的な失効操作を伴わない、受動的なポリシー変更**が既存 grant に届くか」である。
`done/consent-withdrawal-grant-token-revocation.md` は「撤回したら revoke する（能動的な失効経路）」を扱い、`done/client-metadata-enforcement.md` は「入口（authorize / token の入り口）で登録内容を強制する」を扱う。どちらも「設定を書き換えただけのとき、既に出ている Refresh Token はどうなるか」は扱っていない。

## 2. 関連する仕様・基準

共通の Refresh Token 仕様説明（rotation の SHOULD / 再利用時の失効 / public client の MUST）は上記既存ファイルにあるため繰り返さない。本トピックに関係する条文は次のとおり。

### 2.1 RFC 6749 §6 — Refreshing an Access Token

> The authorization server MAY issue a new refresh token, in which case the client MUST discard the old refresh token and replace it with the new refresh token. The authorization server MAY revoke the old refresh token after issuing a new refresh token to the client. **The scope of the access request... MUST NOT include any scope not originally granted by the resource owner**, and if omitted is treated as equal to the scope originally granted by the resource owner.

「元の付与を超えてはならない」は上限の規定であり、**「元の付与が今も有効か」を再確認せよとは書かれていない**。逆に言えば、再確認するかどうかは実装裁量である。

### 2.2 RFC 6749 §10.4 / RFC 9700 §4.14 — Refresh Token の保護

- RFC 6749 §10.4: 認可サーバは Refresh Token とクライアントの binding を維持し、**「resource owner が認可を取り消した場合を含め、Refresh Token を失効させる手段を持つべき」**という趣旨の要求（Refresh Token Security Considerations）
- RFC 9700（OAuth 2.0 Security Best Current Practice）§4.14: Refresh Token は長寿命になりやすく、漏洩・悪用の主要面である。rotation・限定的な有効期限・sender-constraining のいずれかで露出を抑えることを求める

つまり **「認可の取り消し／権限縮小が Refresh Token に反映される経路を持つこと」は Security BCP の趣旨に含まれる**。本リポジトリは能動的な revoke API（RFC 7009 / `revokeTokensByGrantId` / 同意撤回タスク）を持つが、「設定変更を反映する」経路は持たない。

### 2.3 OIDC Core 1.0 §11 — Offline Access

> The use of Refresh Tokens is not exclusive to the `offline_access` use case... When an Access Token is used at the UserInfo Endpoint to obtain Claims about the End-User, the OP MUST... The Authorization Server MUST ensure that the End-User has authorized the release of the `offline_access` scope...

`offline_access` は「エンドユーザーがオフラインアクセスを許可したこと」を表す。OP 側の `offlineAccessAllowed` フラグ（本リポジトリ独自）は「そのクライアントにオフラインアクセスを許すか」という**管理者側のポリシー**であり、性質が違う。管理者がこれを `false` に戻したとき、既存の Refresh Token をどう扱うかは仕様に規定が無い**が、`false` にした管理者の意図はほぼ確実に「もうオフラインアクセスさせない」である**。

### 2.4 RFC 7009 — OAuth 2.0 Token Revocation

明示的な失効 API は実装済み（`packages/core/src/revocation.ts`）。本トピックは「失効 API を呼ばずに設定だけ変えた場合」を扱うため、RFC 7009 の範囲外である点を明確にしておく。

## 3. 参照資料

- **RFC 6749 §6 Refreshing an Access Token** — https://www.rfc-editor.org/rfc/rfc6749#section-6 （scope は元の付与を超えてはならない。再確認の義務は規定されていない）
- **RFC 6749 §10.4 Refresh Tokens** — https://www.rfc-editor.org/rfc/rfc6749#section-10.4 （Refresh Token と client の binding、失効手段）
- **RFC 9700 (OAuth 2.0 Security Best Current Practice) §4.14 Refresh Token Protection** — https://www.rfc-editor.org/rfc/rfc9700#section-4.14 （長寿命 Refresh Token の露出低減。rotation / 限定的有効期限 / sender-constraining）
- **OAuth 2.1 draft §4.3.1 Refresh Token Grant** — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （public client の rotation or sender-constrained MUST）
- **OpenID Connect Core 1.0 §11 Offline Access** — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess （`offline_access` の付与条件）
- **RFC 7009 OAuth 2.0 Token Revocation** — https://www.rfc-editor.org/rfc/rfc7009 （明示的失効。本トピックの範囲外であることの確認先）
- 本リポジトリ内: `packages/core/src/refresh-token-grant.ts`（`validateRefreshTokenGrant` の全ステップ）、`packages/core/src/token-request.ts`（`TokenClientInfo` / `validateClientGrantType`）、`packages/cli/src/frameworks/hono/templates.ts`（`grantHasOfflineAccess` の算出、`refreshTokenAbsoluteLifetime: 7776000`、authorize 側の `offlineAccessAllowed` フィルタ）

## 4. 現在の実装確認

### 4.1 認可エンドポイント側: `offlineAccessAllowed` で `offline_access` を落とす

生成 OP の `/authorize`（`packages/cli/src/frameworks/hono/templates.ts`）は、認可コード発行の直前に必ず次のフィルタを通す（`prompt=none` 経路・SSO 経路・同意経路のいずれも同じ）。

```ts
const clientConfig = await clientResolver.findClient(transaction.clientId);
const grantedScope = transaction.scope.split(' ').filter((s: string) => {
  if (s === 'offline_access' && !clientConfig?.offlineAccessAllowed) return false;
  return Boolean(s);
});
```

`offlineAccessAllowed` は生成コードの `config.ts` にある `RegisteredClient` のフィールドであり、**core の型（`ClientInfo` / `TokenClientInfo`）には存在しない**。

### 4.2 Token エンドポイント側: refresh では保存済み grant だけを見る

```ts
const grantHasOfflineAccess =
  validatedRequest.grantType === 'refresh_token'
    ? validatedRequest.hadOfflineAccess          // ← 保存済み Refresh Token の scope から算出
    : validatedRequest.scope.includes('offline_access');
```

`hadOfflineAccess` は `buildValidatedRefreshTokenRequest`（`packages/core/src/refresh-token-grant.ts`）が `refreshTokenInfo.scope.includes('offline_access')` で作る値であり、**現在のクライアント登録を一切参照しない**。

そして `refresh_token` の再発行は `grantHasOfflineAccess ? generateRandomString(32) : undefined` で決まる。つまり:

- 発行時に `offline_access` を含んでいた grant は、`offlineAccessAllowed` が後から `false` になっても **ローテーションを続け、90 日間アクセストークンを取り直せる**

### 4.3 `validateRefreshTokenGrant` の全ステップに、クライアント登録の参照が無い

`packages/core/src/refresh-token-grant.ts` の合成関数が呼ぶのは次の 6 ステップである。

1. `resolveRefreshToken` — ストアから引き当てる
2. `validateRefreshTokenUnused` — rotation 再利用検知
3. `validateRefreshTokenClient` — `refreshTokenInfo.clientId === authenticatedClientId`
4. `validateRefreshTokenExpiration` — 絶対有効期限
5. `validateRefreshTokenIdleTimeout` — 任意の idle 失効
6. `validateRefreshTokenScope` — 要求 scope ⊆ 元 scope

いずれも引数に `TokenClientInfo` を取らない。クライアント登録が参照されるのは、この合成関数より**手前**の `validateClientGrantType(client, grantType)` だけである。

### 4.4 同意（consent）は refresh 経路で一切参照されない

- `ConsentResolver.hasConsent` は認可エンドポイント（`validatePromptNoneConsent` / SSO 経路の同意スキップ判定）でのみ呼ばれる
- token ルートの refresh 分岐に `consentResolver` の呼び出しは無い
- したがって `revokeConsent` を呼んだだけで（かつトークン失効を伴わなければ）、既存 Refresh Token は生き続ける
  - なお「同意撤回時に grant のトークンを失効させる」経路自体は `study-material/done/consent-withdrawal-grant-token-revocation.md` で検討済み。本ファイルはその**能動的失効を呼び忘れた／呼べない場合**の受動的な安全網の不在を指摘する

### 4.5 露出ウィンドウの大きさ

生成 OP の既定値は次のとおり。

| 設定 | 既定値 | 意味 |
|---|---|---|
| `refreshTokenAbsoluteLifetime` | `7776000`（90 日） | ローテーションを跨いだ絶対失効までの期間 |
| `accessTokenExpiresIn` | `3600`（1 時間） | 各アクセストークンの寿命 |

したがって `offlineAccessAllowed` を `false` に戻しても、**最長 90 日間・1 時間ごとに新しいアクセストークンが発行され続ける**。

## 5. 現在の実装との差分

### 満たしていること

- クライアントの**認証**面（`client_secret` 回転、`token_endpoint_auth_method` 変更）は refresh 時に再評価される
- クライアントの `grant_types` から `refresh_token` を外せば、refresh は `unauthorized_client` で止まる（= 管理者が「refresh を止める」意図を表明する手段は 1 つ存在する）
- 明示的な失効手段は揃っている（RFC 7009 revocation エンドポイント、`revokeTokensByGrantId`、同意撤回タスク）

### 不足している可能性があること

- 🟠 **`offlineAccessAllowed` の変更が既存 grant に届かない**。認可エンドポイントでは強制されるポリシーが、Token エンドポイントの refresh 経路では強制されない。同じフラグが片方でしか効かないのは、利用者から見て予測しづらい
- 🟠 **同意状態が refresh 時に確認されない**。`ConsentResolver` を実装している構成でも、refresh は同意を見ない。「同意を撤回したのにトークンが取れ続ける」は、撤回 API とトークン失効の呼び出しを両方正しく実装した場合のみ回避できる
- 🟡 **クライアント単位の許可 scope という概念が無い**。`ClientInfo` / `TokenClientInfo` に scope allowlist が無いため、「このクライアントは `email` を要求できない」というポリシーを表現する場所が存在しない（OP 全体の scope ポリシーは `study-material/scope-handling-validation-and-granted-scope.md` が扱う）
- 🟡 **`offlineAccessAllowed` が core の型に無い**。生成コード固有のフィールドであるため、core を直接使う利用者には同じポリシーを表現する標準的な場所が無い

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **どこまで再評価するのが「正しい」か**。RFC 6749 §6 は再評価を要求していない。実運用の OP（IdaaS 各社）は「登録変更は既存トークンに即時反映される」ものと「次回認可から反映される」ものを分けて設計しており、業界にも唯一解が無い。本リポジトリとして**どちらを既定にするか**を明示的に決め、文書化する必要がある
- 🟡 **`grant_types` からの `refresh_token` 除去との重複**。`offlineAccessAllowed` を見なくても `grant_types` を変えれば止められる。二重管理の解消（`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` の方針 A = `offlineAccessAllowed` の廃止）が先に決まれば、本トピックの一部は自動的に解消する。**両者の依存関係を整理してから着手すべき**

### セキュリティ上、改善した方がよいこと

- 🟠 **インシデント対応の穴**。「このクライアントのオフラインアクセスを止めたい」という運用判断に対し、`offlineAccessAllowed: false` は効かない。管理者はそれを知らないまま「止めた」と誤認しうる。実際に止めるには `grant_types` を変える、または Refresh Token を個別に失効する必要がある
- 🟠 **フェイルオープンな挙動**。ポリシーが厳しくなる方向の変更が無視されるのは、安全側ではなく危険側への倒れ方である

### 相互運用性の観点で改善した方がよいこと

- 🟢 プロトコル上の相互運用性への影響は無い。影響するのは OP の運用モデルの予測可能性

### Basic OP として提供する上で確認すべきこと

- Basic OP 認定要件には含まれない。ただし「Refresh Token フローの安全性」を検証したい利用者にとっては、観測できる挙動として重要

## 6. 改善・追加を検討する理由

### なぜ価値があるのか

- **「設定を厳しくしたのに効かない」は、セキュリティ機能として最も避けたい失敗の形**である。利用者は設定を変えた時点で防御が有効になったと考える
- **PoC で検証したい典型シナリオに直結する**。「クライアントの権限を剥奪したら既存トークンはどうなるか」は、IdaaS 移行を検討する開発者が必ず試す挙動である。本リポジトリの目的（仕様と挙動を素早く検証する）に照らして、この経路が観測できることには価値がある
- **90 日という既定値が問題を増幅している**。露出ウィンドウが短ければ実害は限定的だが、既定 90 日では実質「変更が反映されない」と同義になる

### Basic OP として必要か、拡張機能として有用か

- **どちらでもなく、運用ポリシーの設計判断**である。仕様上の MUST は無い。ただし RFC 9700 §4.14 の趣旨（長寿命 Refresh Token の露出低減）に照らせば、「ポリシー変更が届く経路を持つこと」は Security BCP に沿った改善と位置づけられる

### 現在のリポジトリ構成から見た導入しやすさ

- **導入しやすい点**:
  - refresh 経路は既に `tokenClient`（`TokenClientInfo`）を手に持っている（`resolveAuthenticatedTokenClient` の戻り値）。ポリシー判定を足す引数は揃っている
  - `validateRefreshTokenGrant` はステップ関数の合成であり、ステップを 1 つ足す構造がすでに用意されている（生成コードはステップを個別に呼ぶ形で出力される）
  - `ConsentResolver` は既に生成 OP の変数として存在しており、token ルートから参照可能な位置にある
- **導入しにくい点**:
  - `offlineAccessAllowed` は core の型に無いため、core にステップを足すなら **core の型にポリシーフィールドを持ち込む**か、**判定をコールバックとして注入する**かの設計判断が要る
  - 同意を refresh のたびに問い合わせると、`ConsentResolver` の実装（DB アクセス）が Token Endpoint のホットパスに乗る。性能とのトレードオフがある
  - `offlineAccessAllowed` の二重管理解消（既存 study-material の方針 A）と衝突しうる。先に二重管理の方針を決めるべき

### 既存実装との接続

- `packages/core/src/refresh-token-grant.ts`: 新しいステップ関数の追加点
- `packages/core/src/token-request.ts`: `TokenClientInfo` にポリシーフィールドを足す場合の変更点
- `packages/cli/src/frameworks/hono/templates.ts`: refresh 分岐にステップを差し込む点。`grantHasOfflineAccess` の算出式の変更点
- `samples/*/conformance.test.ts`: 挙動の契約固定（生成元は `packages/cli`）

### 利用者・開発者・運用者のメリット

- 運用者: 設定変更が意図どおり効く。インシデント対応の手順が単純になる
- 利用者（PoC 開発者）: 「権限剥奪 → 既存トークンの挙動」を実際に観測でき、IdaaS 移行時の設計判断材料になる
- 開発者: 認可エンドポイントと Token エンドポイントで同じポリシーが同じ意味を持つ

### 実装しない場合に残る制約・リスク

- `offlineAccessAllowed: false` が「新規発行は止まるが既存は 90 日生き続ける」という**部分的にしか効かない設定**のまま残る。少なくともこの挙動は文書化が必要
- 同意撤回時にトークン失効の呼び出しを忘れると、撤回が無効になる（安全網が無い）
- 「Refresh Token フローの改善」という観点で、rotation・寿命・再利用検知は揃っているのに、認可の**継続的な妥当性**だけが抜けた状態が続く

## 7. 実装方針の候補

**最終判断は人間が行う。以下は判断材料の整理である。**

### 方針 A: `offlineAccessAllowed` の二重管理を先に解消する（既存方針との統合）

`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` の方針 A（`offlineAccessAllowed` を廃止し `grant_types` に一本化）を採用する。

- 利点: `grant_types` は refresh 時に既に再評価されているため、**本トピックの `offlineAccessAllowed` 部分は追加実装ゼロで解消する**。標準メタデータ（RFC 7591 §2）に寄せられる
- 欠点: 「オフラインアクセスの可否」と「refresh_token grant の可否」は概念上は別物であり、一本化すると表現力が落ちる場面がありうる
- 依存: `tasks/p1-refresh-token-issuance-requires-refresh-grant-registration.md` の完了状況を先に確認すること

### 方針 B: refresh 経路にポリシー再評価ステップを追加する

`validateRefreshTokenGrant` に「クライアント登録ポリシーの再評価」ステップを足す。

- 実装形: 新しいステップ関数（例: 現在のクライアント情報とポリシー判定コールバックを受け取り、満たさなければ `invalid_grant`）を core に追加し、生成コードのステップ列に挿入する
- 利点: 「何を再評価するか」を利用者が差し替えられる。core は具体的なポリシー（`offlineAccessAllowed` 等）を知らずに済む
- 欠点: ステップが 1 つ増え、生成コードが長くなる。既定で何を評価するか（既定は「何もしない」か「offline_access を評価する」か）の判断が要る
- 返すエラー: RFC 6749 §5.2 の `invalid_grant`（付与がもはや有効でない）が意味的に近い。`unauthorized_client` も候補だが、こちらは「クライアントがその grant type を使えない」の意味なので使い分けを明記する必要がある

### 方針 C: 同意の再確認を refresh 経路に追加する（オプトイン）

`ConsentResolver.hasConsent` を refresh 時にも呼ぶ。

- 利点: 同意撤回が能動的なトークン失効なしで効くようになる（安全網）
- 欠点: Token Endpoint のホットパスに DB アクセスが増える。`ConsentResolver` 未実装の構成では何も変わらない（= 既定では効かない）
- 既定: オプトイン（設定で有効化）にするのが現実的か、既定 ON にするかは判断事項

### 方針 D: 既定の絶対寿命を短くする

`refreshTokenAbsoluteLifetime` の既定 90 日を短縮する（例: 14 日 / 30 日）。

- 利点: 実装変更が最小。ポリシー変更が届かない窓そのものが縮む
- 欠点: 根本解決ではない。既定値の変更は既存利用者の挙動を変える
- 補足: 寿命の推奨値そのものは `study-material/token-lifetime-security-policy.md` が扱う論点であり、本トピック単独で決めるべきではない

### 方針 E: 文書化のみ

「クライアント登録の変更のうち、既存 Refresh Token に即時反映されるもの / されないもの」を表にして README・JSDoc に明記し、止めたい場合の正しい手順（`grant_types` の変更 or 明示的失効）を示す。

- 利点: 実装リスクゼロ。誤認による事故を減らせる
- 欠点: フェイルオープンな挙動自体は残る

### 横断的な論点

- **どのポリシー変更を「即時反映」にするかの原則を先に決める**。個別に足していくと一貫性を失う。「認証・クライアント認可は即時反映、エンドユーザーの認可（consent）と OP 側の付与ポリシーは次回認可から反映」といった原則を決め、例外だけを実装する形が保守しやすい
- **`study-material/subject-wide-token-invalidation-on-credential-change.md` との関係**。あちらは「エンドユーザー側の変化」、本ファイルは「クライアント・OP 側の変化」。どちらも「発行済みトークンへの伝播」という同じ機構（例: grant への世代番号付与）で実装できる可能性があり、方針決定時に併せて検討する価値がある

## 8. タスク案

- [ ] **依存関係の整理**: `tasks/p1-refresh-token-issuance-requires-refresh-grant-registration.md` と `study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` の方針決定状況を確認し、`offlineAccessAllowed` を残すのか廃止するのかを先に確定する
- [ ] **原則の決定**: 「クライアント登録・ポリシー変更のうち、既存 Refresh Token に即時反映されるものはどれか」を決め、表として文書化する
- [ ] **現状の挙動を回帰テストで固定する**（方針を問わず先にやる価値がある）:
  - [ ] `should keep rotating refresh tokens after offlineAccessAllowed is set to false`（現状の挙動を明示的に固定 or 逆に失敗させて修正対象とする）
  - [ ] `should reject the refresh_token grant after refresh_token is removed from the client grant_types`（既に効いている経路の回帰固定）
  - [ ] `should reject the refresh_token grant after the client secret is rotated`（同上）
- [ ] **方針 B を採る場合の実装**: core に「refresh 時のポリシー再評価」ステップ関数を追加し、`packages/cli` のテンプレートのステップ列へ挿入する。返すエラーコード（`invalid_grant` / `unauthorized_client`）を決めて JSDoc に根拠を書く
- [ ] **方針 C を採る場合の実装**: refresh 経路で `ConsentResolver.hasConsent` を呼ぶオプションを追加し、既定 ON / OFF を決める
- [ ] **conformance テストの更新**: 決定した挙動を `packages/cli` の `conformance.test.ts` 生成コードへ反映し、`samples/*` を再生成する
- [ ] **E2E の検討**: 「認可 → refresh 成功 → ポリシー変更 → refresh の結果」を `tests/e2e` で観測できるか検討する
- [ ] **ドキュメント**: 方針 E は他方針を採る場合でも実施する。README / `config.ts` のコメントに、どの設定変更が既存トークンに届くかを明記する
