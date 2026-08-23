# エンドユーザー認証（`authenticateUser`）の契約とクレデンシャル取り扱いの既定

## 1. タイトル

OIDC Core 1.0 §3.1.2.3 が「End-User の認証方法は本仕様の範囲外」とする以上、
エンドユーザー認証は本ライブラリの利用者責務である。しかし CLI 生成コードには
**平文パスワードを `===` で比較する `UserStore`** が既定実装として同梱されており、
「差し替えるべき境界」と「差し替えるときに満たすべき最低条件」がどこにも明示されていない。

## 2. このトピックで確認したいこと

- `authenticateUser` / `UserStore` が「開発用フィクスチャ」であることが、
  生成コードを読む利用者に伝わっているか
- 差し替える利用者が満たすべき最低条件（パスワードのハッシュ保存、定数時間比較、
  認証結果と `amr` / `acr` の対応付け、`sub` の安定性）を、契約として提示できているか
- ユーザー列挙（user enumeration）に対して、現在の生成コードがどう振る舞っているか
- どこまでを core / CLI が保証し、どこからを利用者に委ねるかの線引き

> 既存ファイルで扱っている内容は繰り返さない:
> - `client_secret` の比較・保存: `study-material/security-client-secret-handling.md`
> - Bearer クレデンシャル（認可コード / RT / opaque AT）の保存時ハッシュ化:
>   `study-material/credential-at-rest-hashing.md`
> - CSRF トークンの定数時間比較: `study-material/done/csrf-token-constant-time-comparison.md`
> - ログイン試行回数の制限とバイパス: `study-material/done/login-attempt-throttling-scope-and-reset-bypass.md`
> - レート制限・ブルートフォース・列挙攻撃の全体像: `study-material/rate-limiting-and-brute-force.md`
> - `amr` 値の標準化と `AcrResolver`: `study-material/amr-values-rfc8176.md` /
>   `study-material/amr-values-guidance-rfc8176.md`
> - `sub` の安定性と subject_types: `study-material/sub-stability-and-subject-types.md`
> - Resolver / Store の契約全般: `study-material/resolver-and-store-contract.md`
>
> 本ファイルは、上記いずれも扱っていない
> **「エンドユーザー認証そのものの差し替え境界と最低条件」**に限定する。

## 3. 関連する仕様・基準（本トピック固有の差分）

### 3.1 OIDC Core 1.0 §3.1.2.3 — 認証方法は仕様の範囲外

> The methods used by the Authorization Server to Authenticate the End-User
> (e.g. username and password, session cookies, etc.) are beyond the scope of this specification.

つまり **OIDC は「どう認証するか」を一切規定しない**。これは本ライブラリが
「認証方法を提供しない」ことの正当な根拠であると同時に、
「だからこそ利用者が自前で正しく実装できるだけの契約を示す必要がある」ということでもある。

### 3.2 認証結果と OIDC のクレームの接続点

仕様が規定しないのは「認証手段」であって、**認証結果の表現**は規定されている。

- **OIDC Core 1.0 §2 `auth_time`**: 認証が発生した時刻。生成コードは
  `Math.floor(Date.now() / 1000)` をログイン成功時に記録している。
- **OIDC Core 1.0 §2 `acr` / `amr`**: 認証コンテキストクラスと認証方式。
  `AcrResolver` で利用者が決める設計になっている（`study-material/amr-values-*.md`）。
  つまり **「どう認証したか」を `amr` に正しく反映する責任は、認証実装を差し替える利用者にある**。
- **OIDC Core 1.0 §2 / §8 `sub`**: OP 内で End-User を一意かつ**再割り当てされない**形で識別する。
  `UserStore.authenticate` が返す `user.sub` がそのまま ID Token の `sub` になるため、
  ここに可変な値（メールアドレス等）を入れると §8 の安定性要件に反する。

したがって `authenticateUser` の差し替えは、単なる「パスワード照合の置き換え」ではなく
**`sub` / `auth_time` / `amr` の 3 点を仕様どおりに満たす責務の引き受け**である。

### 3.3 クレデンシャル保存・比較の外部基準（参考）

OIDC / OAuth の仕様はパスワード保存を規定しないため、判断材料として外部基準を引く。

- **NIST SP 800-63B（Digital Identity Guidelines, Rev.3）**: memorized secret（パスワード）の
  検証者は、ソルト付きで承認済みの鍵導出関数によりハッシュ化して保存することを要求している
  （Rev.3 では §5.1.1.2 に相当。**章番号は一次資料で確認すること**）。
- **OWASP Password Storage Cheat Sheet**: Argon2id を第一推奨、次点で scrypt / bcrypt / PBKDF2。
  平文および可逆暗号での保存は不可。
