# [P0] ConsentResolverインターフェース定義 + checkPromptNone完成

## 背景

現状の問題が2点ある。

**問題1**: `ConsentResolver` インターフェースがcoreに存在しない。
サンプルの `authorize.ts` で `consentResolver.hasConsent()` を使っているが、
coreに型定義がないため、利用者がインターフェースを推測して実装しなければならない。

**問題2**: `checkPromptNone()` がセッション確認のみで、コンセント確認が欠落している。
`prompt=none` はセッション確認 + コンセント確認の両方が必要（OIDC Core Section 3.1.2.1）。
現在の `checkPromptNone` はセッション確認のみで、コンセント確認はサンプル層に実装されている。

## 準拠仕様

- OIDC Core 1.0 Section 3.1.2.1 (prompt パラメータ)
  - `prompt=none`: ユーザーインタラクションなしで認証とコンセントを完了しなければならない
  - コンセントが得られていなければ `consent_required` を返す

## 実装内容

### `packages/core/src/auth-transaction.ts` への追加

```ts
// ConsentResolverインターフェース（新規）
export interface ConsentResolver {
  hasConsent(subject: string, clientId: string, scopes: string[]): Promise<boolean>;
}
```

### `checkPromptNone` のシグネチャ変更

```ts
// 変更前
export async function checkPromptNone(
  transaction: AuthTransaction,
  sessionResolver: SessionResolver,
  request: Request
): Promise<SessionInfo>

// 変更後
export async function checkPromptNone(
  transaction: AuthTransaction,
  sessionResolver: SessionResolver,
  request: Request,
  consentResolver?: ConsentResolver  // 追加
): Promise<SessionInfo>
```

`consentResolver` が渡された場合:
- セッション確認 → 通過したら
- コンセント確認 → `hasConsent` が false なら `consent_required` をスロー

`consentResolver` が渡されない場合:
- 現在の挙動を維持（セッション確認のみ）

### エクスポート

`packages/core/src/index.ts` から `ConsentResolver` をエクスポートする。

## テスト

`packages/core/src/auth-transaction.test.ts` に追記する（TDD）。

追加するテストケース:
- should throw consent_required when consentResolver returns false
- should return session when both session and consent are valid
- should not check consent when consentResolver is not provided (backward compat)

## 完了条件

- [ ] テストが全て通る
- [ ] `ConsentResolver` が core の index.ts からエクスポートされている
- [ ] `packages/sample/src/oidc-provider/routes/authorize.ts` のコンセント確認ロジックをcoreの `checkPromptNone` に統合する
