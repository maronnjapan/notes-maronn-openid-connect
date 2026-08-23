# MCP（Model Context Protocol）認可仕様に対する OP 側適合性の棚卸し

## ステータス

🟡 Major（拡張・適用範囲・ロードマップ）/ 未着手（人間の方針決定が必要）

## 1. このトピックで確認したいこと

MCP（Model Context Protocol）の認可仕様は、MCP サーバーを OAuth 2.0 のリソースサーバーとして扱い、
その前段に立つ **認可サーバー（AS）に対して明確な MUST / SHOULD を課す**。
本リポジトリは「PoC で最新の OAuth/OIDC 仕様を素早く検証するための OP」を掲げており、
MCP サーバーを守るための AS を手元に立てたい利用者は、この OP の最も現実的な採用動機のひとつになりうる。

そこで本ファイルでは、**個々の RFC の解説は既存ファイルに委ね**、

- MCP 認可仕様が **AS 側に何を要求しているか**を一次情報から正確に列挙する
- その各項目が本リポジトリで **既に満たされているか / 既存 study-material のどれが担当するか**を対応付ける
- **どの既存トピックにも属さない MCP 固有の差分**を特定する
- 「MCP 対応 OP」と呼べる状態に到達するための最小セットと実装順序の判断材料を出す

ことを目的とする。

### 既存ファイルとの差分（重複回避）

本ファイルは**束ねトピック（棚卸し）**であり、各仕様の解説は行わない。個別仕様は以下を参照する。

| MCP が要求する要素 | 解説を担当する既存ファイル |
|---|---|
| RFC 9728 Protected Resource Metadata | `study-material/ext-protected-resource-metadata-rfc9728.md` |
| RFC 8414 OAuth AS Metadata | `study-material/oauth-authorization-server-metadata-rfc8414.md` |
| RFC 7591 Dynamic Client Registration | `study-material/ext-dynamic-client-registration.md`、`study-material/ext-dynamic-client-registration-management-rfc7592.md` |
| RFC 8707 Resource Indicators | `study-material/ext-resource-indicators-rfc8707.md`、`study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md` |
| public client の Refresh Token ローテーション | `study-material/refresh-token-public-client-rotation-enforcement.md` |
| アクセストークンの `aud` 束縛 | `study-material/authorization-audience-parameter-unvalidated-token-audience.md`、`tasks/done/p1-jwt-access-token-aud-default.md` |
| PKCE / OAuth 2.1 の基礎要件 | `tasks/done/p1-basic-op-pkce-compatibility.md`、`study-material/done/oauth-security-bcp-rfc9700.md` |
| `openid` 非必須化（MCP は `openid` を要求しない） | `study-material/oauth-only-authorization-request-openid-scope-policy.md` |

上表の各ファイルは「その RFC を実装すべきか」を単体で論じている。
本ファイルはそれらを **MCP という 1 つのユースケースから見たときの必須集合と優先順位**として束ね直す点で独立している。
また §5.3 の「MCP 固有の差分」は既存のどのファイルにも記載が無い。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 MCP 認可仕様が AS に課す要件（2025-06-18 リビジョン）

MCP 仕様の Authorization セクションは、認可サーバーに対して次を規定している（一次情報からの抜き出し）。

**MUST**

- OAuth 2.1 を、confidential client と public client の双方に対するセキュリティ対策込みで実装すること
- **OAuth 2.0 Authorization Server Metadata（RFC 8414）を提供すること**
- すべてのエンドポイントを HTTPS で提供すること
- リダイレクト URI を **事前登録値と完全一致**で検証すること
- **自分自身のリソース向けに有効なトークンのみを受け付けること**（＝ audience 束縛されたトークンを発行し、他リソース向けを受理しない）
- **public client に対して Refresh Token をローテーションすること**（OAuth 2.1 §4.3.1）

**SHOULD**

- OAuth 2.0 Dynamic Client Registration（RFC 7591）をサポートすること
- 短寿命のアクセストークンを発行すること
- ユーザーエージェントの自動リダイレクト先を信頼できる URI に限ること

**MCP サーバー（リソースサーバー）側の MUST**（AS の設計に影響する範囲で）

- **RFC 9728 Protected Resource Metadata を実装**し、`/.well-known/oauth-protected-resource` で広告すること
- 401 応答に `WWW-Authenticate` ヘッダを付け、そこから PRM を発見できるようにすること
- トークンを OAuth 2.1 §5.2 に従って検証し、**自分自身が `aud` に含まれないトークンを拒否**すること
- 他所から受け取ったトークンを受理・転送しないこと（token passthrough の禁止）

