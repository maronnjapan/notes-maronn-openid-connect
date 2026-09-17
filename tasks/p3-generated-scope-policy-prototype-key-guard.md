# [P3] 生成 scopes.ts の RESTRICTED_SCOPE_SUBJECTS ルックアップを own-property 判定にする

## ステータス

🟢 Low / 未着手

## 背景

生成される `scopes.ts` は `RESTRICTED_SCOPE_SUBJECTS[scope]` を素引きするため、`--scope constructor` / `--scope __proto__` のように `Object.prototype` のプロパティ名と一致する scope（RFC 6749 §3.3 の ABNF 上は正当で、CLI も受理する）を宣言すると、プロトタイプ連鎖の値が返って `allowedSubjects.includes` が TypeError になる。
該当 scope を含む正当なリクエストが consent / SSO / prompt=none / device / CIBA 承認へ到達するたびに 500 / server_error になる。
宣言しなければ `findUnsupportedScopes` が先に弾くため外部から起動はできず、発生条件は開発者自身の宣言に限られる。

詳細は `study-material/done/generated-scope-policy-prototype-key-collision.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（scopes.ts テンプレートのルックアップと、conformance テスト内の `RESTRICTED_SCOPE_SUBJECTS` 書き込み箇所）
- `packages/cli/src/__tests__/custom-scope-feature.test.ts`

## 仕様参照

- RFC 6749 §3.3（scope-token の ABNF。`constructor` 等は正当な scope 名）

## 現状の実装

```typescript
const allowedSubjects = RESTRICTED_SCOPE_SUBJECTS[scope];
return allowedSubjects === undefined || allowedSubjects.includes(subject);
```

## 修正方針

- [ ] ルックアップを `Object.hasOwn(RESTRICTED_SCOPE_SUBJECTS, scope)` ガード付きにする（`Map` / `Object.create(null)` 化は利用者が編集するファイルの書き味が変わるため採らない）
- [ ] CLI 側での `__proto__` / `constructor` / `prototype` の宣言拒否は行わない（ABNF 上正当な名前を狭める判断は本タスクに含めない。必要なら別途検討）

## テスト要件

- [ ] `should resolve grantable scopes for a scope named constructor`（生成コードを実行して検証）
- [ ] `should resolve grantable scopes for a scope named __proto__`
- [ ] 既存の custom-scope テストの回帰確認

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm typecheck
pnpm test:conformance
```

- `--scope constructor` で生成した OP の consent フローが 500 にならないことをテストで固定する