- **定数時間比較**: 秘密値の比較でタイミング差を作らないこと。
  本リポジトリは `client_secret` と CSRF トークンについては `timingSafeEqual`
  （`packages/core/src/crypto-utils.ts`）で対応済み。

なお **Web 標準 API のみ**という本リポジトリの制約下では、
Argon2id / bcrypt を dependencies 無しで実装するのは現実的でない。
Web Crypto API で提供されるのは PBKDF2（`crypto.subtle.deriveBits` の `PBKDF2`）であり、
これは NIST の承認済み KDF に含まれる。**利用者へ示せる現実的な既定は PBKDF2** になる。

### 3.4 ユーザー列挙（user enumeration）

- **OWASP Authentication Cheat Sheet**: ログイン失敗時のメッセージ・レスポンス時間から
  「ユーザーが存在するか」を推測できないようにすること。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User —
  https://openid.net/specs/openid-connect-core-1_0.html#Authenticates
  （認証方法は仕様の範囲外である旨）
- OpenID Connect Core 1.0 §2 ID Token（`sub` / `auth_time` / `acr` / `amr` の定義）—
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- OpenID Connect Core 1.0 §8 Subject Identifier Types —
  https://openid.net/specs/openid-connect-core-1_0.html#SubjectIDTypes
- RFC 8176 Authentication Method Reference Values — https://www.rfc-editor.org/rfc/rfc8176.html
- NIST SP 800-63B Digital Identity Guidelines — https://pages.nist.gov/800-63-3/sp800-63b.html
  （memorized secret verifier の保存要件。**章番号は一次資料で要確認**）
- OWASP Password Storage Cheat Sheet —
  https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- OWASP Authentication Cheat Sheet —
  https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html
- W3C Web Cryptography API（`PBKDF2` の `deriveBits`）— https://www.w3.org/TR/WebCryptoAPI/

## 5. 現在の実装確認

### 5.1 差し替え口（生成物 `routes/login.ts`）

```ts
const authenticateUser =
  c.get('authenticateUser') ??
  ((u: string, p: string) => userStore.authenticate(u, p));
```

- コンテキスト経由で `authenticateUser` を注入できる（差し替え口は存在する）
- 注入しなければ既定の `UserStore` にフォールバックする

### 5.2 既定の `UserStore`（生成物 `store.ts` / `packages/cli/src/frameworks/hono/templates.ts`）

```ts
export class UserStore {
  private users = new Map<string, UserClaims & { password: string }>();
  constructor() {
    this.users.set('testuser', { sub: 'testuser', /* ...standard claims... */, password: 'password' });
    this.users.set('otheruser', { sub: 'otheruser', /* ... */, password: 'password' });
  }
  authenticate(username: string, password: string) {
    const user = this.users.get(username);
    if (user && user.password === password) return user;
    return undefined;
  }
  getClaims(sub: string): UserClaims | undefined { /* password を除いて返す */ }
}
```

- パスワードは**平文**で保持
- 比較は `===`（**定数時間ではない**）
- `JsonUserStore`（永続バックエンド版）も同じ構造で、`findOrSeed` により
  D1 / SQLite に**平文パスワードを含むユーザーレコードを書き込む**
- クラス名・コメントには「In production, replace with a database-backed user store.」とあるが、
  **「パスワードをハッシュ化せよ」「比較を定数時間にせよ」とは書かれていない**

### 5.3 ログイン失敗時の挙動（生成物 `routes/login.ts`）

```ts
const user = await authenticateUser(username, password);
if (!user) {
  const failureResult = await handleLoginFailure(transactionId, transaction, transactionStore);
  if (!failureResult.canRetry) { /* 429 */ }
  return renderView(views.loginPage({ ..., error: 'Invalid credentials', ... }));
}
```

- 未知ユーザーとパスワード誤りで**同一のメッセージ**（`Invalid credentials`）を返す
- HTTP ステータスも同一

### 5.4 認証結果の使われ方

```ts
const authTime = Math.floor(Date.now() / 1000);
await authSessionStore.set(transactionId, { subject: user.sub, authTime });
await browserSessionStore.set(sessionId, { subject: user.sub, authTime });
```

`user.sub` がそのまま `subject` として認可コード → ID Token の `sub` に流れる。
`amr` は `AcrResolver`（サンプルでは要求された `acr_values` をそのまま返し `amr: ['pwd']` を返す実装）
が別経路で決めており、**実際の認証手段とは接続されていない**。

## 6. 現在の実装との差分

満たしていること:

- ✅ 認証処理の差し替え口（`authenticateUser`）が存在し、core / ルートを触らずに差し替えられる
- ✅ ログイン失敗メッセージが未知ユーザーとパスワード誤りで同一であり、
  メッセージ経由のユーザー列挙は成立しない
  （`study-material/rate-limiting-and-brute-force.md` §5 で「未確認」とされていた論点に対する回答）
