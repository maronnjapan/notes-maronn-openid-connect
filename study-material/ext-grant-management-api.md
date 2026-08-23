# 拡張: Grant Management for OAuth 2.0（OIDF Grant Management API）

## ステータス

🟢 拡張機能 / 検討段階（方針未決定）

## 1. このトピックで確認したいこと

OpenID Foundation（FAPI WG）の **Grant Management for OAuth 2.0** を導入するかを整理する。

本リポジトリはすでに「consent / grant の永続化と管理」を内部実装として持っている（`study-material/done/consent-grant-persistence-and-management.md` でタスク化・完了済み）。Grant Management API は、その **内部 grant を標準化された `grant_id` と専用エンドポイントで外部公開**するための仕様であり、既存資産の自然な発展形になりうる。

確認したいのは:

- 既存の consent/grant 永続化と Grant Management API の **境界**（内部実装 vs 標準 API）。
- 標準 `grant_id` / `grant_management_action` を導入する価値とコスト。
- Basic OP / 一般 PoC ユーザーにとっての有用性。

> 注意: consent/grant の永続化・再同意トリガ・失効など **内部ライフサイクルの設計は既存 done ファイルに記載済み**。本ファイルでは「標準 API として外部公開する差分」に絞り、内部設計の重複説明はしない。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイントのみ。

### Grant Management API の要点

- **認可リクエストの拡張パラメータ**:
  - `grant_management_action`: `create` / `update`（既存 grant に scope/claims を追加）/ `replace`（置換）。
  - `grant_id`: `update` / `replace` 時に対象 grant を指定。
  - サーバは認可コード/トークンレスポンスに **`grant_id`** を返す（クライアントが以後参照できる）。
- **Grant Management Endpoint**（新規エンドポイント）:
  - `GET {grant_management_endpoint}/{grant_id}`: その grant の現在の scope / claims / authorization_details を返す（query）。
  - `DELETE {grant_management_endpoint}/{grant_id}`: grant を失効（revoke）。失効時は紐づく access/refresh token も失効する。
  - アクセス制御は **専用 scope**（`grant_management_query` / `grant_management_revoke`）を持つ access token。
- **Discovery メタデータ**:
  - `grant_management_endpoint`: エンドポイント URL。
  - `grant_management_actions_supported`: 例 `["create","replace","update"]`。
  - `grant_management_action_required`: `create` を常に要求するか等のポリシー。
- **RAR との連携**: `authorization_details`（RFC 9396 / `ext-rich-authorization-requests-rfc9396.md`）を grant に束ねて管理するのが本来の主用途。RAR と組み合わせて初めて真価を発揮する。

### 既存実装・既存トピックとの関係（重複回避）

- **grant の内部ストア・ライフサイクル**: `study-material/done/consent-grant-persistence-and-management.md` ＋ `tasks/done/p0-consent-resolver.md` ＋ `tasks/p1-consent-persistence-prompt-none.md` で扱い済み。→ ここは再説明しない。
- **token 失効の cascade**: `tasks/done/p0-token-revocation-on-code-reuse.md` / `tasks/done/p1-token-revocation.md` の grant_id 連動失効を流用できる。
- **RAR**: `study-material/ext-rich-authorization-requests-rfc9396.md`。

→ Grant Management API は「既存の grant 永続化に **標準 ID と標準 CRUD エンドポイントの皮を被せる**」差分である、という整理。

## 3. 参照資料

- Grant Management for OAuth 2.0（OpenID Foundation, FAPI WG）: https://openid.net/specs/fapi-grant-management.html
  - 「Grant Management Actions」「Grant Management Endpoint」「Metadata」節
- RFC 9396 OAuth 2.0 Rich Authorization Requests（authorization_details）: https://www.rfc-editor.org/rfc/rfc9396
- RFC 7009 OAuth 2.0 Token Revocation（失効連動の参考）: https://www.rfc-editor.org/rfc/rfc7009

> 注: Grant Management 仕様は FAPI WG で更新されうる。着手前に最新版でパラメータ名・エンドポイント仕様を再確認すること（本ファイルは知識時点 2026-01 の整理）。

## 4. 現在の実装確認

