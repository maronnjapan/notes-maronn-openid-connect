# [P1] Consent の記録・再利用（`prompt=none` を実機で成立させる）

## ステータス

🟠 High / 未着手

## 背景

core には読み取り側の `ConsentResolver.hasConsent(subject, clientId, scopes)` が存在し、`checkPromptNone` に統合済み（`tasks/done/p0-consent-resolver.md`）。
しかし **同意を記録する書き込み側が一切存在せず**、sample / CLI 生成 Provider では `consentResolver` も consent ストアも未配線である。

その結果:

- `prompt=none` 経路は `consentResolver` が常に undefined のため **構造的に常に `consent_required`** を返す（`routes/authorize.ts` 194-197 行）。認証セッションを永続化しても consent 側が空のままでは silent な再認可が成立しない。
- 通常フローでは同一クライアント・同一スコープへの再訪でも **毎回同意 UI** が出る（consent fatigue → フィッシング耐性低下）。

検討の全体像・方針の選択肢は `study-material/done/consent-grant-persistence-and-management.md` を参照。
本タスクは「`prompt=none` を成立させる最小機構（記録 + 対話フローでの参照）」に絞る。
incremental consent の高度化・grant 失効 UI / Grant Management 拡張は本タスクの範囲外（study-material 側に残置）。

> 依存: `prompt=none` の silent 成功には認証セッション永続化が前提。
> `tasks/p1-generated-provider-browser-session-sso.md` とセットで効果が出る。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`ConsentResolver` への記録メソッド追加、または別 `ConsentStore` 型の新設）
- `packages/core/src/auth-transaction.test.ts`（部分集合判定・記録のテスト）
- `packages/core/src/index.ts`（型の export）
- `packages/sample/src/oidc-provider/store.ts`（consent ストア追加）
- `packages/sample/src/oidc-provider/resolvers.ts`（`consentResolver` 配線 + 記録実装）
- `packages/sample/src/oidc-provider/routes/consent.ts`（承認時に記録）
- `packages/sample/src/oidc-provider/routes/authorize.ts`（通常経路で既存同意を参照）
- `packages/cli/src/frameworks/hono/templates.ts`（生成コードへ反映 — 生成物の修正は cli 側で行う）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1（`prompt`）:
  - `prompt=none`: 認証・同意 UI を表示してはならない（MUST NOT）。同意未取得なら `consent_required`。
  - `prompt=consent`: 過去同意の有無にかかわらず同意 UI を再表示しなければならない（MUST）。
  - `prompt` 省略時: 同意取得済みなら UI スキップ可（MAY）。
- OIDC Core 1.0 §3.1.2.4（OP が consent を取得する責務。再利用可否は OP 裁量）。
- OIDC Core 1.0 §11（`offline_access` の「その他の条件」に記録済み同意を充てられる）。
- 根拠の詳細は `study-material/done/consent-grant-persistence-and-management.md` §2 を参照。

## 現状の実装

- `packages/core/src/auth-transaction.ts`: `ConsentResolver` は `hasConsent` のみ（読み取り）。記録メソッドが無い。
- `packages/sample/src/oidc-provider/routes/consent.ts`: `action=allow` でコード発行するが **同意を記録しない**。
- `packages/sample/src/oidc-provider/routes/authorize.ts`: 通常経路は常に login → consent へ誘導し、既存同意でスキップする分岐が無い。`prompt=none` は `consentResolver` 未設定で即 `consent_required`。
- `packages/sample/src/oidc-provider/resolvers.ts` / `store.ts`: consent ストアも `consentResolver` 登録も無い。

問題: 読み取り側 `ConsentResolver` が実データを持たず、`prompt=none` が機能しない。

## 修正方針

- [ ] 記録 API の置き場所を決定する（A: `ConsentResolver` に `recordConsent` / `revokeConsent` を追加 / B: 別 `ConsentStore` を新設）。後方互換のため記録メソッドは任意（optional）にすることを検討
- [ ] `hasConsent` の契約を「**要求スコープ ⊆ 付与済みスコープ** のときのみ true」と明文化（部分一致 true は scope 昇格を招くため禁止）
- [ ] core: `prompt=consent` のときは既存同意があっても **必ず再同意**する分岐（対話フロー側で参照する際の前提条件）を整理
- [ ] sample `store.ts`: `(subject, clientId) -> grantedScopes` を保持する consent ストアを追加（`resolver-and-store-contract.md` の参照一貫性・失効反映の契約に従う）
- [ ] sample `resolvers.ts`: `consentResolver`（`hasConsent` + 記録）を実装し、middleware で `c.set('consentResolver', ...)` 配線
- [ ] sample `routes/consent.ts`: `action=allow` 時に付与スコープを記録（最小 incremental: 要求 ⊄ 付与なら全スコープ再同意 → 承認後にマージ）
- [ ] sample `routes/authorize.ts`: `prompt` に `consent` を含まず、かつ `hasConsent(subject, clientId, requestedScopes)` が true なら consent UI をスキップして直接コード発行（`max_age` / `prompt=login` の既存分岐と順序整合）
- [ ] CLI テンプレートへ反映（生成 Provider にも consent ストア + 配線が入るようにする）

実装イメージ（方針A・最小）:

```ts
// core: auth-transaction.ts
export interface ConsentResolver {
  hasConsent(subject: string, clientId: string, scopes: string[]): Promise<boolean>;
  // 追加（任意）: 承認時の記録 / 失効
  recordConsent?(subject: string, clientId: string, scopes: string[]): Promise<void>;
  revokeConsent?(subject: string, clientId: string): Promise<void>;
}
```

## テスト要件

- [ ] `hasConsent` は要求スコープが付与済みの部分集合なら true、新規スコープを含むなら false（scope 昇格防御）
- [ ] consent 承認 → `recordConsent` が呼ばれ、以降の `hasConsent` が true を返す
- [ ] `prompt=none`: session 有 + 記録済み同意有 → `consent_required` を返さず silent にコード発行
- [ ] `prompt=none`: session 有 + 同意無 → `consent_required`
- [ ] `prompt=consent`: 記録済み同意が有っても同意 UI を再表示する（スキップしない）
- [ ] `prompt` 省略: 記録済み同意が有れば consent UI をスキップする / 無ければ表示する
- [ ] 通常経路で新規スコープが過去同意に含まれない場合は再同意になる（incremental 最小）

## 完了条件

- [ ] 上記テストが全て通る（`pnpm test`）
- [ ] sample / CLI 生成 Provider で、session 永続化と組み合わせたとき `prompt=none` が silent 成功する
- [ ] `study-material/done/consent-grant-persistence-and-management.md` の該当タスク案にチェックが入る
- [ ] 既存の `prompt` 系・`offline_access` 系テストにリグレッションが無い
