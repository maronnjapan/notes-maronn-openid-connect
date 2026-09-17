# [P2] PAR エンドポイントに宣言外スコープの許容リストチェックを注入する

## ステータス

🟡 Medium / 未着手

## 背景

`--scope` 宣言時、認可・device・CIBA の各リクエスト受付エンドポイントには `findUnsupportedScopes` による宣言外 scope の `invalid_scope` 拒否が注入されるが、PAR エンドポイント（`--enable par`）だけ注入されない。
宣言外 scope の pushed request が 201 + `request_uri` で受理され、拒否が /authorize 到達時のフロントチャネルまで遅延する。
RFC 9126 §2.1（認可リクエストと同様に検証する MUST）と、生成 PAR ルート自身のコメント「a bad scope fails here, before the user ever sees a screen」に反する。
/authorize 側で PAR 展開後の scope にもチェックが効くため、発行時点の抜けは無い（一貫性・早期検証の問題）。

詳細は `study-material/done/par-custom-scope-allowlist-parity.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`parRouteTemplate` に scopes を渡し、チェックを注入。コメントの整合も取る）
- `packages/cli/src/frameworks/hono/index.ts` / `packages/cli/src/frameworks/web-standard/templates.ts`（呼び出し側）
- `packages/cli/src/__tests__/custom-scope-feature.test.ts` / `par-feature.test.ts`
- 生成 conformance テストテンプレート

## 仕様参照

- RFC 9126 §2.1（PAR リクエストは認可リクエストと同様に検証する）
- RFC 6749 §4.1.2.1（invalid_scope）

## 現状の実装

`parRouteTemplate(corePkg)` は scope 宣言を受け取らず、`findUnsupportedScopes` を呼ばない。
device / CIBA のルートテンプレートは同チェックを注入済み。

## 修正方針

- [ ] `parRouteTemplate` へ scopes を渡す
- [ ] `validatePushedAuthorizationParams` の後（core の offline_access ポリシー適用後）に device と同形の `findUnsupportedScopes` チェックを注入し、`ParError('invalid_scope')` を返す
- [ ] 「a bad scope fails here」コメントを実挙動と整合させる
- [ ] `--scope` 未宣言時は従来出力とバイト同一であることを維持する

## テスト要件

- [ ] `should reject a pushed request containing an undeclared scope with invalid_scope`（4 フレームワーク）
- [ ] `should accept a pushed request whose scopes are all declared`
- [ ] `should keep the PAR route byte-identical when no custom scope is declared`
- [ ] 生成 conformance テストに宣言外 scope の PAR 拒否ケースを追加

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm typecheck
pnpm test:conformance
```

- 上記がすべて成功する
- `--enable par --scope reports.read` で生成した OP へ宣言外 scope を push すると 400 / invalid_scope が返る