- consent / grant の内部永続化は resolver（`ConsentResolver` 相当）で外部化されており、`prompt=consent` / `offline_access` と連動している（done ファイル参照）。
- token 失効は `packages/core/src/revocation.ts` が grant 単位の cascade（`revokeTokensByGrantId` 等）を持つ。
- ただし **標準 `grant_id` を認可/トークンレスポンスに返す経路は無い**。
- **Grant Management Endpoint（GET/DELETE）は未実装**。
- Discovery（`packages/core/src/discovery.ts`）に `grant_management_*` フィールドは無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP 要件ではない**: 未対応は仕様違反ではない。
- 🟢 **内部資産が既にある**: grant ライフサイクルと grant 単位失効は実装/設計済み。標準 API 化のための土台は揃っている。
- 🟡 **標準 `grant_id` の露出が無い**: 現状クライアントは grant を ID で参照・操作できない。
- 🟡 **専用 scope ベースのアクセス制御が必要**: Grant Management Endpoint を access token で保護する仕組み（`grant_management_query` / `grant_management_revoke` scope の検証）が新規。
- 🟡 **真価は RAR 前提**: RAR 未実装の段階では「scope/claims の grant 管理」だけになり、効果が限定的。
- 🟢 **ユーザー価値（透明性・GDPR 的な同意管理）**: エンドユーザーが「どのアプリに何を許可したか」を確認・撤回できる UX を標準 API で提供できる。

## 6. 改善・追加を検討する理由

価値:

- **同意の透明性と撤回**: ユーザーが付与済み grant を一覧・撤回できる標準 API は、プライバシー規制（GDPR / 各国個人情報保護）対応の PoC で需要がある。
- **既存資産の再利用効率が高い**: grant 永続化と cascade 失効が既にあるため、標準 API を被せるコストは比較的小さい。
- **RAR とセットで「きめ細かい権限管理」の検証層になる**: 「自分の権限モデルがこの仕様で表現できるか」を試す本リポジトリのコンセプトに合致。

Basic OP として必要か / 拡張か:

- **拡張（Tier C 相当）**。Basic OP 認証には不要。FAPI 系の高保証ユースケースで価値が出る。

導入しやすさ / しにくさ:

- 🟢 既存の grant resolver / cascade 失効を流用できる。
- 🟡 新規エンドポイント（GET/DELETE）と専用 scope の access token 検証が必要。
- 🟡 RAR 未実装だと効果が薄いため、RAR と前後関係を意識する必要がある。

既存実装との接続:

- 認可コード/トークン発行（`authorization-code.ts` / `token-response.ts`）に `grant_id` を払い出す経路を追加。
- Grant Management Endpoint は `revocation.ts` の cascade 失効を DELETE で呼ぶ薄いハンドラとして実装可能。
- access token 検証は `packages/core/src/access-token.ts` / `userinfo.ts` の scope チェックを流用。

実装しない場合のリスク / 制約:

- 標準 API でのユーザー主導の同意撤回は提供できない。内部失効 API（RFC 7009 revocation）はクライアント主導のため、ユーザー透明性ユースケースは未充足のまま。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x スコープ外」と記載し、RAR / FAPI 2.0 の後続として位置づけ。

### 方針B（最小: grant_id 露出 + DELETE 失効のみ）

- 認可/トークンレスポンスに `grant_id` を返す。
- Grant Management Endpoint は **DELETE（失効）のみ**実装し、既存 cascade 失効を呼ぶ。
- GET（照会）と `grant_management_action`（create/update/replace）は後続。
- 「ユーザーが grant を撤回できる」という最小価値を先に出す。

### 方針C（フルセット）

- `grant_management_action`（create/update/replace）対応、GET 照会、専用 scope、Discovery メタデータ全対応。
- RAR（`authorization_details`）と束ねて管理。

判断材料:

- RAR の実装可否で価値が大きく変わる。RAR を入れる予定があるなら方針 C をセット設計するのが効率的。
- 単独で透明性 UX だけ欲しいなら方針 B（grant_id + DELETE）で十分価値が出る。

## 8. タスク案

> RAR 連携の有無で設計が変わるため、**まずは方針判断待ち（検討段階）**。RAR と独立して「grant_id + DELETE 失効」だけなら小さく切り出せる。

- [ ] 人間が方針 A / B / C を選択する（特に RAR を入れるかを先に決める）
- [ ] 方針 B 採用時（RAR 非依存で着手可能な最小スコープ）:
  - [ ] 認可コード/トークン発行に標準 `grant_id` を払い出し、トークンレスポンスへ含める
  - [ ] `grant_management_revoke` scope を持つ access token で `DELETE /grants/{grant_id}` を受ける薄いハンドラを追加（`revocation.ts` の cascade を再利用）
  - [ ] Discovery に `grant_management_endpoint` / `grant_management_actions_supported` を追加し honesty を担保
  - [ ] テスト: grant_id 払い出し、DELETE で grant と紐づく token が失効、scope 不足は `insufficient_scope`
- [ ] 方針 C 採用時: 上記 + GET 照会、`grant_management_action`（create/update/replace）、RAR（`authorization_details`）連携
