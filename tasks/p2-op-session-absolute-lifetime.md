# [P2] OP ブラウザセッションに絶対有効期限を導入し、永続バックエンドにも TTL を渡す

## ステータス

🟡 Medium / 未着手

## 背景

CLI 生成 OP のブラウザ（OP）セッションには**有効期限が一切無い**。

- `BrowserSessionInfo` は `{ subject, authTime }` のみで期限フィールドを持たない
- `BrowserSessionStore.get()` に期限判定が無い（認可コード / AT / RT の各ストアはいずれも
  `expiresAt <= now` の lazy eviction を持つのに、セッションだけ非対称）
- `JsonBrowserSessionStore.set()` が `backend.put(key, value)` を `ttlSeconds` 無しで呼ぶため、
  D1 / SQLite の `expires_at` が `NULL` になり、行が恒久的に残る

結果として、

- `max_age` を送らないクライアントに対しては、**何ヶ月前のセッションでも SSO と `prompt=none` が成功し続ける**
- ID Token の `auth_time` が無期限に古いまま発行され続ける
- セッション Cookie が漏洩した場合、攻撃者は**時間的制限なしに**認可を得られる
- 永続バックエンドのセッション行が単調増加する（`subject` / `authTime` を含むため PII の滞留にもなる）

認可コード 300 秒、アクセストークン 1 時間、リフレッシュトークン 90 日と寿命を厳密に設計してきたのに、
その大元であるセッションだけ無限であり、ライフタイム設計の一貫性が欠けている。

### online refresh token の導入で影響が広がった（2026-08-25 追記）

main の「online refresh token を追加し offlineAccessAllowed を廃止」（6e2e8a4）で、
`offline_access` を伴わない Refresh Token は `RefreshTokenInfo.sessionId` で
ブラウザセッションへ束縛され、「セッションが終われば `invalid_grant`」という契約を持つようになった
（core `validateRefreshTokenSession` / 生成物 `resolvers.ts` の `authenticationSessionResolver`）。

しかしセッションに有効期限が無い現状では、この契約が発動するのは
再ログイン時の `browserSessionStore.delete()`（生成物 `routes/login.ts`）か、
ストアの明示的な削除だけになる。ブラウザを閉じて戻らない End-User のセッションは
サーバ側に生き続けるため、**online refresh token が実質 offline refresh token と同じ寿命を持つ**。
セッションの絶対有効期限は、SSO / `prompt=none` の判定だけでなく
online refresh token の失効性そのものを決めるパラメータになったので、本タスクの優先度根拠は強まっている。

なお、experimental の device authorization grant の verification ルート
（生成物 `routes/device.ts`）も `browserSessionStore.set()` でセッションを作るため、
`expiresAt` の付与はこの経路にも同時に適用する。

OIDF Basic OP の Conformance テストは短時間で完走するため、これにより FAIL することは無い。
本タスクは**認定要件ではなく、安全側の既定値の設計**として扱う。

検討詳細は `study-material/done/op-session-lifecycle-and-expiry.md` を参照。

> 関連（重複記載しない）:
> - セッションの確立と SSO: `study-material/done/cli-generated-provider-browser-session-and-sso.md`
> - 認可トランザクションの TTL: `study-material/done/auth-transaction-ttl-configuration-and-lifecycle.md`
> - Cookie 属性（HttpOnly / Secure / SameSite）: `study-material/http-security-headers-and-tls.md`
> - ログアウトプロトコル: `study-material/ext-rp-initiated-logout.md`
>
> 本タスクは**絶対有効期限と永続バックエンドの TTL** に限定する。
> アイドルタイムアウト（方針B）とローカルログアウトルート（方針C）は本タスクに含めず、
> 必要なら別タスクとして切り出す。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - `storeTemplate()` 内の `BrowserSessionInfo` / `BrowserSessionStore` / `JsonBrowserSessionStore`
  - `configTemplate()` 相当の `ProviderConfig`（`sessionAbsoluteLifetime` の追加先）
  - `routes/login.ts` を生成する箇所（`browserSessionStore.set` の呼び出し）
  - `conformance.test.ts` を生成する箇所（契約テストの追加）
- 再生成される生成物: `samples/*/src/oidc-provider/store.ts` / `config.ts` /
  `routes/login.ts` / `conformance.test.ts`
- `samples/*/src/app.ts` / `runtime.ts`（`sessionAbsoluteLifetime` を config に渡す場合）

## 仕様参照

- **OIDC Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User**:
  End-User が未認証なら OP は認証を試みなければならない（MUST）。`prompt=none` では対話してはならず、
  未認証なら `login_required` を返す。認証方法自体は仕様の範囲外だが、
  **「認証済みか否か」の判定＝セッションが生きているかの判定**は仕様上の分岐条件そのもの。
- **OIDC Core 1.0 §3.1.2.1 `max_age`**: 最後に能動的に認証されてからの経過許容秒数。
  超過していれば OP は能動的な再認証を試みなければならない（MUST）。
  → セッションに絶対有効期限を入れても、`max_age` の意味論は変わらない（両者は直交）。
- **OIDC Core 1.0 §2 `auth_time`**: End-User 認証が発生した時刻。
  セッションを期限切れにしても `auth_time` の意味は変わらず、再ログイン時に更新される。
- **NIST SP 800-63B / OWASP Session Management Cheat Sheet**（参考、規範ではない）:
  セッションには idle timeout と absolute timeout の両方を設けることを推奨。
  本タスクは absolute のみを対象とする。

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:700 付近（生成物 store.ts）
export interface BrowserSessionInfo {
  subject: string;
  authTime: number;
  // expiresAt が無い
}

