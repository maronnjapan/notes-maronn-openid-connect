# scope の正規化（重複除去）の一貫性 — Authorization Endpoint と Token Endpoint の非対称

## 1. このトピックで確認したいこと

`scope` は OAuth 2.0 / OIDC において **空白区切りの集合（set）** として扱う値である。
本リポジトリでは **Token Endpoint（refresh_token grant）では重複除去（dedup）しているのに、Authorization Endpoint では重複除去していない**という非対称が存在する。

このファイルでは次を確認する。

- `scope` を「集合」として正規化（重複除去・順序非依存）すべき仕様根拠
- Authorization Endpoint で重複が除去されず、そのまま発行物（access token の `scope` クレーム / token response の `scope` 値 / granted scope）へ伝播する現状
- この非対称が相互運用性・テスト容易性・リグレッション検知に与える影響
- 既存の `scope-handling-validation-and-granted-scope.md` との差分（本ファイルは「重複除去・正規化の一貫性」という固有論点のみを扱う）

> 関連既存ファイル（重複記載しない）:
> - `study-material/scope-handling-validation-and-granted-scope.md`: scope の検証・granted scope の決定ロジック全般を扱う。**重複除去の有無・エンドポイント間の一貫性には触れていない**。
> - `study-material/done/offline-access-scope-grant-policy.md`: `offline_access` の付与条件を扱う。
> 本ファイルは上記の隙間（**scope を集合として正規化する際のエンドポイント間の一貫性**）に絞る。

## 2. 関連する仕様・基準

- **RFC 6749 §3.3 (Access Token Scope)**: 「The value of the scope parameter is expressed as a list of **space-delimited, case-sensitive** strings.」scope は文字列の**リスト＝集合**であり、各スコープ値は一意のトークンを表す。順序に意味はない。
- **OAuth 2.1 draft §1.4.1 / §3.2.2.1**: scope の意味論は RFC 6749 を踏襲。scope は要求された権限の集合であり、重複した値は同一の権限を二重に表すだけで追加の意味を持たない。
- **OIDC Core 1.0 §3.1.2.1**: Authorization Request の `scope` は `openid` を含む空白区切り値。OIDC でも集合として扱う。
- **OIDC Core 1.0 §3.1.3.3 / RFC 6749 §5.1**: Token Response は付与された scope が要求と異なる場合 `scope` を返す（REQUIRED if different）。ここで返す scope 値も正規化された集合であることが、クライアント側の scope 比較を素直にする。
- **RFC 9700 (OAuth 2.0 Security BCP) §2 一般原則**: 入力の正規化を一貫させ、同じ意味の入力が経路によって異なる内部表現になる状況を避けることは、検証ロジックの単純化と脆弱性低減に資する（ここでは MUST ではなく設計健全性の観点）。

仕様上、重複した scope を**拒否せよ**とは明記されていない。したがって本トピックは「拒否」ではなく「**正規化（重複除去）してから付与・発行する**」一貫性の問題として扱う。

## 3. 参照資料

- RFC 6749 The OAuth 2.0 Authorization Framework — https://www.rfc-editor.org/rfc/rfc6749 （§3.3 scope の定義、§5.1 token response の scope）
- OAuth 2.1 Authorization Framework (draft-ietf-oauth-v2-1) — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （§3.2.2.1 token response、scope 意味論）
- OpenID Connect Core 1.0 — https://openid.net/specs/openid-connect-core-1_0.html （§3.1.2.1 Authorization Request、§3.1.3.3 Token Response）
- RFC 9700 Best Current Practice for OAuth 2.0 Security — https://www.rfc-editor.org/rfc/rfc9700 （入力検証・正規化の一般原則）

## 4. 現在の実装確認

### Authorization Endpoint（重複除去なし）

`packages/core/src/authorization-request.ts`

```ts
// 835 行目付近
const scopeValue = effective.scope ?? queryScopeValue;
const scope = scopeValue.split(' ').filter((s) => s.length > 0);  // ← dedup していない
if (!scope.includes('openid')) { ... }
```

- `split(' ').filter(...)` のみで、`new Set(...)` による重複除去を行っていない。
- ここで作られた `scope` 配列はそのまま検証・`offline_access` フィルタを経て、認可コードに保存される（同ファイル 923 行目 `scope,` で返却 → 認可コードに格納）。

### Token Endpoint（refresh_token grant では重複除去あり）

`packages/core/src/token-request.ts`

```ts
// 516 行目付近
const uniqueRequestedScopes = [...new Set(requestedScopes)];  // ← dedup している
```

- refresh_token grant の `scope` 縮小要求では `new Set` で重複除去している。
- 一方 authorization_code grant では `authCode.scope` をそのまま透過する（authz 側で正規化されていないため、重複はここでも残る）。

