# OP ブラウザセッションのライフサイクル（有効期限・アイドルタイムアウト・終了経路）

## 1. タイトル

CLI 生成 OP が確立するブラウザ（OP）セッションに **有効期限が一切無く**、一度ログインすると
サーバ側セッションレコードが無期限に残り続ける問題。SSO / `prompt=none` / `max_age` の挙動、
Cookie 盗用時の被害範囲、ストアの肥大に直結する。

## 2. このトピックで確認したいこと

- `BrowserSessionStore`（およびその JSON バックエンド版）が保存するセッションレコードに
  絶対有効期限・アイドルタイムアウトが無いことの影響
- セッション Cookie に `Max-Age` / `Expires` を付けない現在の設計（＝ブラウザセッション Cookie）と、
  サーバ側レコードが永続することの非対称
- `auth_time` が無期限に古くなり得ることが `max_age` / `prompt=none` / ID Token の
  `auth_time` クレームにどう波及するか
- セッションを終了する経路（ローカルログアウト）が生成 OP に存在しないこと
- 中断された認可フローの `AuthSessionStore` / `AuthTransactionStore` エントリの回収

> 既存ファイルで扱っている内容は繰り返さない:
> - セッションの**確立**（Cookie 発行と SSO の実現）: `study-material/done/cli-generated-provider-browser-session-and-sso.md`
> - 認可トランザクション（`auth_txn:`）の TTL: `study-material/done/auth-transaction-ttl-configuration-and-lifecycle.md`
> - Cookie の `HttpOnly` / `Secure` / `SameSite` 属性: `study-material/http-security-headers-and-tls.md`
> - ストアの期限切れエントリ回収一般: `study-material/done/store-expired-entry-eviction-and-ttl.md`
> - `max_age=0` の境界: `study-material/done/max-age-zero-reauthentication-boundary.md`
> - RP からのログアウト**プロトコル**: `study-material/ext-rp-initiated-logout.md` /
>   `study-material/ext-oidc-session-management-1_0.md` /
>   `study-material/ext-channel-logout-notifications.md`
>
> 本ファイルは「OP 自身が持つセッションレコードの寿命と終了」に限定した差分を扱う。

## 3. 関連する仕様・基準（本トピック固有の差分）

### 3.1 OIDC Core 1.0 §3.1.2.3 — セッションは OP の裁量、ただし判定は仕様に効く

§3.1.2.3 は「End-User をどう認証するか（ユーザー名/パスワード、セッション Cookie 等）は本仕様の範囲外」
と明言する一方で、次を MUST として課している。

- End-User が未認証なら OP は認証を試みなければならない
- `prompt=login` なら既に認証済みでも再認証しなければならない
- `prompt=none` では対話してはならず、未認証なら `login_required` を返さなければならない

つまり **「認証済みか否か」の判定＝セッションが生きているか否かの判定**は、仕様上の分岐条件そのものである。
セッションの寿命を決めるポリシーは OP 実装の裁量だが、寿命を決めていないことは
「一度ログインしたら永遠に `prompt=none` が成功する OP」を意味する。

### 3.2 OIDC Core 1.0 §3.1.2.1 `max_age` / §2 `auth_time`

- `max_age`: 「End-User が最後に**能動的に**認証されてからの経過許容秒数。これを超えていれば OP は
  能動的な再認証を試みなければならない（MUST）」
- `auth_time`: 「End-User 認証が発生した時刻」。`max_age` が指定された場合、または
  クライアントが `require_auth_time=true` を登録している場合は ID Token に必須。

現実装は `authTime` をセッションに保存し `requiresReauthentication()` で比較するため、
`max_age` 付きのリクエストは正しく再認証に落ちる。**問題は `max_age` を送らないクライアント**で、
その場合はどれだけ古いセッションでも SSO が成立し、ID Token の `auth_time` は
何ヶ月も前の値のまま発行され続ける。仕様違反ではないが、OP のセキュリティポリシーとしては空白。

### 3.3 セッション有効期限に関する外部基準（参考）

OIDC / OAuth の仕様はセッション寿命の具体値を規定しないため、判断材料として外部基準を引く。

