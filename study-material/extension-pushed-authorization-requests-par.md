# 拡張機能候補: Pushed Authorization Requests (PAR, RFC 9126)

## 1. タイトル

OAuth 2.0 Pushed Authorization Requests（RFC 9126）を拡張機能として導入する場合の検討。

## 2. このトピックで確認したいこと

- PAR とは何か、Basic OP との関係（必須か拡張か）
- 本リポジトリの現構成（Authorization Code Flow + 厳密一致 redirect_uri + Discovery 機構）に PAR がどの程度載せやすいか
- `RELEASE-v0.x-scope.md` が先端仕様（PAR / DPoP 等）を **v0.x 非対象・後続ロードマップの駆動力にもしない**と明言している点と整合させ、本ファイルは「拡張候補の判断材料の凍結保存」に限定する（v0.x 実装提案ではない）

## 3. 関連する仕様・基準

DPoP（RFC 9449）は別トピック（📌 `tasks/T-019-dpop.md`）。本ファイルは PAR 固有の差分のみ。

- **RFC 9126 OAuth 2.0 Pushed Authorization Requests**:
  - クライアントが認可リクエストパラメータを **バックチャネルで Token Endpoint 類似の PAR Endpoint（`pushed_authorization_request_endpoint`）へ POST** し、`request_uri`（短命・OP 発行）を受け取る
  - クライアントは認可エンドポイントへ `client_id` と当該 `request_uri` のみで遷移
  - 効果: 認可リクエストの**完全性・機密性**（フロントチャネル改ざん防止、長大パラメータ回避、リクエスト固定化攻撃の緩和）
  - Discovery: `pushed_authorization_request_endpoint`、`require_pushed_authorization_requests`（boolean）
- **OIDC Core §6 の `request_uri` との関係**: PAR の `request_uri` は OP 自身が発行するため、§6 の汎用 `request_uri`（外部参照）非対応方針（📌 `tasks/request-object-rejection-and-discovery-honesty.md`）とは別物。PAR を入れる場合、認可エンドポイントは「OP 発行の PAR `request_uri`」だけを受理し、それ以外の `request_uri` は従来通り拒否、という分離設計が必要
- **Basic OP との関係**: PAR は Basic OP 認定の**対象外**（必須でも Conformance Basic プランの送信対象でもない）。純粋な**セキュリティ拡張**

## 4. 参照資料

- RFC 9126 OAuth 2.0 Pushed Authorization Requests — https://www.rfc-editor.org/rfc/rfc9126 （PAR Endpoint、`request_uri` 発行、Discovery メタデータ `pushed_authorization_request_endpoint` / `require_pushed_authorization_requests`）
- OAuth 2.0 Security Best Current Practice（RFC 9700）— https://www.rfc-editor.org/rfc/rfc9700.html （フロントチャネル改ざん対策を含む OAuth セキュリティ勧告）
- 本リポジトリ `RELEASE-v0.x-scope.md` — 先端仕様を v0.x 非対象とする戦略決定（本ファイルの位置づけの根拠）

## 5. 現在の実装確認

- PAR Endpoint / `pushed_authorization_request_endpoint` は**未実装・未広告**（routes に該当なし、`discovery.ts` に該当メタデータ無し）
- 認可リクエストはフロントチャネルの URL クエリ（および POST、`done/p0-authorization-endpoint-post.md`）から `authorization-request.ts` が直接パース
- redirect_uri 厳密一致（`done/p0-redirect-uri-fragment-rejection.md`）、PKCE 必須（OAuth 2.1）は実装済み — PAR が無くてもフロントチャネル攻撃面はある程度抑えられている

## 6. 現在の実装との差分

満たしていること:

- PKCE 必須・redirect_uri 厳密一致により、PAR 不在でも基本的なリクエスト改ざん／インジェクションの一部は緩和済み

不足（拡張観点）:

- 🔵（拡張）認可リクエストパラメータの**完全性保証**（フロントチャネル非経由）は無い。長大 `claims` / 多数パラメータのフロント露出、リクエスト固定化系の攻撃面が残る
- 🔵（拡張）`require_pushed_authorization_requests` による「PAR 必須クライアント」運用ができない

これらは Basic OP 非違反（PAR は任意）。あくまで将来のセキュリティ強化余地。

## 7. 改善・追加を検討する理由

- なぜ価値があるか: PAR は FAPI 2.0 等のセキュアプロファイルの土台。「最新仕様を忠実に検証できる」というブランド軸（Speed/Fidelity）に対し、PAR は将来の高セキュリティ要件 PoC で需要が見込まれる
- Basic OP 必須かどうか: **必須ではない（拡張）**
- 導入しやすさ: PAR Endpoint は「Token Endpoint と同等のクライアント認証 + パラメータ受領 → 短命 `request_uri` をストアに保存」という構造で、既存の client-auth・KV ストア・authorization-request バリデーションを**再利用**できる。認可エンドポイント側は「`request_uri` を引いて保存済みパラメータに復元してから既存 `validateAuthorizationRequest` に流す」分岐追加で済む。比較的載せやすい
- 既存接続: `client-auth.ts`（PAR はクライアント認証を要求しうる）、KV ストア（短命 `request_uri` の保存）、`authorization-request.ts`（復元後の検証）、`discovery.ts`（メタデータ出力機構あり）と自然に接続
- 利用者メリット: セキュアプロファイル検証の入口を提供。運用者は `require_pushed_authorization_requests` でフロントチャネル露出を排除できる
- 実装しない場合: 高セキュリティ PoC（金融・ヘルスケア等）の検証ニーズに応えられない。ただし `RELEASE-v0.x-scope.md` の初期 SME セグメントはこのニーズを持たないと明言済み = v0.x の機会損失は小さい

## 8. 実装方針の候補

`RELEASE-v0.x-scope.md` 準拠で「v0.x 非対象、後続ロードマップでも単独の駆動力にしない」前提。判断材料として方針を整理:

- 方針A（凍結保存のみ・推奨デフォルト）: 本ファイルを判断材料として保存し、実装は将来のセキュアプロファイル（FAPI 等）着手時に再評価。今は何もしない
- 方針B（後続ロードマップ末尾に候補追加）: `RELEASE-v0.x-scope.md` の後続ロードマップに「セキュアプロファイル基盤（PAR）」を 4軸スコア評価対象として列挙（実装確約ではない）
- 方針C（先行 Tier A の任意1本候補）: `RELEASE-v0.x-scope.md` D 項「（任意・ブロッカーにしない）拡張仕様を1本だけ先行 Tier A」の候補として PAR を提示。ただし DPoP（📌 `T-019-dpop.md`）と競合するため二者択一の判断材料に留める

最終的に PAR を後続ロードマップ/先行 Tier A 候補に載せるか、凍結保存に留めるかは事業判断含め人間が決定する。

## 9. タスク案

- [ ] 方針（A/B/C）を決定（`RELEASE-v0.x-scope.md` の戦略と整合させる）
- [ ] （B/C 採用時）後続ロードマップ or D 項候補へ PAR を追記し、DPoP との優先度を 4軸スコアで比較
- [ ] （将来実装時）PAR Endpoint の設計詳細（client 認証要否、`request_uri` 形式・TTL、`require_pushed_authorization_requests` の扱い、§6 汎用 request_uri 拒否との分離）を本ファイルに追補
- [ ] （将来実装時）TDD で PAR → 短命 request_uri 発行 → 認可エンドポイントでの復元・検証フローのテストを先行作成
- [ ] `tasks/basic-op-requirement-traceability.md` には「PAR は Basic OP 対象外（拡張）」と注記済みであることを確認
