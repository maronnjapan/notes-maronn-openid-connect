# Dynamic Client Registration の `scope` メタデータ登録とクライアント単位の最小権限

## ステータス

🟢 タスク化済み（`tasks/p2-dcr-scope-metadata-registration.md`）

## 1. このトピックで確認したいこと

PR #131 で実装した Dynamic Client Registration（RFC 7591）が、クライアントメタデータ `scope` を登録へ反映できるかを確認する。
現在の実装は `scope` を未知フィールドと同じ扱いで黙って捨てる。
そのため動的登録クライアントには、静的クライアントで利用できるクライアント単位のスコープ制限（core の `ClientInfo.scope`）を掛ける手段が無い。
この状態が RFC 7591 と最小権限の方針に照らして妥当か、登録へ反映するならどう接続するかを整理する。

DCR の導入判断そのものは `study-material/done/`・`tasks/experimental/done/dynamic-client-registration/` で扱い済みであり、ここでは実装後に残った `scope` の扱いだけを扱う。

## 2. 関連する仕様・基準

- **RFC 7591 §2 の `scope`**：クライアントがアクセストークン要求時に使ってよい scope 値のスペース区切り文字列。省略時は「an authorization server MAY register a client with a default set of scopes」とされ、既定セットでの登録が許される
- **RFC 7591 §2（メタデータ処理の一般規則）**：認可サーバーは、クライアントが提示したメタデータ値を適切な値へ置き換えてよい。理解しないメタデータは無視しなければならない（MUST ignore）
- **RFC 7591 §3.2.1**：登録応答は、登録済みの全メタデータ（サーバーが付与・置換したフィールドを含む）を返さなければならない（MUST）。クライアントは、応答の値が自分の提示値と異なり得る前提で応答を確認する
- **RFC 6749 §3.3**：`scope` パラメータの構文（スペース区切り、scope-token の文字集合）
- **本リポジトリの既存機構**：`ClientInfo.scope`（登録済みスコープ一覧）。設定すると一覧外の scope 要求は `validateClientScope` が `invalid_scope` で拒否する

注記：この調査を行ったセッションではネットワーク制限により RFC 原文を再取得できなかった。
§3.2.1 の MUST は `tasks/experimental/done/dynamic-client-registration/understanding-guide.md` に引用済みの条文と一致することを確認したが、§2 の `scope` 定義の引用文は実装時の知識に依っている。
条文を根拠として引用し直す場合は原文を参照すること。

## 3. 参照資料

- RFC 7591 OAuth 2.0 Dynamic Client Registration Protocol — https://www.rfc-editor.org/rfc/rfc7591 （§2 `scope`、§3.2.1 応答、§3.2.2 エラー）
- RFC 6749 The OAuth 2.0 Authorization Framework — https://www.rfc-editor.org/rfc/rfc6749 （§3.3 scope 構文）
- RFC 9700 Best Current Practice for OAuth 2.0 Security — https://www.rfc-editor.org/rfc/rfc9700 （クライアントへ与える権限を最小化する方針）
- 実装時の仕様判断の記録：`tasks/experimental/done/dynamic-client-registration/specification.md`（非目標の節は RFC 7592、`software_statement`、OIDC 固有メタデータ、レート制限を挙げるが、`scope` は挙げていない）
- 実装解説：`implementation-guides/experimental/dynamic-client-registration.md`

## 4. 現在の実装確認

検証関数 `validateClientRegistrationRequest`（`packages/experimental/src/dynamic-client-registration/registration-request.ts`）は、理解する 5 フィールド（`redirect_uris` / `token_endpoint_auth_method` / `grant_types` / `response_types` / `client_name`）だけを選び取る allowlist-pick 方式で、`scope` はこの一覧に無い。
したがって `scope` を含む登録リクエストでも、`scope` は読まれずに捨てられる。