- **NIST SP 800-63B（Digital Identity Guidelines, Rev.3）**: 認証保証レベルごとの再認証間隔を規定している。
  AAL1 は最大 30 日、AAL2 は最大 12 時間かつ 30 分の非活動でのタイムアウト、AAL3 はより短い、という
  「絶対有効期限＋アイドルタイムアウト」の二段構えが基準になっている。
  （章番号は Rev.3 の §4.1.3 / §4.2.3 / §7.1–7.2 に相当すると理解しているが、
  Rev.4 で構成が変わっているため**引用時は一次資料で章番号を確認すること**）
- **OWASP Session Management Cheat Sheet**: セッションには idle timeout と absolute timeout の
  両方を設けること、ログアウトでサーバ側レコードを破棄すること（Cookie を消すだけでは不十分）を推奨。

いずれも「絶対有効期限」と「アイドルタイムアウト」を**両方**持たせる点で一致している。

### 3.4 セッション終了とトークン失効の関係（明確化）

OIDC / OAuth の仕様上、**OP セッションの終了は、発行済みアクセストークン / リフレッシュトークンを
自動的に失効させない**。RP-Initiated Logout 1.0 も「OP でのログアウト」であり、
トークン失効は OP のポリシー（SHOULD ですらない）である。

本リポジトリでは `offline_access` により RT の絶対有効期限が最長 90 日
（`refreshTokenAbsoluteLifetime`）であるため、「セッションを閉じてもオフラインアクセスは残る」
という設計になっている。これは仕様準拠だが、**利用者が誤解しやすい点なので明文化する価値がある**。
サブジェクト単位の一括失効は `study-material/subject-wide-token-invalidation-on-credential-change.md` を参照。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User —
  https://openid.net/specs/openid-connect-core-1_0.html#Authenticates
  （未認証時 MUST 認証 / `prompt=login` で MUST 再認証 / `prompt=none` で MUST 非対話）
- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`max_age` の定義）—
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §2 ID Token（`auth_time` の定義と必須条件）—
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- OpenID Connect RP-Initiated Logout 1.0 —
  https://openid.net/specs/openid-connect-rpinitiated-1_0.html
  （OP セッション終了の標準プロトコル。トークン失効は規定しない）
- NIST SP 800-63B Digital Identity Guidelines — https://pages.nist.gov/800-63-3/sp800-63b.html
  （再認証間隔・セッション管理。**章番号は一次資料で要確認**）
- OWASP Session Management Cheat Sheet —
  https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
- 本リポジトリ内: `study-material/done/cli-generated-provider-browser-session-and-sso.md`（セッション確立の経緯）

## 5. 現在の実装確認

生成物（`samples/*/src/oidc-provider/store.ts`）はすべて
`packages/cli/src/frameworks/hono/templates.ts` の `storeTemplate()` から生成される。

### 5.1 インメモリ実装（`templates.ts:700` 付近 / 生成物 `store.ts`）

```ts
export class BrowserSessionStore {
  private sessions = new Map<string, BrowserSessionInfo>();
  set(sessionId: string, info: BrowserSessionInfo): void { this.sessions.set(sessionId, info); }
  get(sessionId: string): BrowserSessionInfo | undefined { return this.sessions.get(sessionId); }
  delete(sessionId: string): void { this.sessions.delete(sessionId); }
}
```

- `BrowserSessionInfo` は `{ subject, authTime }` のみ。**有効期限フィールドが無い**。
- `get()` に期限チェックが無い（`AuthorizationCodeStore` / `AccessTokenStore` / `RefreshTokenStore` は
  いずれも `expiresAt <= now` の lazy eviction を持つのに対し、セッションだけ持たない）。

### 5.2 永続バックエンド実装（`templates.ts:1107` 付近）

```ts
class JsonBrowserSessionStore implements BrowserSessionStorage {
  async set(sessionId: string, info: BrowserSessionInfo): Promise<void> {
    await this.backend.put(BROWSER_SESSION_PREFIX + sessionId, info); // ttlSeconds 未指定
  }
}
```

`JsonStoreBackend.put(key, value, ttlSeconds?)` は `ttlSeconds` 省略時に `expires_at = NULL` を書く
（`samples/hono-cloudflare/src/storage.ts` の D1 実装、`samples/nextjs-vercel/src/app/_oidc-provider/storage-backend.ts`
の SQLite 実装ともに同じ）。したがって **D1 / SQLite 上のセッション行は恒久的に残る**。