### 発行物への伝播

`packages/core/src/token-response.ts`

```ts
// 293 / 373 行目付近
scope: scope.join(' '),
```

- access token（JWT）の `scope` クレーム、および token response の `scope` 値は、配列を `join(' ')` してそのまま出力する。
- したがって Authorization Endpoint で `scope=openid openid profile` を送ると、`["openid","openid","profile"]` が認可コード→アクセストークン→token response の `scope` まで重複を保ったまま伝播する。

## 5. 現在の実装との差分

- **満たしていること**: scope 検証（`openid` 必須）・granted scope 決定・refresh 時の縮小検証・refresh 時の重複除去は実装済み。
- **不足している可能性があること（非対称）**:
  - Authorization Endpoint で `scope` の重複除去をしていない。同じ意味の入力（`openid profile` と `openid openid profile`）が異なる内部表現（要素数の違う配列）になる。
  - その結果、発行された access token の `scope` クレームと token response の `scope` 値に重複が残りうる。
  - Token Endpoint（refresh）は重複除去するため、**初回発行とリフレッシュ後で同一 grant の scope 表現が変わりうる**（例: 初回は `openid openid profile`、リフレッシュ後は `openid profile`）。
- **相互運用性の観点**: scope を集合として扱わず文字列一致で比較するリソースサーバ／クライアントは、重複や順序の違いで誤判定する可能性がある。正規化しておくとクライアント側の比較が素直になる。
- **テスト容易性 / リグレッション検知**: 発行物の `scope` を `toBe('openid profile')` のように一意値で固定するテストが書きにくくなる（重複の有無が入力依存になるため）。CLAUDE.md の「アサーションは合格値を一意に固定する」方針とも相性が悪い。
- **Basic OP 観点**: Basic OP 認定テストは重複 scope を直接検査しないため、認定可否のブロッカーではない。あくまで設計健全性・相互運用性の改善。

## 6. 改善・追加を検討する理由

- **一貫性**: 同じ「scope は集合」という前提を、Authorization Endpoint と Token Endpoint で揃えるべき。現状は片方だけ正規化している。
- **発行物の決定性**: アクセストークン／ID Token のクレーム、token response の `scope` 値を、入力の冗長性に依存しない決定的な表現にできる。
- **導入しやすさ**: 修正は局所的（authz 側で `[...new Set(...)]` を一行追加するだけ）で、既存の `offline_access` フィルタや `openid` チェックの前段に差し込める。Breaking change なし（重複を含むクライアントは稀で、除去しても権限は変わらない）。
- **拡張機能との接続**: 将来 incremental authorization（`study-material/ext-oauth-incremental-authorization.md`）や granted scope の永続化を入れる際、scope を正規化済み集合として保持しておくと差分計算が単純になる。
- **実装しない場合のリスク**: 発行物に重複 scope が混入し、scope を文字列比較するリソースサーバとの相互運用で稀な不具合を生む。エンドポイント間で scope 表現が揺れることでテストの固定値化が阻害される。

なお、これは MUST 違反ではないため「拒否」ではなく「正規化」を推奨する。重複を `invalid_scope` で拒否する選択肢もあるが、相互運用性を損なうため非推奨（下記方針 C）。

## 7. 実装方針の候補

- **方針 A（推奨: 正規化する）**: Authorization Endpoint で scope を `[...new Set(split)]` により重複除去する。順序は入力順を保持（`Set` は挿入順保持）。Token Endpoint と挙動が揃う。
- **方針 B（共通ヘルパに切り出す）**: `parseScope(value: string): string[]`（split → filter → dedup）を `core` に新設し、Authorization / Token / refresh の全経路で共有する。重複ロジックの一元化。最も保守的。
- **方針 C（拒否する）**: 重複を `invalid_scope` で拒否。相互運用性を損なうため非推奨。判断材料として記載するに留める。

最終的にどの方針を採るかは人間が判断する。

## 8. タスク案

- [ ] `parseScope` ヘルパ（split + filter + dedup、挿入順保持）を `packages/core/src` に新設するか、authz 側にインライン dedup を入れるかを決める（方針 A か B）。
- [ ] Authorization Endpoint の `scope` 構築箇所（`authorization-request.ts:835` 付近）で重複除去を適用する。
- [ ] token response / access token の `scope` が重複を含まないことを確認する回帰テストを追加（`scope=openid openid profile` 入力 → 発行物の `scope` が `'openid profile'`）。
- [ ] 初回発行 scope とリフレッシュ後 scope の表現が一致することのテストを追加。
- [ ] CLI テンプレート（`packages/cli`）が生成する OP の `conformance.test.ts` に影響しないか確認（発行物の scope 値を固定しているテストがあれば更新）。
