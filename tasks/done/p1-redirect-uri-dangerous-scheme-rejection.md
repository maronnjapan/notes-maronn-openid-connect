# [P1] 危険スキーム / ループバック以外の `http://` redirect_uri を拒否する

## ステータス

🟡 Major / 未着手

## 背景

`validateRegisteredRedirectUris` は fragment（`#`）を含む URI のみを拒否する。これは OIDC Core §3.1.2.1 で MUST だが、RFC 8252 §8.5 と OAuth 2.0 Security BCP の観点では以下も AS 側で拒否すべき:

- **危険スキーム**: `javascript:` / `data:` / `file:` / `vbscript:` / `blob:` 等は XSS / RCE の起点になる
- **ループバック以外の `http://`**: OIDC Core §3.1.2.1 と RFC 8252 §8.4 によりプロダクションでは禁止。ループバック（`localhost` / `127.0.0.1` / `[::1]`）以外の平文 HTTP は受理すべきでない

現状の `matchRedirectUri` は完全一致を要求するため、AS 設定者が誤って危険スキームや非ループバック `http://` を登録しなければ事故は起きない。しかし設定者を信頼するだけの設計では DCR（`study-material/ext-dynamic-client-registration.md`）拡張時に untrusted 登録元から危険 URI が混入する経路ができる。防御の深さとして登録時に弾くべき。

詳細な仕様調査と方針候補は `study-material/done/oauth-native-apps-rfc8252.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`

## 仕様参照

- RFC 8252 OAuth 2.0 for Native Apps §8.4 / §8.5
- OIDC Core 1.0 §3.1.2.1: redirect_uri MUST NOT include a fragment
- OAuth 2.1 §10.3 / §10.4: redirect_uri Security Considerations
- OAuth 2.0 Security Best Current Practice — Dangerous Schemes

## 現状の実装

```ts
// packages/core/src/authorization-request.ts:269-284 validateRegisteredRedirectUris
export function validateRegisteredRedirectUris(registeredUris: string[]): void {
  for (const uri of registeredUris) {
    if (uri.includes('#')) {
      throw new AuthorizationError(
        AuthorizationErrorCode.ServerError,
        `Registered redirect_uri must not contain fragment: ${uri}`
      );
    }
  }
  // ↑ 危険スキーム / 非ループバック http:// は通る
}
```

## 修正方針

- [ ] `validateRegisteredRedirectUris` に以下を追加する:
  - 危険スキーム（`javascript:` / `data:` / `file:` / `vbscript:` / `blob:`）を拒否する。スキーム判定は ASCII 小文字化して比較する
  - `http://` で host がループバック（`localhost` / `127.0.0.1` / `[::1]`）以外なら拒否する
- [ ] 違反時は `ServerError` を投げる（設定ミスは redirectable でない fatal）
- [ ] エラーメッセージで「どの URI のどこが問題か」が分かるようにする（既存 fragment 拒否と同じ粒度）

```ts
const DANGEROUS_SCHEMES = new Set([
  'javascript:',
  'data:',
  'file:',
  'vbscript:',
  'blob:',
]);

export function validateRegisteredRedirectUris(registeredUris: string[]): void {
  for (const uri of registeredUris) {
    if (uri.includes('#')) { /* 既存 */ }

    // スキーム抽出（先頭から ':' まで、ASCII 小文字化）
    const colonIndex = uri.indexOf(':');
    if (colonIndex === -1) {
      throw new AuthorizationError(
        AuthorizationErrorCode.ServerError,
        `Registered redirect_uri must include a scheme: ${uri}`,
      );
    }
    const scheme = uri.slice(0, colonIndex + 1).toLowerCase();

    if (DANGEROUS_SCHEMES.has(scheme)) {
      throw new AuthorizationError(
        AuthorizationErrorCode.ServerError,
        `Registered redirect_uri uses a dangerous scheme: ${scheme}`,
      );
    }

    // http:// で loopback 以外を拒否
    if (scheme === 'http:') {
      try {
        const url = new URL(uri);
        const isLoopback =
          url.hostname === 'localhost' ||
          url.hostname === '127.0.0.1' ||
          url.hostname === '[::1]';
        if (!isLoopback) {
          throw new AuthorizationError(
            AuthorizationErrorCode.ServerError,
            `Registered redirect_uri must use https:// or loopback http:// — got ${uri}`,
          );
        }
      } catch (e) {
        if (e instanceof AuthorizationError) throw e;
        throw new AuthorizationError(
          AuthorizationErrorCode.ServerError,
          `Registered redirect_uri is not a valid URL: ${uri}`,
        );
      }
    }
  }
}
```

## テスト要件

- [ ] `javascript:alert(1)` を登録 → `ServerError`
- [ ] `data:text/html,...` を登録 → `ServerError`
- [ ] `file:///etc/passwd` を登録 → `ServerError`
- [ ] `vbscript:...` を登録 → `ServerError`
- [ ] `blob:...` を登録 → `ServerError`
- [ ] `JAVASCRIPT:alert(1)` のように大文字スキーム → `ServerError`（case-insensitive）
- [ ] `http://example.com/cb` を登録 → `ServerError`（non-loopback http）
- [ ] `http://localhost:3000/cb` → OK
- [ ] `http://127.0.0.1:3000/cb` → OK
- [ ] `http://[::1]:3000/cb` → OK
- [ ] `https://example.com/cb` → OK
- [ ] `com.example.app:/oauth2redirect` → OK（カスタムスキームは許容）

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
