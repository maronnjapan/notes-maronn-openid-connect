# [P0] `offline_access` 要求時の `prompt=consent` / scope 無視制御

## ステータス

🟡 Critical / 未着手

## 背景

OIDC Core 1.0 §11 では、`offline_access` を要求する場合は `prompt` に `consent` を含めること、またはそれに代わる「offline access を許可するための他条件」があることを要求している。条件を満たさない場合、Authorization Server は `offline_access` 要求を無視しなければならない。

現状実装は通常フローで常に consent 画面を経由するものの、認可リクエスト自体に `prompt=consent` が無くても `offline_access` をそのまま保持し、結果として refresh token を発行しうる。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/cli/src/frameworks/hono/templates.ts`

## 仕様参照

- OIDC Core 1.0 §11: Offline Access

## 現状の実装

- `validateAuthorizationRequest()` は `scope` に `offline_access` が含まれていても、`prompt` 値との整合を検証していない
- CLI の authorize / consent ルートは `offline_access` を `offlineAccessAllowed` でのみフィルタしている
- Token Endpoint は `validatedRequest.scope.includes('offline_access')` を基準に refresh token を発行する

そのため、`prompt=consent` が無い認可リクエストでも `offline_access` が最終的な付与 scope に残り、refresh token が発行される。

## 修正方針

- [ ] `offline_access` を含む認可リクエストを検出し、`prompt` に `consent` が含まれない場合は `offline_access` を付与 scope から除外する
- [ ] 「他条件で offline access を許可する」拡張点は将来追加可能な形にしつつ、現状は安全側として除外をデフォルトにする
- [ ] `prompt=none` かつ `offline_access` を要求された場合も、現状の `consent_required` 分岐に到達する前に `offline_access` が除外されることを確認する
- [ ] refresh token 発行判定は「最終的に付与された scope」に対してのみ行う

### 拡張性要件（将来の独自 consent 判定の差し込み）

`prompt=consent` の代替として「OP 独自の条件で offline access を許可する」ロジックを後から差し込めるよう、判定処理を差し替え可能にしておく。

- `offline_access` を許可するか否かの判定を `isOfflineAccessGranted(request, context) => boolean` のようなコールバック形式に切り出す
- デフォルト実装は `prompt.includes('consent')` のみを許可条件とする（現在の安全側の挙動を維持）
- コールバックは `validateAuthorizationRequest()` の呼び出しオプション（または上位の設定オブジェクト）として渡せるインターフェースを用意する
- CLI テンプレートはデフォルト実装をそのまま渡す形にし、利用者がオプションを上書きすることで独自ロジックを注入できることを示すコメントを残す

## テスト要件

- [ ] `scope=openid offline_access` かつ `prompt` 未指定で認可した場合、認可コードに `offline_access` が保存されないこと
- [ ] `scope=openid offline_access` かつ `prompt=consent` の場合、`offline_access` が保持されること
- [ ] `offlineAccessAllowed=false` の既存フィルタと今回の `prompt=consent` 条件が両立すること
- [ ] `prompt=none` + `offline_access` でも refresh token が発行されないこと
- [ ] カスタムの `isOfflineAccessGranted` コールバックを渡した場合、デフォルト条件（`prompt=consent`）を満たさなくても `offline_access` が許可されること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