**MCP クライアント側の MUST**

- 認可リクエストとトークンリクエストの**両方**に、対象 MCP サーバーを指す **RFC 8707 の `resource` パラメータ**を付けること

参照 RFC: RFC 8414 / RFC 7591 / RFC 9728 / RFC 8707 / RFC 9068 / OAuth 2.1（draft-ietf-oauth-v2-1）。

### 2.2 MCP が要求**しない**もの（適用範囲を誤らないために）

- **OpenID Connect は要求されない**。MCP の認可は純粋に OAuth 2.1 ベースであり、
  `openid` scope も ID Token も UserInfo も仕様上の要件に含まれない。
- したがって MCP クライアントは通常 `openid` を送らない。
  これが本リポジトリにとって**最も重い構造的な差分**になる（§5.3）。

### 2.3 リビジョンの流動性（正確性のための注記）

MCP 認可仕様は改訂が続いており、本ファイルが依拠するのは **2025-06-18 リビジョン**である。
`draft` リビジョンが別途公開されており、`resource` パラメータの必須性などについて
コミュニティで議論（例: `resource` を OPTIONAL にする提案）が継続している。
**実装着手時には必ず最新リビジョンを再確認すること**。本ファイルの記述を最新版の根拠として扱ってはならない。

## 3. 参照資料

- Model Context Protocol Specification 2025-06-18, Basic / Authorization — https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- Model Context Protocol Specification（draft リビジョン。改訂追随の確認用） — https://modelcontextprotocol.io/specification/draft/basic/authorization
- MCP 仕様リポジトリ（原文 mdx。差分追跡用） — https://github.com/modelcontextprotocol/modelcontextprotocol
- `resource` パラメータの必須性に関する議論（Issue #1614） — https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1614
- RFC 9728 OAuth 2.0 Protected Resource Metadata — https://www.rfc-editor.org/rfc/rfc9728
- RFC 8414 OAuth 2.0 Authorization Server Metadata — https://www.rfc-editor.org/rfc/rfc8414
- RFC 8707 Resource Indicators for OAuth 2.0 — https://www.rfc-editor.org/rfc/rfc8707
- RFC 7591 OAuth 2.0 Dynamic Client Registration Protocol — https://www.rfc-editor.org/rfc/rfc7591
- RFC 9068 JSON Web Token (JWT) Profile for OAuth 2.0 Access Tokens — https://www.rfc-editor.org/rfc/rfc9068
- OAuth 2.1 Authorization Framework（draft-ietf-oauth-v2-1）§4.3.1 / §5.2 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/

## 4. 現在の実装確認（要件マトリクス）

| # | MCP が AS に課す要件 | 強度 | 本リポジトリの現状 | 担当ファイル |
|---|---|---|---|---|
| 1 | OAuth 2.1（PKCE S256 必須） | MUST | ✅ 実装済み。PKCE 必須が既定、互換モードは明示オプトイン | `tasks/done/p1-basic-op-pkce-compatibility.md` |
| 2 | 全エンドポイント HTTPS | MUST | ✅ `validateIssuer`（`discovery.ts:126-149`）が https 以外を拒否（loopback のみ例外） | — |
| 3 | redirect URI の事前登録・完全一致 | MUST | ✅ 実装済み。fragment / 危険スキームの拒否も済 | `tasks/done/p0-redirect-uri-fragment-rejection.md` ほか |
| 4 | RFC 8414 AS Metadata の提供 | MUST | ❌ 未実装。`/.well-known/openid-configuration` のみで、`/.well-known/oauth-authorization-server` は無い | `study-material/oauth-authorization-server-metadata-rfc8414.md` |
| 5 | 自リソース向けトークンのみ受理（audience 束縛） | MUST | 🟡 部分的。`buildAccessTokenAudience` で `aud` は必ず非空になり、UserInfo は `expectedAudience` を検証する。ただし**認可リクエストの `resource` を受理して aud を絞る経路が無い** | `study-material/ext-resource-indicators-rfc8707.md`、`study-material/authorization-audience-parameter-unvalidated-token-audience.md` |
| 6 | public client の Refresh Token ローテーション | MUST | 🟡 ローテーション自体は実装済み（再利用検知＋ family 失効まで）。ただし「public client では**必ず**ローテーションする」という強制が無い | `study-material/refresh-token-public-client-rotation-enforcement.md` |
| 7 | RFC 7591 Dynamic Client Registration | SHOULD | ❌ 未実装 | `study-material/ext-dynamic-client-registration.md` |
| 8 | 短寿命アクセストークン | SHOULD | ✅ `accessTokenExpiresIn` で設定可能（サンプル既定 3600 秒） | `study-material/token-lifetime-security-policy.md` |
| 9 | 自動リダイレクト先を信頼できる URI に限る | SHOULD | 🟡 クライアント向けの `redirect_uri` は完全一致で堅牢。ただし **OP 内部リダイレクト（`/login` / `/consent`）の origin 導出**が hono テンプレートだけリクエスト URL 由来 | `study-material/done/generated-op-internal-redirect-origin-derivation.md`、`tasks/p1-generated-op-internal-redirect-origin.md` |
| 10 | （RS 側）RFC 9728 PRM の広告 | MUST | ❌ 未実装 | `study-material/ext-protected-resource-metadata-rfc9728.md` |
| 11 | （クライアント側）`resource` パラメータの送信を AS が受理できること | MUST（クライアント側） | ❌ Authorization Endpoint が `resource` を受理しない。未知パラメータとして無視される | `study-material/ext-resource-indicators-rfc8707.md` |