同じことが `JsonAuthSessionStore`（`templates.ts:1091` 付近、ログイン→同意の受け渡し）にも当てはまる。
こちらは同意完了・拒否時に `delete` されるが、**ユーザーが同意画面を閉じて離脱した場合は残る**。

### 5.3 Cookie（`templates.ts:740` 付近）

```ts
export function buildSessionCookie(sessionId: string): string {
  return SESSION_COOKIE_NAME + '=' + sessionId + '; HttpOnly; Secure; SameSite=Lax; Path=/';
}
```

`Max-Age` / `Expires` が無いためブラウザ的には「セッション Cookie」だが、
主要ブラウザのセッション復元機能でブラウザ再起動後も送出され得る。
いずれにせよ **サーバ側の寿命が無いことが本質**であり、Cookie 属性だけでは制御できない。

### 5.4 セッション更新・破棄経路

- 発行: `routes/login.ts` の POST ハンドラで毎回**新しい** `sessionId` を採番して `Set-Cookie`
  （セッション固定化に対しては正しい実装）
- 破棄: `prompt=login` / `prompt=select_account` のときだけ、直前の `sessionId` を
  `browserSessionStore.delete()`（`routes/login.ts`）
- **それ以外に破棄する経路が無い**。ローカルログアウト用のルートが生成されない。
- SSO 再利用時（`routes/authorize.ts`）はセッションを読むだけで `authTime` を更新しない
  （これは `auth_time` の意味上、正しい）。

## 6. 現在の実装との差分

満たしていること:

- ✅ ログイン成功のたびに新しい `sessionId` を採番しており、セッション固定化（session fixation）耐性がある
- ✅ `prompt=login` / `prompt=select_account` で既存セッションを明示破棄する
- ✅ `max_age` 付きリクエストは `requiresReauthentication()` により正しく再認証へ落ちる
- ✅ `HttpOnly` / `Secure` / `SameSite=Lax` は付与済み

不足している可能性があること:

- 🔴 **セッションの絶対有効期限が無い**: `BrowserSessionInfo` に `expiresAt` 相当が無く、
  `get()` にも期限判定が無い。`max_age` を送らないクライアントに対しては、
  何ヶ月前のセッションでも SSO と `prompt=none` が成功し続ける。
- 🔴 **アイドル（非活動）タイムアウトが無い**: 最終利用時刻を記録していないため、
  「30 分使われていないセッションを閉じる」というポリシーを表現できない。
  Refresh Token 側にはアイドルタイムアウトの検討（`study-material/done/refresh-token-idle-inactivity-timeout.md`）
  があるのに、セッション側だけ非対称。
- 🟠 **永続バックエンドのセッション行が TTL 無しで書かれる**: `JsonBrowserSessionStore.set` /
  `JsonAuthSessionStore.set` が `ttlSeconds` を渡さないため、D1 / SQLite の `expires_at` が `NULL` になり、
  行が無期限に蓄積する。他のストア（code / AT / RT / transaction）は `ttlUntil()` で TTL を渡しており非対称。
- 🟠 **ローカルログアウト経路が無い**: 生成 OP には「このブラウザのセッションを終了する」手段が無い。
  Cookie を手で消す以外にセッションを閉じられないため、共用端末での PoC 検証ができず、
  RP-Initiated Logout（`ext-rp-initiated-logout.md`）を実装する際の土台も無い。
- 🟡 **中断フローの `auth-session:` エントリが残る**: 同意画面で離脱したユーザーの
  `AuthSessionStore` エントリに TTL が無く回収されない（`subject` / `authTime` を含むため軽微な PII 滞留）。

セキュリティ上、改善した方がよいこと:

- セッション Cookie が漏洩した場合（XSS は `HttpOnly` で緩和されるが、端末奪取・バックアップ・
  マルウェアなど経路は残る）、**有効期限が無いため攻撃者は無期限に SSO と `prompt=none` を通せる**。
  絶対有効期限は「漏洩の時間的封じ込め」として RT の絶対有効期限と同じ役割を果たす。