export class BrowserSessionStore {
  private sessions = new Map&lt;string, BrowserSessionInfo&gt;();
  set(sessionId: string, info: BrowserSessionInfo): void { this.sessions.set(sessionId, info); }
  get(sessionId: string): BrowserSessionInfo | undefined { return this.sessions.get(sessionId); }
  // 期限判定なし。他のストア（AuthorizationCodeStore / AccessTokenStore /
  // RefreshTokenStore）はいずれも expiresAt <= now で lazy eviction している
  delete(sessionId: string): void { this.sessions.delete(sessionId); }
}
```

```ts
// packages/cli/src/frameworks/hono/templates.ts:1107 付近
class JsonBrowserSessionStore implements BrowserSessionStorage {
  async set(sessionId: string, info: BrowserSessionInfo): Promise&lt;void&gt; {
    await this.backend.put(BROWSER_SESSION_PREFIX + sessionId, info);  // ttlSeconds 未指定 → expires_at = NULL
  }
}
```

セッションを破棄する経路は `prompt=login` / `prompt=select_account` のときの
`browserSessionStore.delete()`（生成物 `routes/login.ts`）**のみ**。

## 修正方針

- [ ] `BrowserSessionInfo` に `expiresAt: number`（Unix epoch 秒）を追加する
- [ ] `BrowserSessionStore.get()` に lazy eviction を追加する。
      境界の意味論は他ストアと揃えて **`expiresAt <= now` を期限切れ**とする
      （`AuthorizationCodeStore.get` / `AccessTokenStore.get` / `RefreshTokenStore.get` と同一）
- [ ] `JsonBrowserSessionStore.set()` で `ttlUntil(info.expiresAt)` を `backend.put` に渡す。
      `JsonBrowserSessionStore.get()` にも他の Json ストアと同じ期限判定＋削除を入れる
- [ ] `ProviderConfig` に `sessionAbsoluteLifetime: number`（秒）を追加する。
      既定値は `defaultProviderConfig` に置き、JSDoc に「OP セッションの絶対有効期限。
      これを超えると SSO / `prompt=none` は成立せず再認証が必要になる」と明記する
      （既定値の候補は 12 時間 = 43200 / 24 時間 = 86400。**採用値は実装時に決定する**）
- [ ] 生成物 `routes/login.ts` の `browserSessionStore.set(sessionId, {...})` で
      `expiresAt: authTime + config.sessionAbsoluteLifetime` を渡す
- [ ] 各サンプルの `src/app.ts` / `runtime.ts` の config に `sessionAbsoluteLifetime` を明示する
      （環境変数で上書きできるようにするかは実装時に判断）
- [ ] 期限切れセッションは `SessionResolver.resolve()` が `null` を返すだけでよく、
      `resolvePromptNoneSession` 以降の core コードは無変更で `login_required` に落ちることを確認する
      （core 側の変更は不要）
- [ ] 期限切れセッションでは `AuthenticationSessionResolver.findSession()` も `null` を返し、
      束縛された online refresh token が `invalid_grant` になることを確認する
      （lazy eviction を `BrowserSessionStore.get()` に入れれば両リゾルバーが同時に満たされるはず。
      core `validateRefreshTokenSession` の変更は不要）
- [ ] 生成コード（`samples/*/src/oidc-provider/**`）を直接編集せず、
      必ず `packages/cli` のテンプレートを修正して再生成する

### 併せて検討（同一タスク内で実施するか判断）

- [ ] `JsonAuthSessionStore.set()`（ログイン→同意の受け渡し）にも TTL を渡し、
      同意画面で離脱したユーザーのエントリが回収されるようにする
      （TTL は認可トランザクションの TTL と同値が自然）
- [ ] `buildSessionCookie()` に `Max-Age=<sessionAbsoluteLifetime>` を付け、
      ブラウザ側でも期限切れ Cookie を送らないようにする（サーバ側期限が真実の情報源であることは変えない）

## テスト要件

- [ ] `BrowserSessionStore.get()` が `expiresAt <= now` のエントリに対して `undefined` を返し、
      エントリを削除することを単体テストで固定する
- [ ] 境界値: `expiresAt === now` は期限切れ、`expiresAt === now + 1` は有効
      （他ストアと同じ境界であることを明示的に検証する）
- [ ] `JsonBrowserSessionStore.set()` が `backend.put` に `ttlSeconds` を渡していることを検証する
      （モックバックエンドで引数を確認）
- [ ] 契約テスト（`conformance.test.ts` 生成コードに追加）:
  - [ ] 有効なセッションで `prompt=none` が認可コードを返すこと（既存挙動の回帰）
  - [ ] 期限切れセッションで `prompt=none` が `login_required` を返すこと
  - [ ] 期限切れセッションで通常の認可リクエストがログイン画面へリダイレクトされること
  - [ ] `sessionAbsoluteLifetime` を超えていないセッションで SSO が成立すること
  - [ ] 期限内のセッションに束縛された online refresh token の refresh が成功すること（回帰）
  - [ ] 期限切れセッションに束縛された online refresh token が `invalid_grant` になること
- [ ] `max_age` の既存挙動（`requiresReauthentication`）が回帰しないこと
- [ ] 既存の `tests/e2e` がパスすること（既定値がテスト実行時間より十分長いこと）

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` と `pnpm run test:conformance` がパスすること
- `pnpm --filter "./packages/*" test` / `pnpm run test:e2e` / `pnpm typecheck` がパスすること
- 生成物を再生成し、`samples/*/src/oidc-provider/store.ts` / `config.ts` / `routes/login.ts` /
  `conformance.test.ts` の差分がテンプレート修正に由来するものだけであること
- `sessionAbsoluteLifetime` の既定値と、その根拠（想定ユースケース）が
  `ProviderConfig` の JSDoc に記載されていること
