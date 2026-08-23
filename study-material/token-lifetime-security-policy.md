# トークンライフタイムとセキュリティポリシー

## 1. タイトル

アクセストークン・リフレッシュトークン・認可コード・ID Token の有効期限設定が、OAuth 2.1 / OIDC Core のセキュリティ推奨に沿っているかの確認と、改善観点の整理。

## 2. このトピックで確認したいこと

- 各トークン種別の有効期限として、OAuth 2.1 / OIDC Core が推奨・要求する基準値があるか
- 現在のデフォルト値がセキュリティ上適切かを評価する材料を整理する
- 絶対有効期限（Refresh Token の無限延長防止）や設定可能性のギャップを確認する
- 有効期限設定が Basic OP 認定に影響するか

個別タスク（`p1-refresh-token-absolute-lifetime.md`, `p2-auth-code-ttl-configurable.md`）の親トピックとして機能し、全体の設計方針の判断材料を提供する。

## 3. 関連する仕様・基準

### 3.1 各トークン種別の仕様上の扱い

#### 認可コード（Authorization Code）

- **OAuth 2.1 §4.1.2**: 認可コードは MUST で短命（short-lived）。推奨は最大 10 分。1 回のみ使用可能。
- **RFC 6749 §4.1.2**: 仕様では "should expire shortly after it is issued" とのみ記載（数値なし）。OAuth 2.1 が 10 分以内を具体化。
- 本リポジトリの現状: `packages/core/src/authorization-code.ts` の `createAuthorizationCode` は `ttlSeconds` を引数で受け取り、sample では設定可能（`p2-auth-code-ttl-configurable.md` が追跡中）。

#### アクセストークン

- **OAuth 2.1 / RFC 6749**: 有効期限の具体的数値なし。RFC 9700 §4.14 は refresh token によって access token を短命・低権限にできるという設計上の利点を説明するが、具体的な上限値は規定しない。
- **OIDC Core §15**: 言及なし（AT の形式・期限は AS の裁量）。
- **業界慣行**: 5〜60 分（典型的には 15〜30 分）。JWT AT を使う場合は即時失効が困難なため、より短い値が推奨される。Opaque AT + Introspection の場合は長めでも即時失効対応できる。
- 本リポジトリのデフォルト: `3600` 秒（1 時間）。JWT AT 使用時はやや長め。

#### ID Token

- **OIDC Core §2**: 有効期限の最小・最大値の規定なし。"SHOULD be a short time period" との記述あり。
- **実運用**: ID Token は一度使ったら再利用しない運用が多い（UserInfo で最新クレームを取得する）。10〜60 分程度が一般的。ただし OIDC Conformance Suite は期限切れの ID Token を送ることがあるため、テスト時は十分な有効期限を設定する必要がある。
- 本リポジトリのデフォルト: `3600` 秒（1 時間）。

#### リフレッシュトークン

- **OAuth 2.1 §4.3.1 / §6.1**: 特定の数値なし。Long-lived に設定してよいが、**絶対有効期限**（発行から N 日後に無効）を設けることをセキュリティ観点から推奨。
- **OAuth 2.0 Security BCP（RFC 9700）§4.14**: Public client の Refresh Token には sender constraint または rotation を要求し、一定期間利用されていない Refresh Token の失効を SHOULD とする。絶対有効期限は明示要件ではないが、無限延長を避ける防御的な実装方針として本リポジトリで検討する。
- 本リポジトリの現状: `config.refreshTokenExpiresIn = 2592000`（30 日）。ローテーション時に `issuedAt + refreshTokenExpiresIn` で毎回リセット → **無限延長** 状態。絶対有効期限の実装は 📌 `tasks/p1-refresh-token-absolute-lifetime.md` で追跡中。

### 3.2 絶対有効期限（Absolute Lifetime）と相対有効期限（Rolling Lifetime）の違い