## 5. 現在の実装との差分

### 5.1 満たしていること

MCP が AS に課す MUST のうち、**OAuth 2.1 の基礎部分（#1〜#3）は完全に満たしている**。
これは他の多くの OSS OP が PKCE 任意・redirect URI 部分一致で妥協している点であり、
本リポジトリの Fidelity 軸の強みがそのまま MCP 要件に効いている。

### 5.2 不足していること（既存トピックで担当済み）

#4 / #7 / #10 / #11 は、いずれも**既に study-material に個別トピックが存在する未実装項目**である。
本ファイルの寄与は「MCP という 1 ユースケースにおいて、この 4 つが**同時に必要**である」という束ね方の提示にある。
個別には「あると良い拡張」でも、MCP 対応という文脈では **4 つ揃わないと動かない**。

### 5.3 どの既存ファイルにも属さない MCP 固有の差分

**`openid` scope 必須化が MCP クライアントを構造的に排除する。**

- MCP 認可仕様は OpenID Connect を要求しない。MCP クライアントは `scope` に `openid` を含めない。
- 本リポジトリの Authorization Endpoint は `openid` を含まない `scope` を **`invalid_scope` で拒否**する
  （`packages/core/src/authorization-request.ts:1018-1025`）。
- したがって **MCP クライアントは認可リクエストの時点で必ず失敗する**。
  上記 #4〜#11 をすべて実装しても、この 1 点が残る限り MCP 対応は成立しない。

さらに副次的に、

- Refresh Token の発行が `offline_access`（OIDC 固有 scope）に紐づいているため、
  MCP クライアントは `openid` 必須を回避できたとしても **Refresh Token を得られない**。
  MCP は #6 で public client の Refresh Token ローテーションを MUST としているので、
  「Refresh Token が出せない」ことは要件を満たせないことを意味する。

この 2 点は `study-material/oauth-only-authorization-request-openid-scope-policy.md` が扱う
適用範囲の設計判断そのものであり、**MCP 対応の可否はその判断に完全に従属する**。
本ファイルは「MCP がその判断の具体的な動機になる」という接続を提供する。

### 5.4 Basic OP として提供する上で確認すべきこと

- MCP 対応は **Basic OP 認定とは無関係**である。認定テストは MCP の要件を一切検査しない。
- 逆に、MCP 対応のために `openid` 必須を緩めても Basic OP 認定は影響を受けない
  （認定テストはすべて `openid` 付きで送るため）。
- ただし RFC 8414 メタデータを `/.well-known/oauth-authorization-server` に追加する場合、
  `/.well-known/openid-configuration` との**内容の食い違い**が新たな自己整合の検査対象になる
  （`study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` の延長）。

## 6. 改善・追加を検討する理由

- **Speed 軸に最も直接効く**: MCP 認可は 2025 年以降に実装需要が急増した領域であり、
  「MCP サーバーの認可を手元で検証したいが Keycloak を立てるのは重い」という需要は
  本リポジトリが想定するターゲットユーザー（PoC 開発者・本番導入を見据える開発者）とほぼ一致する。
- **必要な部品がほぼ揃っている**: #4 / #7 / #10 / #11 はいずれも
  「既存の builder / resolver パターンを 1 つ増やす」規模であり、core のアーキテクチャ変更を伴わない。
  最大の障壁は実装量ではなく **§5.3 の適用範囲の判断**である。
