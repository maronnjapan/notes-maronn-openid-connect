# 拡張機能候補: Dynamic Client Registration（OIDC Registration 1.0 / RFC 7591）

## 1. タイトル

OpenID Connect Dynamic Client Registration 1.0 / RFC 7591 を拡張機能として導入する場合の検討。特に OIDF Conformance Suite 連携との関係を含む。

## 2. このトピックで確認したいこと

- DCR とは何か、Basic OP との関係（必須でないことの確認）
- Discovery が `registration_endpoint` を広告しているか（広告と実装の整合）
- DCR 非対応が Conformance Suite 実行（`tasks/basic-op-conformance-verification-plan.md`）に与える制約
- 拡張として導入する価値・接続容易性の判断材料

## 3. 関連する仕様・基準

- **OpenID Connect Dynamic Client Registration 1.0**: クライアントが `registration_endpoint` に JSON メタデータ（`redirect_uris`、`token_endpoint_auth_method`、`grant_types`、`response_types` 等）を POST し、`client_id`（および必要に応じ `client_secret`）の動的払い出しを受ける
- **RFC 7591 OAuth 2.0 Dynamic Client Registration Protocol**: 上記の OAuth 一般化。`software_statement` 等
- **OpenID Connect Discovery 1.0 §3**: `registration_endpoint`（DCR 対応時に広告）
- **Basic OP との関係**: DCR は **Basic OP の必須要件ではない**。Conformance プロファイルとしては `Dynamic OP` 系が DCR を要求する。Basic OP は静的登録クライアントで完結する
- **Conformance Suite との実務的関係**: OIDF Suite の多くのテストプランは、対象 OP がクライアントを **動的登録できる**ことを前提に組まれている。DCR 非対応 OP は「静的クライアント」設定のプランで実行する必要がある（→ 詳細は `tasks/basic-op-conformance-verification-plan.md`）。本ファイルはその制約の根本原因（DCR 非対応）側を扱う

## 4. 参照資料

- OpenID Connect Dynamic Client Registration 1.0 — https://openid.net/specs/openid-connect-registration-1_0.html （`registration_endpoint`、クライアントメタデータ）
- RFC 7591 OAuth 2.0 Dynamic Client Registration — https://www.rfc-editor.org/rfc/rfc7591
- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata （`registration_endpoint`）
- 本リポジトリ `tasks/basic-op-conformance-verification-plan.md`（DCR 非対応が検証実行に与える影響）
- 本リポジトリ `RELEASE-v0.x-scope.md`（拡張のスコープ判断の戦略前提）

## 5. 現在の実装確認

- `packages/core/src/discovery.ts`: `registrationEndpoint`（設定）→ `registration_endpoint`（出力）の機構は実装済み（行 35, 77, 185-186）。**ただし条件付き出力**（設定がある時のみ）
- `packages/sample/src/oidc-provider/routes/discovery.ts` および CLI テンプレート: `registrationEndpoint` を**設定していない** → `registration_endpoint` は**広告されない**
- DCR エンドポイント本体（`/register` 等のルート）は**存在しない**（routes に該当なし）
- 結論: 「広告していないし実装もしていない」= **整合は取れている（仕様非違反）**。`registration_endpoint` を広告しながら実装が無い、という不整合は**発生していない**（要確認だった点を確認済み）

## 6. 現在の実装との差分

満たしていること:

- DCR 非対応であることと Discovery の広告内容は整合（広告していないので不整合なし）。Basic OP 非違反

不足（拡張観点 / 検証運用観点）:

- 🔵（拡張）動的クライアント登録ができないため、クライアント増設は静的設定の編集が必要。多数クライアントでの検証や、Conformance Suite の動的登録前提プランが使えない
- 🟡（検証運用）Conformance Suite を回す際、静的クライアント設定での実行手順が別途必要（`basic-op-conformance-verification-plan.md` に依存タスクとして既出）。DCR があれば Suite 連携が大幅に簡素化する

## 7. 改善・追加を検討する理由

- なぜ価値があるか:
  - Conformance 検証の自動化容易化（Suite の動的登録プランが使える）。`RELEASE-v0.x-scope.md` の差別化軸「Fidelity（Conformance 準拠シグナル）」に効く
  - PoC で「複数アプリを素早く繋ぐ」体験（`RELEASE-v0.x-scope.md` の SSO 体験シナリオ／後続ロードマップ「複数サンプルアプリでの SSO 体験」）と相性が良い。アプリ追加のたびに静的設定編集が要る現状は体験摩擦
- Basic OP 必須か: **必須ではない（拡張 / Dynamic OP 系の領域）**
- 導入しやすさ: `discovery.ts` 側の広告機構は既存。エンドポイント本体は「メタデータ JSON 受領 → バリデーション → `client_id`/`client_secret` 生成 → クライアントストアへ保存」で、既存の KV ストア・client-auth・redirect_uri 検証ロジックを再利用できる。中規模
- 既存接続: クライアントストア、`client-auth.ts`、`authorization-request.ts` の redirect_uri 検証、`discovery.ts` メタデータ出力と接続
- 利用者メリット: アプリ追加が API 経由で完結。検証担当者の手作業削減。Conformance 連携の自動化
- 実装しない場合のリスク: Conformance Suite 連携が常に手動の静的設定運用になり、`Fidelity` シグナルの定期検証コストが高止まり。SSO 体験デモのスケールが鈍る。ただし `RELEASE-v0.x-scope.md` は v0.x で本格運用をスコープ外としており、v0.x 段階の損失は限定的

## 8. 実装方針の候補

`RELEASE-v0.x-scope.md`（先端・運用機能は v0.x 非対象、後続は 4軸スコアで判断）と整合させた判断材料:

- 方針A（凍結保存）: 現状維持。検証は静的クライアント設定で対応（`basic-op-conformance-verification-plan.md`）。最小コスト
- 方針B（最小 DCR）: 認証必須・固定発行ポリシーの最小限 DCR（`redirect_uris` と `token_endpoint_auth_method` のみ受理、その他は OP 既定）。Conformance 連携と複数アプリ体験の両方に効く。後続ロードマップ「複数サンプルアプリ SSO」とセットで評価
- 方針C（検証専用フラグ付き DCR）: 本番非対象を明示するため、開発/検証モードでのみ有効化できる DCR（既定無効）。`RELEASE-v0.x-scope.md` の「責務の境界（検証スコープ内 / 本番運用スコープ外）」と整合しやすい

DCR を後続ロードマップに載せるか（4軸スコア: 相談化しやすさ / 採用の近さ / 実装コスト / 移行接続性）、検証専用に留めるか、凍結保存かは人間が判断する。

## 9. タスク案

- [ ] 方針（A/B/C）を決定し、必要なら `RELEASE-v0.x-scope.md` 後続ロードマップへ「複数アプリ SSO」と束ねて追記提案
- [ ] （B/C 採用時）最小 DCR の受理メタデータ集合・認可ポリシー・既定値を設計し本ファイルに追補
- [ ] （B/C 採用時）TDD で DCR → client_id 発行 → 当該クライアントで Authorization Code Flow 成立、までのテストを先行作成
- [ ] `basic-op-conformance-verification-plan.md` の「静的設定での Suite 実行」依存と本タスクの関係を相互参照で明記
- [ ] `tasks/basic-op-requirement-traceability.md` 6.7 の「クライアント静的登録」行に方針決定結果を反映
