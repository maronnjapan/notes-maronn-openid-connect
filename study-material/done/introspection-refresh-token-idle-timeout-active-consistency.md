# Introspection がアイドルタイムアウト済み Refresh Token を `active: true` と報告する（Token Endpoint との不整合）

## 1. タイトル

Token Endpoint は `refreshTokenIdleTimeoutSeconds`（無操作タイムアウト）を超えた Refresh Token を `invalid_grant` で拒否するのに、`handleIntrospectionRequest` は同じトークンを `active: true` と報告する。`isRefreshTokenActive` が `used` と `expiresAt` しか見ず、Introspection 側にアイドルタイムアウトの入力が無いため、OP 自身の無操作失効ポリシーが Introspection から不可視になっている問題。

## 2. このトピックで確認したいこと

- Token Endpoint の Refresh 経路はアイドルタイムアウトで RT を失効扱いにするのに、Introspection の `active` 判定はアイドルを考慮せず、同一トークンについて 2 エンドポイントで**矛盾した有効性**を返す
- RFC 7662 の `active` は「現時点で使用可能（有効期限切れ・失効・不正でない）」を意味する。Token Endpoint が使用不可と判断するトークンを `active: true` と返すのは、この定義と整合しない
- 併せて、`buildRefreshTokenResponse` が保存済み `audience` を `aud` として返さない（access token 応答は返す）非対称も、Introspection 応答の忠実性として確認対象に含める

## 3. 関連する仕様・基準

共通の Introspection 形状・Refresh アイドルタイムアウト自体の説明は重複させない。既存の確定事項:

- Refresh Token のアイドル（無操作）タイムアウトの**存在と Token Endpoint での失効**: `study-material/done/refresh-token-idle-inactivity-timeout.md` / `tasks/done/p3-refresh-token-idle-inactivity-timeout.md`
- Introspection のレスポンス形状・`token_type: refresh_token` 値: `tasks/done/p1-token-introspection.md` / `study-material/introspection-refresh-token-type-value-rfc7662.md`
- `active:false` 時の最小開示・呼び出し元認可: `study-material/introspection-caller-authorization-and-disclosure.md`

本トピック固有の差分（`active` 判定のクロスエンドポイント一貫性）に関する根拠:

- **RFC 7662 §2.2（Introspection Response）**: `active` は "whether or not the presented token is currently active" を示し、有効期限切れ・失効・その他の理由で無効なら `false`。無操作タイムアウトで OP が使用不可とみなすトークンは、この "invalid for other reasons" に該当すると解釈するのが自然
- **RFC 9700（OAuth 2.0 Security BCP）§4.14.2**: Refresh Token のローテーション/無効化ポリシー。無操作失効を採るなら、その状態が観測系（Introspection）でも一貫することが望ましい
- **RFC 7662 §2.2**: `aud` は OPTIONAL なレスポンスメンバ。省略自体は準拠だが、access token 応答と揃えるかは忠実性の判断対象

留保:

- アイドルタイムアウトは**オプトイン**の設定（`refreshTokenIdleTimeoutSeconds` 未設定なら無効）。したがって本件は「設定を有効化した OP でのみ顕在化する」不整合
- Introspection（RFC 7662）は Basic OP 認定の必須エンドポイントではない（拡張）。本件は認定ブロッカーではなく、Fidelity/セキュリティ観測性の改善
- `aud` 省略は「Refresh Token の audience は概念的に AS であってリソースサーバではない」という設計判断による可能性があり、その場合は「意図的省略を明文化」で解決しうる（要方針判断）

## 4. 参照資料

- RFC 7662 OAuth 2.0 Token Introspection §2.2 — https://www.rfc-editor.org/rfc/rfc7662#section-2.2
- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 — https://www.rfc-editor.org/rfc/rfc9700.html
- 本リポジトリ内: `study-material/done/refresh-token-idle-inactivity-timeout.md`（アイドルタイムアウトの Token Endpoint 実装。本ファイルは Introspection 一貫性の差分）

## 5. 現在の実装確認

- `packages/core/src/introspection.ts:103-107`（`isRefreshTokenActive`）: `if (info.used) return false; if (info.expiresAt <= now) return false; return true;` — アイドルタイムアウトの検査なし
- `packages/core/src/introspection.ts:64-70`（`IntrospectionRequestContext`）: `params` / `authenticatedClientId` / 各 resolver のみ。アイドルタイムアウト秒やトークンの最終使用時刻を受け取るフィールドが無い
- `packages/core/src/refresh-token-grant.ts:86-97`: Token Endpoint 側はアイドルタイムアウト超過を検出して `invalid_grant`（"expired due to inactivity" 相当）で拒否
- `packages/core/src/token-request.ts:277-285`: Token 経路がアイドルタイムアウトの設定軸を受け取る（Introspection にはこの軸が無い）
- `packages/core/src/introspection.ts:129-141`（`buildRefreshTokenResponse`）: `scope` / `client_id` / `token_type` / `sub` / `exp` / `iat` / `iss` は返すが `aud` を返さない。対して `buildAccessTokenResponse`（:121-123）は `info.audience` を `aud` として返す
- `packages/core/src/introspection.test.ts`: idle/inactivity の検証は無い（`grep` でヒットせず）

