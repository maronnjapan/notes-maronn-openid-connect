# 生成 scopes.ts の RESTRICTED_SCOPE_SUBJECTS がプロトタイプ連鎖のキーと衝突する問題

## 1. このトピックで確認したいこと

`--scope constructor` や `--scope __proto__` のように、`Object.prototype` のプロパティ名と一致する scope 名を宣言した場合、生成 OP が実行時エラー（500 / server_error）を返す。RFC 6749 の scope 文法上これらは正当な scope 名であり、CLI も無警告で受理する。この組み合わせをどう扱うべきかを確認する。

## 2. 関連する仕様・基準

- RFC 6749 §3.3: scope-token = 1*( %x21 / %x23-5B / %x5D-7E )。`constructor` / `__proto__` / `toString` 等は正当な scope 名。
- 本リポジトリの方針: CLI が無警告で壊れた OP を生成しないこと（生成物の契約）。

## 3. 参照資料

- `packages/cli/src/scopes.ts`（`resolveCustomScopes` は ABNF と予約 scope のみ検証）
- `packages/cli/src/frameworks/hono/templates.ts` の scopes.ts テンプレート（`RESTRICTED_SCOPE_SUBJECTS[scope]` の素引き）

## 4. 現在の実装確認

生成される `scopes.ts` は次の形で許可 subject を引く。

```typescript
const allowedSubjects = RESTRICTED_SCOPE_SUBJECTS[scope];
return allowedSubjects === undefined || allowedSubjects.includes(subject);
```

`RESTRICTED_SCOPE_SUBJECTS` は素のオブジェクトリテラルなので、`scope === 'constructor'` では `Object.prototype.constructor`（関数）が、`'__proto__'` では `Object.prototype` が返り、`allowedSubjects.includes` が存在せず TypeError になる。

## 5. 現在の実装との差分

- 🟠 該当 scope を宣言して生成した OP は、その scope を含む正当なリクエストが consent / SSO / prompt=none / device / CIBA 承認に到達するたびに 500（またはフロー次第で server_error redirect）になる。
- 🟢 宣言しなければ `findUnsupportedScopes`（`Array.includes`）が先に弾くため、攻撃者が外部から起動することはできない。発生条件は開発者自身の宣言に限られる。
- 🟠 生成 conformance テスト内の `RESTRICTED_SCOPE_SUBJECTS['__proto__'] = [...]` のような書き込みもプロトタイプ代入になり壊れる。

## 6. 改善・追加を検討する理由

CLI は scope 名の検証者を名乗っており（ABNF・予約 scope の拒否を実装済み）、検証を通した宣言が実行時に必ず壊れるのは契約違反にあたる。修正は生成テンプレートの 1 箇所（`Object.hasOwn` ガードか `Map` 化）と CLI 検証の 1 箇所で済み、導入は容易。

## 7. 実装方針の候補

- 案 A: 生成コードを `Object.hasOwn(RESTRICTED_SCOPE_SUBJECTS, scope)` ガード付きにする（最小変更）。
- 案 B: `RESTRICTED_SCOPE_SUBJECTS` を `Object.create(null)` ベースまたは `Map` にする（構造的に安全だが、利用者が編集するファイルとしての書き味が変わる）。
- 併せて CLI 側で `__proto__` / `constructor` / `prototype` の宣言を拒否またはエラーにする案もある。ただし案 A / B が入れば実害は無く、正当な ABNF を狭める判断は人間に委ねる。

## 8. タスク案

- [ ] 生成 scopes.ts のルックアップを own-property 判定にする
- [ ] `--scope constructor` で生成した OP のフロー完走を generator / conformance テストで固定する

→ `tasks/p3-generated-scope-policy-prototype-key-guard.md` としてタスク化済み。
