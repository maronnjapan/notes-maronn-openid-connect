# ID Token の `aud`（スカラー空文字列）を拒否できていない非対称ガード

## 1. タイトル

ID Token 発行経路 (`validatePayload`) の `aud` バリデーションが、配列メンバーの空文字列は拒否する一方で、**単一値（スカラー）の `aud: ""`（空文字列）を素通りさせている**非対称性の是正。

## 2. このトピックで確認したいこと

- `validatePayload` は `aud` に対して「欠損」「空配列」「配列メンバーの空文字列 / 非文字列」を拒否している。しかし `aud` が**単一のスカラー空文字列 `""`**（配列でない）の場合、どのチェックにも掛からず、構造的に不正な ID Token をそのまま発行できてしまう。
- 本ライブラリはあえて配列パスでは `RFC 7519 §4.1.3`（`aud` = StringOrURI）に基づく厳格検証を入れている。にもかかわらず、より一般的な「単一 audience」ケースだけがザルになっているのは、意図した防御が片側に効いていない**実装の穴**である。
- これは既存の `study-material/done/sub-ascii-charset-enforcement.md`（`sub` の文字種検証）や `study-material/request-object-scalar-value-type-handling.md`（スカラー値の型ハンドリング）と同系統の「発行値の構造健全性」論点だが、**対象クレームが `aud` である点で別トピック**であることを確認したい。

## 3. 関連する仕様・基準

共通の ID Token / `aud` の一般説明は繰り返さない。本トピック固有の根拠に絞る。

- **RFC 7519 §4.1.3 (`aud`)**: `aud` は `StringOrURI` 値、またはその配列。`StringOrURI` は「A JSON string value ... any value containing a `:` character MUST be a URI」と定義され、空文字列は有効な `StringOrURI` ではない（識別子として意味を持たない）。
- **OpenID Connect Core 1.0 §2 (ID Token)**: `aud` は REQUIRED で、ID Token を受け取るべき audience（通常は RP の `client_id`）を表す。空の audience は「誰宛でもない」ため検証側の `aud` 照合（§3.1.3.7 step 3）が破綻する。
- 既存実装は**配列パスでは既にこの厳格性を適用済み**（`packages/core/src/id-token.ts:117-123`「Audience array must contain only non-empty strings」）。本トピックはその防御をスカラーパスにも対称に適用するという差分。

## 4. 参照資料

- RFC 7519 (JSON Web Token) §4.1.3 `aud` / §2 `StringOrURI` の定義 — https://datatracker.ietf.org/doc/html/rfc7519#section-4.1.3
- OpenID Connect Core 1.0 §2 ID Token（`aud` REQUIRED）/ §3.1.3.7 ID Token Validation（`aud` 照合）— https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- 本リポジトリ内の対称防御の先例: `packages/core/src/id-token.ts:117-123`（配列メンバー検証）、テスト `packages/core/src/id-token.test.ts:824-842`（配列パスのみ網羅）

## 5. 現在の実装確認

`packages/core/src/id-token.ts` `validatePayload`（該当行）:

```ts
if (payload.aud === undefined || payload.aud === null) {          // L105
  throw new Error('Missing required claim: aud');
}
// Validate aud is not empty array
if (Array.isArray(payload.aud) && payload.aud.length === 0) {     // L110
  throw new Error('Audience must not be an empty array');
}
// 配列メンバーの空文字列 / 非文字列を拒否
if (Array.isArray(payload.aud)) {                                 // L117
  for (const a of payload.aud) {
    if (typeof a !== 'string' || a.length === 0) {
      throw new Error('Audience array must contain only non-empty strings');
    }
  }
}
```

- L110 と L117 の両方が `Array.isArray(payload.aud)` でガードされているため、`payload.aud = ""`（スカラー空文字列）はいずれの分岐にも入らず、そのまま `generateIdToken` の署名対象になる。
- `generateTokenResponse`（`token-response.ts:323`）は ID Token の `aud` に `clientId` を代入する。したがって呼び出し側が空の `client_id` を渡す等の誤設定があると、`aud: ""` の ID Token が発行され得る。
- テスト `id-token.test.ts:826-841` は `aud: ['client-1', '']`（配列メンバー）を検証しているが、**スカラー `aud: ''` のケースは存在しない**（穴の裏付け）。