## 6. 現在の実装との差分

満たしていること:

- Introspection は `used` / `expiresAt`（および access token の `nbf`）で `active` を正しく判定
- Token Endpoint のアイドルタイムアウト失効は実装・テスト済み

実装はあるが仕様上の確認が必要なこと / セキュリティ観測性:

- 🟡 **クロスエンドポイント不整合**: アイドルタイムアウトを有効化した OP で、無操作失効した RT が Token Endpoint では拒否・Introspection では `active: true`。リソースサーバや監視が Introspection を信頼すると「まだ有効」と誤認する
- 🟡 **`aud` 省略の非対称**: `RefreshTokenInfo.audience` は保存されているのに Introspection の RT 応答で返さない。access token 応答との一貫性・忠実性の観点で、返すか「意図的省略」を明文化するかを決める余地

## 7. 改善・追加を検討する理由

- **Fidelity / 観測性**: 本リポジトリは Conformance 準拠を信頼シグナルに掲げる。同一トークンで有効性判定が割れるのは、忠実性の観点で望ましくない。Introspection を運用監視やリソースサーバ判定に使う利用者にとって、この不整合はデバッグを難しくする
- **セキュリティ**: 無操作失効はセッションハイジャック後の RT 悪用を絞るための設定。その失効が Introspection に反映されないと、失効済みトークンを「有効」と見せてしまい、失効ポリシーの実効性が観測面で崩れる
- **導入接続性**: `IntrospectionRequestContext` にアイドルタイムアウト秒（＋トークンの最終使用時刻 `lastUsedAt` 等）を渡し、`isRefreshTokenActive` に Token 経路と同じ判定を追加すれば局所導入できる。Token/Introspection でアイドル判定ロジックを共有関数に切り出せば二重管理も避けられる
- **実装しない場合のリスク**: 「無操作タイムアウト対応」を謳う設定が Introspection では効かず、観測系が失効を見落とす。`aud` 非対称は軽微だが、忠実性の穴として残る

## 8. 実装方針の候補

- 方針A（判定ロジック共有）: Token 経路と Introspection が共通の `isRefreshTokenUsable(info, now, idleTimeout, lastUsedAt)` を使う。`IntrospectionRequestContext` にアイドルタイムアウト秒と最終使用時刻の供給口を追加。整合が根本から保証されるが型/契約の変更が要る
- 方針B（Introspection にアイドル入力を追加）: `IntrospectionRequestContext` にアイドルタイムアウト秒を追加し、`isRefreshTokenActive` にだけ判定を足す（ロジック共有まではしない）。差分小だが二重管理リスク
- 方針C（現状維持 + 文書化）: アイドル失効は Token Endpoint の責務と割り切り、Introspection は保存状態（used/exp）のみを反映すると明文化。RT の最終使用時刻を持たない実装なら現実的。ただし観測不整合は残置
- `aud` について: 方針X（access と揃えて `aud` を返す）／ 方針Y（RT の audience は AS であり返さない旨をコメント/README に明文化）のいずれか

判定ロジックを共有するか、`RefreshTokenInfo`/context に最終使用時刻・アイドル秒を持たせるか、`aud` を返すか明文化するかは人間が決定する。アイドルタイムアウトを持たない構成では本件は非顕在なので、v0.x 範囲かは `RELEASE-v0.x-scope.md` に照らして判断。

## 9. タスク案

- [ ] Introspection のアイドル反映方針（A/B/C）と `aud` 方針（X/Y）を決定
- [ ] （TDD）`introspection.test.ts` に「アイドルタイムアウト超過の RT → `active:false`」「タイムアウト未超過 → `active:true`」の負/正テストを先に追加
- [ ] （方針A/B）`IntrospectionRequestContext` にアイドルタイムアウト秒（および必要なら最終使用時刻の供給口）を追加し、`isRefreshTokenActive` に判定を実装
- [ ] （方針A）Token 経路と共有する `isRefreshTokenUsable` 相当を切り出し、両者から利用
- [ ] （方針X 採用時）`buildRefreshTokenResponse` に `aud` を追加、または（方針Y）意図的省略のコメントを追記
- [ ] CLI テンプレートの introspection ルートがアイドルタイムアウト設定を core に渡すよう配線（sample が該当設定を持つ場合）
- [ ] 挙動変更が `conformance.test.ts` の想定に関わる場合、生成コード側を更新