| 種別 | 定義 | 本リポジトリの現状 |
|---|---|---|
| 相対有効期限（Rolling） | 利用（ローテーション）のたびに延長 | ✅ 現在の実装（毎回リセット） |
| 絶対有効期限（Absolute） | 初回発行から N 日後に無効（ローテーションで延長しない） | ❌ 未実装 → p1 タスク |

絶対有効期限を設けない場合、利用者が継続的にリフレッシュすることで RT は事実上永続化する。これは漏洩 RT が長期間悪用されるリスクを生む。

### 3.3 `max_age` とセッション有効期限の関係

OIDC Core §3.1.2.1: `max_age` は「最後の認証から何秒以内か」を強制する。AT / RT の有効期限と独立しており、`max_age` が切れると RT が有効であっても再認証を求めることができる。

本リポジトリは `max_age` を正しく実装済み（`done/04-max-age-enforcement.md`）。`max_age` と RT 絶対有効期限は直交する概念。

## 4. 参照資料

- OAuth 2.1 §4.1.2 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （認可コードの短命化 MUST）
- OAuth 2.1 §4.3.1 / §6.1 — 同上（RT ローテーションとセキュリティ推奨）
- OAuth 2.0 Security BCP（RFC 9700）— https://www.rfc-editor.org/rfc/rfc9700.html
  - §4.14 Refresh Token Protection（rotation、security event 時の失効、非アクティブ期限）
- RFC 6749 §4.1.2 — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2 （認可コードの短命化）
- OIDC Core 1.0 §2 — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （ID Token の有効期限）

関連する既存タスク（本ファイルでは詳細を繰り返さない）:
- 📌 `tasks/p1-refresh-token-absolute-lifetime.md` — RT 絶対有効期限の実装
- 📌 `tasks/p2-auth-code-ttl-configurable.md` — 認可コード TTL の設定可能化
- 📌 `study-material/refresh-token-rotation-replay-grace.md` — RT ローテーションの誤検知緩和

## 5. 現在の実装確認

### 5.1 設定値（`packages/sample/src/oidc-provider/config.ts`）

```typescript
export const defaultProviderConfig: ProviderConfig = {
  issuer: 'http://localhost:3000',
  accessTokenExpiresIn: 3600,       // 1時間 JWT AT
  idTokenExpiresIn: 3600,           // 1時間
  refreshTokenExpiresIn: 2592000,   // 30日（ローリング）
  accessTokenFormat: 'jwt',
};
```

### 5.2 認可コード TTL（`packages/core/src/authorization-code.ts`）

```typescript
// sample routes/authorize.ts 内
const authCodeData = await createAuthorizationCode({
  authorizationResponse: responseParams,
  subject: session.subject,
  authTime: session.authTime,
  // ttlSeconds のデフォルト = authorization-code.ts のデフォルト値
});
```

`createAuthorizationCode` は `ttlSeconds` を受け取るが、sample での呼び出しでは明示設定がない（`p2-auth-code-ttl-configurable.md` で追跡）。

### 5.3 RT の絶対有効期限

`token-request.ts` の refresh_token grant:

```typescript
// 現状: issuedAt + config.refreshTokenExpiresIn で毎回リセット
expiresAt: issuedAt + config.refreshTokenExpiresIn,
```

`RefreshTokenInfo` に `firstIssuedAt`（初回発行時刻）フィールドは存在しない。絶対有効期限を実装するには `grantId` と連動した初回発行時刻の追跡が必要（📌 `p1-refresh-token-absolute-lifetime.md` 参照）。

## 6. 現在の実装との差分

| トークン種別 | 仕様の推奨 | 現状 | 状態 |
|---|---|---|---|
| 認可コード | 最大 10 分（OAuth 2.1 §4.1.2） | デフォルト値不明（コード内固定の可能性）| 🟡 → p2 タスク |
| アクセストークン | 具体値なし。短命化で漏洩影響を縮小（RFC 9700 §4.14）| 3600 秒（1 時間）。JWT AT としてはやや長め | 🟡 利用者設定可能だが推奨値をガイドしていない |
| ID Token | 短命を推奨（Core §2）| 3600 秒。Conformance 実行時は十分な値 | ✅（設定可能） |
| リフレッシュトークン | rotation / sender constraint、非アクティブ期限（RFC 9700 §4.14）| 30 日ローリング（無限延長）| 🟡 絶対有効期限は追加防御として p1 タスクで検討 |

