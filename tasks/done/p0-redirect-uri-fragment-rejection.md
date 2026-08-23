# [P0] 登録済み redirect_uri のフラグメント拒否

## 背景

OIDC Core 1.0 Section 3.1.2.1：
> The redirect_uri MUST NOT include a fragment component.

これはリクエスト時の `redirect_uri` だけでなく**登録時**にも適用される。
Basic OP 認定の `OP-redirect_uri-RegFrag` テストで検証される。

## 現状の問題

`packages/core/src/authorization-request.ts` の `resolveRedirectUri()` は、リクエストパラメータの `redirect_uri` に `#` が含まれていれば拒否するが、`ClientResolver.findClient()` が返した登録済みの `redirectUris` 内のフラグメントは検出しない。

利用者が誤ってフラグメント付きの URI を登録すると、認定要件を破る。

## 準拠仕様

- OIDC Core 1.0 Section 3.1.2.1 (Authentication Request)
  > The Redirection URI MUST NOT use the fragment component.
- OAuth 2.1 Section 4.1.1.1

## 実装方針（二重防御）

Codex との協議結果（2026-04-30）：「ClientResolver の責務に寄せる」のではなく「core でも必ずチェック」する二重防御を採用する。利用者の実装ミスがあっても認定要件を守れる。

### `packages/core/src/authorization-request.ts`

`resolveRedirectUri()` の冒頭で、登録済み URI 群を検査するヘルパーを追加：

```ts
function validateRegisteredRedirectUris(registeredUris: string[]): void {
  for (const uri of registeredUris) {
    if (uri.includes('#')) {
      throw new AuthorizationError(
        AuthorizationErrorCode.ServerError,
        `Registered redirect_uri must not contain fragment: ${uri}`,
      );
    }
  }
}
```

`validateAuthorizationRequest()` の `clientResolver.findClient()` 直後、`resolveRedirectUri` 呼び出しの前に `validateRegisteredRedirectUris(client.redirectUris)` を呼ぶ。

エラーは `server_error`（リダイレクト不可）として扱う：登録ミスは設定問題であり、エンドユーザに見せても無意味。

### `packages/core/src/index.ts`

ヘルパー単独でも使えるようにエクスポート：

```ts
export { validateRegisteredRedirectUris } from './authorization-request';
```

### `packages/sample/src/oidc-provider/config.ts`

`createInMemoryClientResolver` の `defaultRegisteredClients` がフラグメント付き URI を含まないことをテストで保証（regression防止）。

## テストケース

`packages/core/src/authorization-request.test.ts` に追記（TDD）：

`describe('validateAuthorizationRequest', () => describe('Registered Redirect URI', () =>`
- `should throw server_error when registered redirect_uri contains fragment`
- `should not throw when registered URIs are clean`
- `should reject before scope validation (fail fast)`

`describe('validateRegisteredRedirectUris', () =>`（ヘルパー単体）
- `should throw for URI containing #`
- `should accept https URI without fragment`
- `should accept loopback URI without fragment`

## 完了条件

- [ ] core でフラグメント付き登録 URI が `server_error` として拒否される
- [ ] テストが全て通る
- [ ] エクスポートが index.ts にある

## 備考

- リクエスト側のフラグメント拒否（既存の `requestRedirectUri.includes('#')`）はそのまま維持。
- これは「登録時」を想定したサーバ側のセーフティネット。本来は client registration 時に拒否すべき。
