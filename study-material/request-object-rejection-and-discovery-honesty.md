# Request Object（`request` / `request_uri`）非対応の明示的拒否と Discovery 整合

## 1. タイトル

OIDC Core §6 の Request Object（`request` / `request_uri` パラメータ）を非対応とする本実装が、受領時に仕様準拠のエラーを返し、かつ Discovery で非対応を正しく広告すること。

## 2. このトピックで確認したいこと

- `request` / `request_uri` が認可リクエストに含まれたとき、現状は**黙って無視**される。OIDC Core §6 は非対応 OP に `request_not_supported` / `request_uri_not_supported` の返却を求めており、この差分を確認する
- Discovery が `request_parameter_supported` / `request_uri_parameter_supported` を出力しておらず、クライアントが事前に非対応を判別できない点を確認する
- 本論点は `tasks/done/oidc-improvements-2026-05.md` の **T-018** に分析記録があるが、当該ファイルは done/ 配下の参照文書であり T-018 自体は**未実装**。独立した OPEN トピックとして判断材料を集約する（重複説明はせず差分のみ）

## 3. 関連する仕様・基準

共通の仕様索引は `tasks/basic-op-requirement-traceability.md`「3.3」を参照。本トピック固有の要点（T-018 の分析を要約・補正）:

- **OIDC Core 1.0 §6.1 / §6.2**: `request`（Request Object 値を直接渡す JWT）と `request_uri`（参照 URL）。OP が当該機能をサポートしない場合:
  - `request` 受領時: `request_not_supported` エラー
  - `request_uri` 受領時: `request_uri_not_supported` エラー
  - これらは認可エラーとして（state を伴い）redirect_uri へ返すべきエラーに分類される（OIDC Core §3.1.2.6 のエラー応答経路）
- **OpenID Connect Discovery 1.0 §3**: `request_parameter_supported` / `request_uri_parameter_supported` は省略時の既定値が `false`。ただし「明示的に `false` を出す」ことでクライアントは事前に挙動を確定できる（相互運用性向上）
- **Basic OP 認定との関係**: Request Object 関連は Basic OP の必須テスト対象**ではない**（Conformance の Basic プランは送らない）。したがってこれは「認定ブロッカー」ではなく **仕様 Fidelity / 相互運用性 / 予測可能性**の論点

## 4. 参照資料

- OpenID Connect Core 1.0 §6 — https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests （`request` / `request_uri`、非対応時のエラー `request_not_supported` / `request_uri_not_supported`）
- OpenID Connect Core 1.0 §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthError （認可エラー応答経路）
- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata （`request_parameter_supported` / `request_uri_parameter_supported` の既定値 false）
- 本リポジトリ内分析: `tasks/done/oidc-improvements-2026-05.md` の T-018（背景分析。実装は未着手）

## 5. 現在の実装確認

- `packages/core/src/authorization-request.ts`: `request` / `request_uri` を一切参照していない（grep で該当なし）。= 認可リクエストに含まれても抽出も拒否もされず**黙殺**
- `packages/core/src/discovery.ts`: `requestParameterSupported` / `requestUriParameterSupported` の設定プロパティと出力分岐は実装済み（行 50, 87, 88, 216-220）
- ただし `packages/sample/src/oidc-provider/routes/discovery.ts` および CLI テンプレートはこれらを**設定していない**ため、Discovery 応答に `request_parameter_supported` / `request_uri_parameter_supported` が**出力されない**（grep で sample/CLI に該当設定なし）

## 6. 現在の実装との差分

満たしていること:

- core の Discovery には非対応広告のための出力機構が既に存在（接続するだけで広告可能）

不足・確認が必要なこと:

- 🔴 **非対応エラー未返却**: `request` / `request_uri` を受けても `request_not_supported` / `request_uri_not_supported` を返さない。OIDC Core §6 非準拠（Basic OP 必須ではないが Fidelity 軸に反する）
- 🟡 **Discovery が暗黙の既定値依存**: 出力機構はあるが sample/CLI が未配線のため、応答に明示が出ない。仕様上「省略時 false」なので非違反だが、明示した方がクライアントの予測可能性が高い（相互運用性）
- 🟡 **無視 vs 拒否の方針未確定**: Request Object を将来サポートする可能性があるなら「今は拒否、将来対応」、サポートしない方針なら「恒久的に拒否 + 明示広告」。方針が未記録

## 7. 改善・追加を検討する理由

- 「最新の OIDC/OAuth 仕様を忠実に」を掲げる本 OSS にとって、§6 の MUST 級エラー挙動の欠落は Fidelity シグナルの毀損になる
- セキュリティ観点: `request_uri` を黙殺すると、攻撃者が `request_uri` に外部 URL を仕込んだリクエストを送っても OP が**それを無視して通常パラメータで処理**するため、クライアント／利用者が「Request Object が効いている」と誤認するリスク（パラメータ汚染の混乱）。明示拒否はこの曖昧さを排除する
- 導入容易性: Discovery 側は既存機構の配線のみ。Authorization 側も「パラメータ検知 → 既存エラー応答経路（redirect with error）に流す」だけで、redirect_uri/client_id 検証済みの段階に1分岐追加する程度。`done/p1-authorization-error-description-redirect.md`（エラー redirect 経路）と接続できる
- 実装しない場合のリスク: 仕様非準拠の黙殺が残り、PoC 利用者が「Request Object が使えるかどうか」を試した際に誤った成功体験（実際は無視されているだけ）を得る

## 8. 実装方針の候補

- 方針A（恒久非対応 + 明示拒否, 推奨検討筆頭）:
  - `validateAuthorizationRequest` で `request` 検知 → `request_not_supported`、`request_uri` 検知 → `request_uri_not_supported` を、redirect_uri/client_id 検証通過後に state 付きで返す
  - sample/CLI の Discovery 設定に `requestParameterSupported: false` / `requestUriParameterSupported: false` を配線
- 方針B（Discovery 明示のみ先行）: 拒否は将来とし、まず Discovery で `false` を明示（最小・低リスク）。ただし黙殺の曖昧さは残る
- 方針C（将来 PAR/Request Object 対応を見据える）: `RELEASE-v0.x-scope.md` は先端仕様（PAR 等）を v0.x 非対象としている。Request Object 対応は後続。当面は方針A で「今は明示的に非対応」を確定させ、後続で解禁

`RELEASE-v0.x-scope.md` の「先端仕様は v0.x 非対象」方針と矛盾しない（本タスクは"対応"ではなく"非対応の明示"であり、むしろスコープ境界を明確化する）。最終方針は人間が判断。

## 9. タスク案

- [ ] 方針（A/B/C）を決定
- [ ] （A 採用時）`authorization-request.test.ts`: `request` 付与 → `request_not_supported`、`request_uri` 付与 → `request_uri_not_supported` のテストを先に追加（TDD）
- [ ] （A 採用時）`authorization-request.ts` に検知・エラー化を実装し、エラー redirect 経路に接続
- [ ] sample / CLI テンプレートの Discovery 設定に `requestParameterSupported: false` / `requestUriParameterSupported: false` を配線
- [ ] `discovery.test.ts`: 両フィールドが `false` で出力されることを検証
- [ ] `tasks/basic-op-requirement-traceability.md` の該当行（6.5 Request Object）の状態を更新
- [ ] 対応完了後、`tasks/done/oidc-improvements-2026-05.md` の T-018 を解決済みとして相互参照
