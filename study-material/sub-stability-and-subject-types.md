# `sub` クレームの安定性と subject_types の整合性

## 1. タイトル

ID Token / UserInfo の `sub`（Subject Identifier）が OIDC Core の安定性要件を満たすことの担保と、Discovery が広告する `subject_types_supported` の挙動整合。

## 2. このトピックで確認したいこと

- `sub` が「特定の End-User に対して、当該 Issuer 内で安定・局所一意・再割当てされない」値であることを、本ライブラリがどこまで保証 or 文書化しているか
- Discovery で `subject_types_supported: ['public']` を広告しているが、実装が実際に Public Subject Identifier の挙動（同一 End-User には全クライアントで同一 `sub`）を満たすか／その責務が誰にあるか
- Basic OP として「確認すべき」事項であり、未追跡（既存タスクに該当なし）

## 3. 関連する仕様・基準

共通の仕様セクション索引は `tasks/basic-op-requirement-traceability.md` の「3.3」を参照。本トピック固有の差分:

- **OIDC Core 1.0 §2（ID Token / sub 定義）**: `sub` は「Issuer 内で End-User に対し locally unique かつ never reassigned」であることが REQUIRED。最長255 ASCII 文字。クライアントは `sub` を End-User の識別子として依拠する
- **OIDC Core 1.0 §8（Subject Identifier Types）**:
  - `public`: 全 RP に対して同一の `sub` を返す
  - `pairwise`: RP（sector）ごとに異なる `sub` を返す（相関防止）
  - OP は `subject_types_supported`（Discovery, OIDC Discovery 1.0 §3）で対応タイプを広告する。広告した挙動と実挙動が一致している必要がある
- **OIDC Core 1.0 §5.3.2 / §3.1.3.7**: UserInfo の `sub` は ID Token の `sub` と一致しなければならない（RP 側の検証責務だが、OP は同一値を返す前提）

## 4. 参照資料

- OpenID Connect Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （sub の安定性要件: "locally unique and never reassigned"）
- OpenID Connect Core 1.0 §8 — https://openid.net/specs/openid-connect-core-1_0.html#SubjectIDTypes （public / pairwise の定義）
- OpenID Connect Core 1.0 §5.3.2 — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoResponse （UserInfo の sub 一致）
- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata （`subject_types_supported`）

## 5. 現在の実装確認

- `sub` の供給元: `packages/core/src/token-response.ts` は `subject` を引数で受け取り、`idTokenPayload.sub = subject`（行付近 261）および UserInfo 連携（`userId: subject`）にそのまま使用。`sub` 値の生成・安定性ロジックは core に無く、**呼び出し側（アプリ／resolver）が渡す値に完全依存**
- `id-token.ts`: `sub` の存在・255文字以内・ASCII の構造検証はあるが、「安定性」「再割当て不可」「pairwise 派生」は検証範囲外（仕様上も実行時検証は不能）
- Discovery: `packages/core/src/discovery.ts` は `subjectTypesSupported` を必須化（空配列を拒否）し出力。sample / CLI テンプレートは `subjectTypesSupported: ['public']` を静的設定
- pairwise 派生（sector_identifier_uri ベースの `sub` 変換）ロジックは存在しない

## 6. 現在の実装との差分

満たしていること:

- `sub` の構造的バリデーション（必須・255 ASCII）は実装済み
- `subject_types_supported` の出力と空配列拒否は実装済み
- UserInfo の `sub` は AT に紐づく subject をそのまま返すため、ID Token と同一値になる設計（RP 側一致検証の前提を満たす）

不足・確認が必要なこと:

- 🟡 **安定性の責務が暗黙**: `sub` の「安定・再割当て不可」は resolver/アプリ責務だが、その契約がドキュメント／型／コメントで明示されていない。OSS 利用者が「メールアドレスや連番 PK をそのまま `sub` に流用 → 再割当て発生」という典型的アンチパターンを踏みやすい
- 🟡 **`public` 広告の裏付けが弱い**: `subject_types_supported: ['public']` を広告しているが、「同一 End-User には全クライアントで同一 `sub`」という public の意味が満たされるかは resolver 実装次第。広告値と実挙動の整合確認ポイントが無い
- 🔴（拡張観点）**pairwise 未対応**: §8 の pairwise は Basic OP 必須ではないが、相関防止が要件になる PoC では不足。広告していないため非整合ではない（=現状は仕様違反ではない）が、拡張余地として記録

## 7. 改善・追加を検討する理由

- Basic OP / OIDC Core の中核は「クライアントが `sub` を恒久 ID として依拠できる」前提に立つ。ここが崩れると ID Token / UserInfo の信頼性全体が崩れる（セキュリティ・相互運用性の根幹）
- 本ライブラリは「仕様検証ブリッジ」であり、利用者は resolver を自前実装する。`sub` 契約が不明示だと、検証目的のはずが誤った `sub` 設計のまま本番 IdaaS 移行 → 移行先で ID マッピング破綻、というファネル上の事故につながる
- 導入しやすさ: 実装変更は小さく、主に「契約の明示（型コメント / ドキュメント / 任意の安全側ヘルパー）」で達成できる。core に重い判定ロジックを持たせない方針（既存の resolver 注入思想、`done/T-015-acr-amr-resolver.md` と同じ哲学）と整合
- 実装しない場合のリスク: 仕様準拠を謳いながら `sub` 安定性は無保証、という曖昧さが残る。Conformance では `sub` 安定性を前提にしたシナリオで顕在化しうる

## 8. 実装方針の候補

- 方針A（最小・ドキュメント中心）: resolver / `subject` 引数の型コメントと CLI 生成コードのコメントに「`sub` MUST be stable, locally unique, never reassigned（OIDC Core §2）。メール等の可変値や再利用される PK を使わない」と明記
- 方針B（軽量ガード追加）: 開発時に明らかなアンチパターン（`sub` に `@` を含む＝メール流用の疑い、空文字、極端に短い等）を **warning ログ**で警告するオプション（エラーにはしない＝仕様を曲げない）
- 方針C（拡張）: pairwise Subject Identifier を resolver オプションとして将来追加（`sector_identifier_uri` ベース）。Basic OP 必須ではないため後続ロードマップ／`RELEASE-v0.x-scope.md` の後続項目候補として扱う
- 方針D（Discovery 整合）: `subject_types_supported` を「実装が保証できる範囲」と一致させるため、設定値とドキュメントの対応関係をテストで固定

最終的にどの方針を採るか（特に B のヒューリスティック警告を入れるか、C をロードマップに載せるか）は人間が判断する。

## 9. タスク案

- [ ] `subject` 引数 / resolver の型に `sub` 安定性契約（OIDC Core §2 引用）を JSDoc で付与
- [ ] CLI 生成テンプレートの resolver スタブに同契約コメントを生成
- [ ] `sub` 安定性の利用者向け説明を README/ドキュメント入口に追記（`RELEASE-v0.x-scope.md` の「責務の境界」節と接続）
- [ ] （方針B採用時）開発モード限定の `sub` アンチパターン警告ロガーを追加し、エラーにしないことをテストで保証
- [ ] （方針C採用時）pairwise を後続ロードマップ項目として `RELEASE-v0.x-scope.md` の後続リストに追記提案
- [ ] `subject_types_supported` 設定値と実挙動契約の対応をテストで固定