- `auth_time` の陳腐化は、RP が `max_age` を送らない限り検知できない。OP 側の上限があれば
  「OP が保証する認証鮮度の上限」を Discovery やドキュメントで説明できる。

相互運用性の観点で改善した方がよいこと:

- 商用 IdP（Auth0 / Okta / Keycloak / Entra ID）はいずれも OP セッションに
  「idle timeout」「absolute/max lifetime」の 2 値を持ち、管理画面で設定できる。
  本 OSS の想定ユーザー（IdaaS 移行前の PoC）が同じ観点で比較検証できることに価値がある。

Basic OP として提供する上で確認すべきこと:

- OIDF Conformance Suite の Basic OP テストは短時間で完走するため、セッション寿命が無いことで
  **FAIL することは無い**（`oidcc-prompt-none-logged-in` / `oidcc-max-age-*` は現状で通る想定）。
  したがって本トピックは「認定の必須要件」ではなく、**セキュリティ既定値の設計**として扱う。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: セッション寿命は「OP が発行するすべての認可の起点」の寿命である。
  認可コード 5 分、AT 1 時間、RT 90 日と寿命を厳密に設計してきたのに、その大元である
  セッションだけ無限なのは、ライフタイム設計全体の一貫性が欠けた状態と言える。
- **Basic OP として必要か、拡張か**: Basic OP 認定の必須要件では**ない**。
  ただし `prompt=none` / `max_age` / SSO という Basic OP の中核挙動の入力値を決めるため、
  「認定は通るが実運用では危ない既定値」を放置しないという意味で優先度は高い。
- **導入しやすさ**: 高い。既に `AuthorizationCodeStore` / `AccessTokenStore` / `RefreshTokenStore` が
  `expiresAt` ＋ lazy eviction のパターンを持っており、`BrowserSessionInfo` に同じ形を足すだけで揃う。
  `ProviderConfig` にも `authorizationCodeTtl` / `refreshTokenAbsoluteLifetime` という前例がある。
- **既存実装との接続**: `SessionResolver.resolve(request)` が `SessionInfo | null` を返す契約なので、
  期限切れセッションは `null` を返すだけでよく、`resolvePromptNoneSession` 以降のコードは無変更で
  `login_required` に落ちる。core 側の変更は不要。
- **利用者メリット**: セッション寿命という「IdaaS で必ず設定する項目」を本 OSS でも同じ語彙
  （idle / absolute）で試せる。移行検証のギャップが減る。
- **実装しない場合のリスク**: 生成コードをそのまま本番寄りに持ち込んだ利用者が、
  無期限セッションの OP をデプロイする。Cookie 漏洩時の被害が時間的に無制限になる。
  D1 / SQLite のセッション行が単調増加する。

## 8. 実装方針の候補

判断材料の整理（最終判断は人間が行う）。

### 方針A（絶対有効期限のみ、最小）

- `BrowserSessionInfo` に `expiresAt: number` を追加。
- `ProviderConfig` に `sessionAbsoluteLifetime`（既定値の候補: 12 時間 = 43200 秒 / 24 時間 / 30 日）を追加。
- `BrowserSessionStore.get()` に lazy eviction（`expiresAt <= now` なら delete して undefined）。
- `JsonBrowserSessionStore.set()` は `ttlUntil(info.expiresAt)` を `backend.put` に渡す。
- 影響範囲が小さく、既存の他ストアと完全に同じパターン。後方互換の破壊は
  `BrowserSessionInfo` の型追加のみ（生成コードを改造済みの利用者は `expiresAt` の付与が必要）。

### 方針B（方針A ＋ アイドルタイムアウト）

- `BrowserSessionInfo` に `lastUsedAt` を追加し、`SessionResolver.resolve` 内で更新。
- `ProviderConfig` に `sessionIdleTimeout`（既定候補: 30 分 / 未設定なら無効）を追加。
- Refresh Token 側の `validateRefreshTokenIdleTimeout` と同じ意味論（`now - lastUsedAt > timeout` で失効、
  境界値は有効）に揃えると、利用者が学ぶ規則が 1 つで済む。