### 6.1 セキュリティ上のリスク

- **JWT AT が 1 時間有効**: JWT AT は発行後は即時失効できない（Revocation は Opaque AT に比べて効果がない）。漏洩時の被害ウィンドウが 1 時間になる。利用者に Opaque AT の選択肢と共にガイドする価値がある（`ProviderConfig.accessTokenFormat: 'opaque'` は実装済み）。
- **RT の無限延長**: 継続利用することで 30 日が事実上無期限化する。セキュリティ侵害（アカウント乗っ取り）の検知が遅れる。

### 6.2 相互運用性の観点

- OIDC Conformance Suite は ID Token の `exp` を確認する。有効期限が短すぎると Suite 実行中に AT が失効してテストが中断する場合がある（Suite 実行は複数リクエストを連続して行うため、数秒〜数十秒の AT 寿命は問題になる可能性がある）。

## 7. 改善・追加を検討する理由

- **PoC 開発者への安全なデフォルト**: CLAUDE.md の「非本番ガードレール」はデフォルト値が dev 前提で安全側であることを求める。JWT AT 1 時間・RT 無限延長はこの方針と緊張関係にある（PoC 環境での便利さと本番移行時の習慣化のリスク）。
- **本番導入を見据える開発者への明示ガイド**: RT の絶対有効期限不在は「本番ではどう設定すべきか」が不明瞭。ガイドドキュメントに「本番では AT を 15〜30 分、RT に絶対有効期限を設けること」を明記することが望ましい。
- **RFC 9068 との関係**: JWT AT を使う場合、有効期限短縮と Introspection / Revocation の活用が RFC 9068 Section 4（Security Considerations）の推奨。`accessTokenFormat: 'opaque'` への切り替えが最も即時失効への近道であることを利用者に示す。

## 8. 実装方針の候補

### 方針A（RT 絶対有効期限のみ実装）

`p1-refresh-token-absolute-lifetime.md` の実装を優先。AT の有効期限は利用者設定に委ねつつ、RT が無限延長しないことを保証する。

### 方針B（推奨値のドキュメント化）

コード変更なしに、`ProviderConfig` の JSDoc と README に推奨値のガイドを追記する:
- AT: 300〜1800 秒（5〜30 分）。JWT AT 使用時は特に短くすることを推奨
- ID Token: AT と同程度（300〜3600 秒）
- 認可コード: 60〜600 秒（1〜10 分）
- RT: 86400〜2592000 秒（1〜30 日）+ 絶対有効期限

### 方針C（設定バリデーションの追加）

`createProviderConfig` に有効期限の下限バリデーションを追加する（例: AT は最低 60 秒・認可コードは最大 600 秒等）。PoC 範囲では過剰かもしれないが、設定ミスの早期検知に有効。

## 9. タスク案

- [ ] 認可コードの TTL デフォルト値を確認し、`p2-auth-code-ttl-configurable.md` 実装時に仕様推奨値（最大 600 秒）を既定値として設定する
- [ ] `ProviderConfig` の各フィールドの JSDoc に推奨値と根拠（RFC/BCP セクション番号）を記載する（方針B）
- [ ] `p1-refresh-token-absolute-lifetime.md` の実装を完了させ、RT の無限延長を防ぐ
- [ ] `accessTokenFormat: 'opaque'` が JWT AT よりも即時失効で優れることを README / コメントで案内する
- [ ] Conformance Suite 実行時の AT / ID Token 有効期限要件を `study-material/basic-op-conformance-verification-plan.md` に追記する（Suite 実行中にトークンが期限切れにならない最低限の有効期限を確認）
- [ ] `ProviderConfig` への有効期限バリデーション（方針C）の導入可否を判断する
