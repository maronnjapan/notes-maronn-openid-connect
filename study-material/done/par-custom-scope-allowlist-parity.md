# PAR エンドポイントだけカスタムスコープ許容リストが未適用になっている非対称

## 1. このトピックで確認したいこと

`--scope` 宣言時、認可エンドポイント・device 認可エンドポイント・CIBA バックチャネル認証エンドポイントには宣言外 scope を `invalid_scope` で拒否する許容リストチェックが注入されるのに、PAR エンドポイント（`--enable par`）には注入されない。この非対称が RFC 9126 の検証要件と生成コードの自己記述に照らして妥当かを確認する。

## 2. 関連する仕様・基準

- RFC 9126 §2.1: "the authorization server MUST validate the request as it would an authorization request"。PAR 実装（`packages/experimental/src/par/par-request.ts`）自身がこの条文を引用している。
- RFC 6749 §4.1.2.1: `invalid_scope` エラー。

## 3. 参照資料

- `packages/cli/src/frameworks/hono/templates.ts`（`parRouteTemplate` は `scopes` を受け取らない。device / CIBA のルートテンプレートは `findUnsupportedScopes` を注入済み）
- `study-material/ext-pushed-authorization-requests-rfc9126.md` / `study-material/extension-pushed-authorization-requests-par.md`（PAR 一般。scope 検証タイミングは扱っていない）

## 4. 現在の実装確認

- `parRouteTemplate(corePkg)` は scope 宣言を受け取らず、`findUnsupportedScopes` を呼ばない。呼び出し側（hono の generator と web-standard の変換）も scope を渡していない。
- 生成 PAR ルートのコメントは「an unregistered redirect_uri or a bad scope fails here, before the user ever sees a screen」と主張しており、宣言外 scope については実挙動と一致しない。
- /authorize 側の customScopeStep は PAR 展開後の scope にも効くため、最終的な発行時点での抜けは無い。

## 5. 現在の実装との差分

- 🟠 宣言外 scope を含む pushed request が 201 + `request_uri` で受理され、拒否が /authorize 到達時のフロントチャネル（redirect の `invalid_scope`）まで遅延する。RFC 9126 §2.1 の「認可リクエストと同様に検証する」に照らすと、PAR 時点で検証すべき項目が漏れている。
- 🟠 エンドポイント間の一貫性（device / CIBA は宣言外 scope をリクエスト受付時に拒否する）を欠く。
- 🟢 セキュリティ上の抜け（宣言外 scope での発行）は無い。品質・一貫性・コメントの正確性の問題。

## 6. 改善・追加を検討する理由

PAR の利点は「ユーザーを画面に送る前にバックチャネルでリクエスト不備を検出できる」ことにあり、生成コードのコメントもそれを売りにしている。宣言外 scope だけがフロントチャネルまで遅延するのは、この利点と自己記述の両方を裏切る。device / CIBA と同形のステップを注入するだけで揃えられ、変更は局所的。

## 7. 実装方針の候補

- `parRouteTemplate` に scopes を渡し、`validatePushedAuthorizationParams` の後（core 側で offline_access ポリシー適用後）に device と同形の `findUnsupportedScopes` チェックを注入して `ParError('invalid_scope')` を返す。コメントも整合させる。
- web-standard 変換経由で 4 フレームワークに展開されることを generator テストで固定する。

## 8. タスク案

- [ ] PAR ルートへの許容リストチェック注入と conformance テスト追加

→ `tasks/p2-par-custom-scope-allowlist.md` としてタスク化済み。