- ✅ ログイン試行回数の上限が実装されている（範囲の課題は
  `study-material/done/login-attempt-throttling-scope-and-reset-bypass.md` で追跡中）
- ✅ ログイン成功時に新しいセッション ID を採番している（セッション固定化耐性）
- ✅ `getClaims` はパスワードを除外して返す（UserInfo にパスワードが漏れない）

不足している可能性があること:

- 🟠 **「これは開発用フィクスチャである」という宣言が弱い**: 「本番ではデータベースに置き換えよ」とは
  書かれているが、「平文保存と `===` 比較はそのまま使ってはならない」とは書かれていない。
  クラス名も `UserStore` で、開発用であることが名前から読み取れない。
- 🟠 **差し替え時に満たすべき契約が文書化されていない**: `authenticateUser` の戻り値が
  `sub` を含むこと、その `sub` が OIDC Core §8 の安定性要件を満たす必要があること、
  実際の認証手段を `amr` に反映する責任が利用者にあることが、型やコメントから読み取れない。
- 🟠 **永続バックエンドに平文パスワードが書かれる**: `JsonUserStore.findOrSeed` は
  フィクスチャユーザーを D1 / SQLite に書き込む。開発用データとはいえ、
  「認証情報を平文で永続化する実装例」が生成コードとして残る。
- 🟡 **比較が定数時間でない**: 同一リポジトリ内で `client_secret` と CSRF トークンには
  `timingSafeEqual` を使っているのに、ユーザーパスワードだけ `===` という非対称がある。
  フィクスチャなので実害は無いが、利用者が模倣する既定としては望ましくない。
- 🟡 **`amr` と実際の認証手段が接続されていない**: サンプルの `AcrResolver` は
  要求された `acr_values` をそのままエコーし `amr: ['pwd']` を返す。
  コメントには「実デプロイでは実際の認証コンテキストにマップすること」と書かれているが、
  ログイン処理側（どう認証したか）と `AcrResolver`（何を主張するか）を結ぶ経路が無い。
- 🟢 **レスポンス時間による列挙**: 未知ユーザーは `Map.get` が即座に失敗するのに対し、
  既知ユーザーは文字列比較を行う。フィクスチャでは差が極小だが、
  ハッシュ検証を導入すると「未知ユーザーは速い / 既知ユーザーは遅い」という
  明確なタイミング差が生まれる（＝ダミーハッシュ検証が必要になる）。

セキュリティ上、改善した方がよいこと:

- ハッシュ検証を導入する場合、**未知ユーザーでもダミーのハッシュ検証を実行**して
  レスポンス時間を揃える必要がある。この落とし穴を契約として先に示しておく価値が高い。

相互運用性の観点:

- 本トピックは OP 内部の実装であり、プロトコル相互運用性には直接影響しない。
  ただし `amr` の値は ID Token を通じて RP に届くため、RFC 8176 の語彙に沿った値を
  返す責任が利用者にあることは相互運用性の論点である。

Basic OP として提供する上で確認すべきこと:

- OIDF Conformance Suite は「ログインできること」を要求するだけで、
  認証方式やクレデンシャル保存を検証しない。本トピックは認定要件に**影響しない**。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 生成コードは「利用者が改造して使う」ことを前提としている
  （本リポジトリの利用者入口の設計そのもの）。つまり生成コードは**手本として読まれる**。
  平文保存と `===` 比較を手本として提示している状態は、ライブラリの設計意図と食い違う。
- **Basic OP として必要か、拡張か**: どちらでもない。**生成コードの品質と責務境界の明示**の問題。
- **導入しやすさ**: 方針によって差が大きい。
  コメントと命名の改善（方針A）はコストほぼゼロ。
  PBKDF2 ベースのフィクスチャに書き換える（方針C）と、
  Web 標準 API のみで実装でき dependencies も増えないが、
  サンプル起動時のハッシュ計算コストと、`conformance.test.ts` / E2E の
  ログイン所要時間への影響を確認する必要がある。
- **既存実装との接続**: `crypto-utils.ts` に `timingSafeEqual` と `sha256` が既にあり、
  `crypto.subtle.deriveBits` は Web 標準なので追加依存なしで PBKDF2 を実装できる。
- **利用者・開発者のメリット**: 「ここまでは提供する / ここからは自分で満たす」という
  境界が明確になり、PoC から本番検証へ持ち上げるときのチェックリストになる。
- **実装しない場合のリスク**:
  - 生成コードの `UserStore` を最小改造（Map をテーブルに置換）しただけで運用に持ち込まれ、
    平文パスワードがデータベースに保存される
  - `amr` が実際の認証手段と乖離したまま RP へ届き、RP 側の認証強度判定が意味をなさなくなる
  - `sub` にメールアドレス等の可変値が入り、OIDC Core §8 の安定性要件に反する