- **判断が 1 箇所に集約されている**: MCP 対応の可否は
  「`openid` 必須を緩めるか」という単一の設計判断に還元できる。
  この見通しが立っていること自体が、実装するかしないかを人間が決めやすくする材料になる。
- **実装しない場合に残る制約**: MCP を検証したい利用者は本ライブラリを採用できない。
  RFC 9728 / RFC 8414 / RFC 7591 を個別に実装しても、`openid` 必須が残る限り徒労になるため、
  **個別実装の優先度判断にも影響する**（＝ 適用範囲を決めずに #4 や #10 を先に作ると無駄になりうる）。

## 7. 実装方針の候補

### 方針 A：適用範囲の判断を先に行い、その結果次第で MCP 対応を決める

`study-material/oauth-only-authorization-request-openid-scope-policy.md` の方針決定を先行させ、
「OIDC 専用」と結論した場合は MCP 対応を明示的にスコープ外とする。

- 利点: 無駄な実装が発生しない。判断の順序が正しい。
- 欠点: MCP 対応の可否が別トピックの決定待ちになる。

### 方針 B：experimental で MCP 適合セットをまとめて実装する

`packages/experimental` に、`openid` 非必須の認可経路 ＋ RFC 8414 メタデータ ＋ RFC 9728 PRM ＋ RFC 8707 `resource` 受理を
「MCP 適合プロファイル」として一括で置く。DCR（#7）は SHOULD なので後回しにできる。

- 利点: 安定版の挙動を変えずに、MCP という文脈で動く状態を早く作れる。
  experimental の昇格レビュー機構（`tasks/experimental/README.md`、`pnpm review:experimental`）に乗せられるため、
  「実験 → 評価 → 昇格」のプロセスが既に用意されている。
- 欠点: 4 仕様の同時実装は experimental 1 機能としては大きい。機能 ID の切り方（1 つにまとめるか 4 つに割るか）の設計が必要。

### 方針 C：MCP と独立に、個別 RFC を優先度順に実装する

`resource` 受理（#11）→ RFC 8414（#4）→ RFC 9728（#10）→ DCR（#7）の順で、
それぞれ単体の価値で実装可否を判断する。MCP 対応は結果として近づくが、目標にはしない。

- 利点: 各 RFC が MCP 以外の用途（FAPI 2.0、API ゲートウェイ連携）でも価値を持つため、判断が単純。
- 欠点: `openid` 必須が残る限り MCP では使えないため、「MCP 対応」という成果には到達しない。

### 方針 D：ドキュメントで現状の非対応を明記する

README に「本 OP は OIDC 認証リクエスト専用のため、現時点で MCP 認可のクライアントは接続できない」と記載する。

- 利点: 実装ゼロで利用者の期待値を正しく設定できる。方針 A / B / C のいずれと組み合わせても有効。
- 欠点: 需要そのものは取り逃す。

**判断材料**: MCP 仕様は改訂が続いており（§2.3）、追随コストが継続的に発生する点は
「Speed 軸」の主張と表裏である。追随を続ける意思があるなら方針 B が最短。
意思が無いなら方針 A → D で早期に確定させる方が、study-material の他トピックの優先度判断も明確になる。
最終判断は人間が行う。

## 8. タスク案

- [ ] MCP 認可仕様の **最新リビジョン**を再確認し、本ファイルの §2.1 要件表を更新する（`resource` の必須性に関する議論の帰結を含む）
- [ ] `study-material/oauth-only-authorization-request-openid-scope-policy.md` の適用範囲判断を先に行う（本トピックの前提条件）
- [ ] 適用範囲が「OAuth 2.1 AS も対象」と決まった場合、MCP 適合セット（#4 / #10 / #11 と `openid` 非必須化）を experimental の機能 ID としてどう切るかを設計する
- [ ] `resource` パラメータを Authorization Endpoint で受理し、アクセストークンの `aud` に反映する経路を設計する（`study-material/ext-resource-indicators-rfc8707.md` と統合して検討）
- [ ] public client に対する Refresh Token ローテーション強制（#6）の実装可否を判断する（`study-material/refresh-token-public-client-rotation-enforcement.md` と統合）
- [ ] RFC 8414 メタデータを追加する場合、`/.well-known/openid-configuration` との内容整合を検証するテストを設計する
- [ ] 適用範囲が「OIDC 専用」と決まった場合、README に MCP 非対応を明記し、本ファイルを判断済みとして `done` へ移す