## 6. 現在の実装との差分

満たしていること:
- `aud` 欠損・空配列・配列メンバーの空文字列/非文字列は拒否済み（配列パスの健全性は担保）。

不足している可能性があること:
- 🟡 **スカラー空文字列 `aud: ""` を発行できてしまう**（構造的に不正な ID Token の混入）。配列パスに入れた防御と非対称。

相互運用性の観点:
- 空 `aud` の ID Token を受け取った RP は §3.1.3.7 の `aud` 照合に失敗する。不正な値を「発行できてしまう」こと自体が、生成 OP の Fidelity シグナル（Conformance 準拠）を毀損する。

Basic OP として確認すべきこと:
- Basic OP は Authorization Code Flow の ID Token 発行を必須とする。`aud` は必須クレームであり、その構造健全性は発行側の責務。スカラーパスの穴は「発行された ID Token が常に spec 準拠である」という保証の隙間になる。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 攻撃というより「誤設定を早期に弾く」防御的整合性。空 `client_id` 等の設定ミスを発行時に検知でき、下流の RP で初めて発覚するより早く原因が分かる。
- **Basic OP 必須か拡張か**: `aud` の非空は RFC 7519 / OIDC Core が要求する構造要件であり、Basic OP としての正しさに含まれる（新機能ではなく既存防御の穴埋め）。
- **導入しやすさ**: 既に配列パスに同等の検証があるため、スカラーパスに 1 分岐足すだけ。core 内で完結し、resolver/テンプレート/sample への波及がない。
- **利用者メリット**: 生成コードを改変して誤った `client_id` を渡した場合でも、Conformance テスト/単体テストで即座に気付ける。
- **実装しない場合のリスク**: 「発行 ID Token は常に spec 準拠」という前提に例外が残り、監査ドキュメント上の Fidelity 主張と実装が食い違う。

## 8. 実装方針の候補

最終判断は人間が行う前提で、判断材料を整理する。

- 方針A（スカラーも非空文字列を要求 / 推奨）: `aud` がスカラーのとき `typeof payload.aud === 'string' && payload.aud.length === 0` を拒否する。配列パスのメッセージと平仄を合わせ、`Audience must be a non-empty string` 等を投げる。最小差分で対称性を回復。
- 方針B（`aud` を一元バリデータ化）: スカラー/配列を一つのヘルパー（例 `assertValidAudience`）に集約し、`id-token.ts` と `access-token.ts`（`access-token.ts:40-48` は既に非空配列を要求）で共有する。重複ロジックを減らせるが変更範囲がやや広い。
- 方針C（`StringOrURI` 厳格化まで踏み込む）: 空文字列だけでなく「`:` を含むなら URI であること」等 `StringOrURI` 完全準拠に拡張。過剰対応の懸念があり、Basic OP スコープでは方針A/Bで十分な可能性が高い。

`sub` の文字種検証（`tasks/p3-sub-ascii-charset-enforcement.md`）と共通バリデータ化を合わせるか（方針B寄り）は、その未着手タスクとの兼ね合いで判断する。

## 9. タスク案

- [ ] （TDD）`id-token.test.ts` に「`aud: ''`（スカラー空文字列）→ 発行拒否」のテストを先に追加（Red）
- [ ] `validatePayload` のスカラーパスに非空文字列チェックを追加（Green）。配列パスのメッセージと平仄を合わせる
- [ ] `access-token.ts` / 署名付き UserInfo の `aud` 発行経路と共通化するか（方針B）を判断し、必要なら共通バリデータへ寄せる
- [ ] リグレッション確認: 正常なスカラー `aud`（通常の `client_id`）と正常な配列 `aud` が従来どおり発行できること
- [ ] `pnpm --filter @maronn-openid-connect/core test` がパスすること

## 関連トピック

- `study-material/done/sub-ascii-charset-enforcement.md` / `tasks/p3-sub-ascii-charset-enforcement.md` — `sub` の文字種・長さ検証。共通バリデータ化を検討する場合の相方。
- `study-material/request-object-scalar-value-type-handling.md` — Request Object のスカラー値型ハンドリング（別入口だが「スカラー値の健全性」という同系統の論点）。