## 8. 実装方針の候補

判断材料の整理（最終判断は人間が行う）。**本トピックは方針が未確定であり、
どの方針を採るかを決めるまではタスク化しない**。

### 方針A（命名とコメントによる契約明示、コスト最小）

- `UserStore` を `DevelopmentUserStore`（または `InMemoryDevUserStore`）に改名し、
  「開発用フィクスチャ。平文保存・非定数時間比較であり、そのまま使ってはならない」旨を
  クラス JSDoc に明記する。
- `authenticateUser` の型（または注入口のコメント）に、差し替え実装が満たすべき契約を列挙:
  - 返す `sub` は OIDC Core §8 の意味で安定・再割り当て不可であること
  - パスワードはソルト付き KDF でハッシュ保存し、検証は定数時間で行うこと
  - 未知ユーザーでもダミー検証を行い、レスポンス時間を揃えること
  - 実際に使った認証手段を `AcrResolver` に反映すること（RFC 8176 の語彙）
- 長所: 破壊的変更が改名のみ。短所: 手本としてのコードは変わらない。

### 方針B（方針A ＋ 定数時間比較だけ導入）

- フィクスチャの比較を `timingSafeEqual` に置き換える。
- 長所: 「秘密値の比較は定数時間」という規則がリポジトリ内で一貫する。
- 短所: 平文保存という本質は変わらないため、中途半端という見方もできる。

### 方針C（PBKDF2 ベースのフィクスチャに書き換える）

- フィクスチャユーザーのパスワードを `{ salt, iterations, hash }` の形で保持し、
  `crypto.subtle.deriveBits` の PBKDF2 で検証する。
- 未知ユーザー時もダミーの `deriveBits` を実行して時間を揃える。
- 長所: 生成コードが「正しい手本」になる。追加依存ゼロ（Web 標準 API のみ）。
- 短所: サンプル起動・E2E・conformance テストのログインに KDF のコストが乗る
  （反復回数を検証用に低く設定するなら、その旨をコメントで明示する必要がある）。
  フィクスチャの可読性（`password: 'password'` が一目で分かる利点）が失われるため、
  「平文をコード上に書き、起動時にハッシュ化する」形にする折衷も検討できる。

### 方針D（ログイン処理と `AcrResolver` を接続する）

- `authenticateUser` の戻り値に `amr?: string[]` / `acr?: string` を含められるようにし、
  ログイン結果を `AuthSessionStore` / `BrowserSessionStore` に保存して
  `AcrResolver` から参照できるようにする。
- 長所: 「どう認証したか」と「何を主張するか」が一致する。
- 短所: `SessionInfo` / `AuthSessionInfo` の型が広がり、core の `AcrResolver` の
  呼び出し規約にも影響し得る。`study-material/amr-values-*.md` の結論と整合を取る必要がある。

### 方針E（現状維持）

- 生成コードは変えず、README にチェックリストだけ置く。
- コストゼロだが、生成コードを直接読む利用者には届かない。

判断のポイント:

- 方針C は「正しい手本」として最も効果があるが、テスト実行時間とフィクスチャの可読性に影響する。
  反復回数を環境変数で切り替える（本番想定値 / テスト用低値）設計にできるかが鍵。
- 方針D は `amr` トピック（`study-material/amr-values-rfc8176.md` /
  `amr-values-guidance-rfc8176.md`）の結論と一体で決めるべきで、
  単独で先行させると設計が二重になる。
- 方針A は他のどの方針を採る場合でも土台として必要。

## 9. タスク案

> 方針が未確定のため、現時点では実装タスクとして切り出さない。
> 下記は方針決定後にタスク化する候補の整理。

- [ ] 方針 A〜E のどれを採るかを人間が決定する（特に方針C の是非とテスト時間への影響評価）
- [ ] 方針D を検討する場合、`study-material/amr-values-rfc8176.md` /
      `study-material/amr-values-guidance-rfc8176.md` の結論と同時に決める
      （`amr` の決定経路を二重に作らないため）
- [ ] 方針決定後にタスク化する候補:
  - [ ] `UserStore` の改名と契約 JSDoc の追加（`packages/cli/src/frameworks/hono/templates.ts`）
  - [ ] `authenticateUser` 注入口のコメントに、差し替え実装が満たすべき契約を列挙
  - [ ] フィクスチャのパスワード検証を定数時間化 / PBKDF2 化
  - [ ] 未知ユーザー時のダミー検証によるタイミング均一化
  - [ ] `JsonUserStore` が平文パスワードを永続化することの是非を再検討
- [ ] `study-material/rate-limiting-and-brute-force.md` の
      「ログイン UI のエラーメッセージがユーザー存在を区別していないか未確認」という記述を、
      本ファイル §6 の確認結果（区別していない＝問題なし）で更新するか判断する