- 代償: 認可リクエストのたびにセッションへ書き込みが発生する（D1 / KV では 1 write 増）。
  読み取り専用で済んでいた `SessionResolver` の契約が変わるため、
  `study-material/resolver-and-store-contract.md` の更新が必要。

### 方針C（方針A ＋ ローカルログアウトルート）

- `/logout`（OP 内部の GET/POST）を生成し、CSRF トークン付きの確認画面 → セッション破棄 →
  `Set-Cookie` の失効（`Max-Age=0`）を行う。
- RP-Initiated Logout（`ext-rp-initiated-logout.md`）を将来入れる際の土台になる。
  `end_session_endpoint` はこのローカルログアウトの上に `id_token_hint` /
  `post_logout_redirect_uri` の検証を足す形で実装できる。
- 代償: ルートとビューが 1 つ増える。Discovery には出さない（`end_session_endpoint` は
  RP-Initiated Logout 実装時に初めて広告する）。

### 方針D（Cookie にも `Max-Age` を付ける）

- `buildSessionCookie` に `Max-Age=<sessionAbsoluteLifetime>` を付け、サーバ側の期限と揃える。
- サーバ側期限が真実の情報源であることは変わらないが、ブラウザ側でも古い Cookie を送らなくなる。
- 方針A と組み合わせる前提。単独では意味が薄い。

### 方針E（現状維持＋ドキュメント）

- コードは変えず、生成コードのコメントと README に
  「このセッションストアには有効期限が無い。本番相当の検証をする場合は `expiresAt` を足すこと」を明記する。
- コストゼロだが、「安全側の既定値を提供する」という本リポジトリの方針とは逆行する。

判断のポイント:

- 既定値をどう置くか（無効＝現状維持を既定にするか、12〜24 時間を既定にするか）。
  既定を有効にすると、既存の E2E / conformance テストの実行時間内では影響が無い一方、
  生成コードを改造済みの利用者には破壊的変更になり得る。
- 方針B は「毎リクエスト書き込み」のコストがエッジ環境（D1 / KV）で無視できない可能性があり、
  `sessionIdleTimeout` 未設定時は書き込みをスキップする設計にできるかを検討する必要がある。

## 9. タスク案

- [ ] 方針 A〜E のどれを採るか、および既定値（絶対有効期限 / アイドルタイムアウト）を人間が決定する
- [ ] 方針A採用時:
  - [ ] `packages/cli/src/frameworks/hono/templates.ts` の `BrowserSessionInfo` に `expiresAt` を追加
  - [ ] `BrowserSessionStore.get()` に lazy eviction を追加（他ストアと同じ `expiresAt <= now` 意味論）
  - [ ] `JsonBrowserSessionStore.set()` で `ttlUntil(info.expiresAt)` を `backend.put` に渡す
  - [ ] `ProviderConfig` に `sessionAbsoluteLifetime` を追加し、`routes/login.ts` の
        `browserSessionStore.set` で `expiresAt` を計算して渡す
  - [ ] 各 sample の `conformance.test.ts` を生成する CLI 側コードに、期限切れセッションで
        `prompt=none` が `login_required` になる契約テストを追加
- [ ] 方針B採用時:
  - [ ] `lastUsedAt` の更新箇所（`SessionResolver.resolve` か authorize ルートか）を決める
  - [ ] `validateRefreshTokenIdleTimeout` と同じ境界意味論であることを単体テストで固定
  - [ ] `study-material/resolver-and-store-contract.md` に「resolve は書き込みを伴い得る」旨を追記
- [ ] 方針C採用時:
  - [ ] `/logout` ルート・ビューをテンプレートに追加（CSRF トークン必須、GET は確認画面のみ）
  - [ ] `Set-Cookie: session_id=; Max-Age=0` でブラウザ側 Cookie も失効させる
  - [ ] `study-material/ext-rp-initiated-logout.md` に「ローカルログアウトを土台にする」旨を追記
- [ ] `JsonAuthSessionStore.set` にも TTL（認可トランザクション TTL と同値）を渡し、
      中断フローのエントリが回収されるようにするかを判断する
- [ ] 「OP セッションを閉じても発行済み AT / RT は失効しない」ことを README または
      生成コードのコメントに明記する（仕様上の事実であり、利用者が最も誤解しやすい点）