登録レコード（`registered-client.ts` の `DynamicallyRegisteredClient`）にも scope フィールドが無く、201 応答（`buildClientRegistrationResponse`）にも `scope` は含まれない。

一方 core には、クライアント単位のスコープ制限がすでにある。
`ClientInfo.scope`（`packages/core/src/authorization-request.ts` 130-136 行）を設定したクライアントは、一覧外の scope 要求を `validateClientScope` が `invalid_scope` で拒否する。
CLI 生成コードでも、認可エンドポイント、デバイス認可、CIBA の各リクエスト処理が `client.scope` を検査している（`packages/cli/src/frameworks/hono/templates.ts` の 3493 行、4303-4310 行、5120-5130 行付近）。

動的登録クライアントは `scope` を常に持たないため、「省略時はクライアント単位の制限を掛けない」という `ClientInfo.scope` の規約どおり、プロバイダーが受理する全スコープ（`--scope` で宣言したカスタムスコープを含む）を要求できるクライアントとして登録される。

## 5. 現在の実装との差分

満たしていること：

- `scope` を無視すること自体は RFC 7591 違反ではない。§2 は提示値の置き換えを許し、省略時の既定セット登録も MAY にとどまる。登録しなかった `scope` を §3.2.1 応答へ載せない点も、応答の規定と整合している

不足している可能性があること：

- 登録者が `scope` で制限を明示しても黙って無視されるため、クライアントは「無制限で登録された」ことを応答から読み取れない（応答に `scope` が無いことの意味を知っている必要がある）
- 静的クライアントでは可能な最小権限の設定が、動的登録経由では一切できない

セキュリティの観点で改善した方がよいこと：

- 既定がオープン登録（RFC 7591 §3.1 の SHOULD に従う）なので、誰でも「全スコープを要求できるクライアント」を作れる。ユーザー認証と同意が別途必要なため直ちに権限昇格にはならないが、同意を誘導されたときに漏れる範囲をクライアント登録の段階で狭める手段が無い

相互運用性の観点で確認すべきこと：

- OIDF Conformance Suite や MCP クライアントのような DCR を使う実クライアントは `scope` を送ることがある。受理して登録・応答へ反映すれば、登録結果がクライアント側から観測できる

## 6. 改善・追加を検討する理由

core の `ClientInfo.scope` と各エンドポイントの検査がすでに存在するため、DCR 側は「検証して登録レコードに積む」だけで既存の拒否経路に乗る。
実装コストは、検証関数へのフィールド追加、登録レコードと応答への反映、生成コードから受理可能スコープ一覧を渡す配線に収まる。

実装しない場合、動的登録クライアントの権限は常にプロバイダー全体のスコープ集合と一致し続ける。
PoC 用途では致命的ではないが、「静的登録とできることが揃っていない」という非対称が残り、DCR で接続したクライアントだけ最小権限を適用できない。

## 7. 実装方針の候補

- **方針A**：`scope` を検証して登録・応答へ反映する。検証関数にオプション `supportedScopes` を追加し、スペース区切り文字列として構文を検査し、一覧外の値は `invalid_client_metadata`（値を反映しない固定文言）で拒否する。登録レコードへ積み、201 応答にはスペース区切りへ戻した `scope` を載せる。省略時は現状どおり制限無しで登録し、応答にも載せない
- **方針B**：一覧外の値を拒否せず、受理可能な値との積集合へ置き換えて登録する（§2 の置き換え許容を使う）。黙った無視よりは観測可能だが、「要求した値が消えた」ことの検出をクライアント側へ要求する
- **方針C**：現状維持とし、`scope` が無視されることと動的登録クライアントが無制限であることを README と実装解説に明記する

方針Aが、このリポジトリの既存の検証スタイル（厳格に拒否し、リクエスト値を反映しない固定 ASCII 文言で返す）と一致する。
最終判断は人間が行う。

## 8. タスク案

- 方針Aの実装 → `tasks/p2-dcr-scope-metadata-registration.md` としてタスク化済み
