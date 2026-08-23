# トークン有効期限の境界条件の一貫性と Opaque アクセストークンの有効期限バインディング

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

トークンの有効期限まわりで、次の 2 つの整合性を確認する。

1. **境界演算子の不一致**: 同一関数 `validateTokenRequest` 内で、認可コードは `expiresAt <= now`（now と同値で失効）、
   リフレッシュトークンは `expiresAt < now`（now と同値ではまだ有効）と、**境界の扱いが逆**になっている。
2. **Opaque アクセストークンの有効期限バインディング**: Opaque トークンは自己記述的な `exp` を持たず、
   失効判定は store レコードに依存する。一方トークンレスポンスの `expires_in` は `config.accessTokenExpiresIn` から
   別途計算され、store に保存する `expiresAt` も別の `Date.now()` から計算される。両者がドリフトすると、
   **広告した有効期限と実際の失効時刻がずれる**余地がある。

> 関連既存ファイル：
> - `study-material/token-lifetime-security-policy.md` はライフタイム値のポリシー（長さ・回転等）を扱う。
> - `study-material/done/jwt-clock-skew-and-time-tolerance.md` は JWT 検証時の clock skew を扱う。
> - `study-material/done/05-authorization-code-ttl.md` / `tasks/done/p2-auth-code-ttl-configurable.md` は TTL の**設定可能化**。
> 本ファイルは **(1) 境界演算子の一貫性** と **(2) opaque トークンの expires_in と store expiresAt のバインド契約**という
> 固有の差分のみを扱う。

## 2. 関連する仕様・基準

- **RFC 6749 §5.1 / OAuth 2.1 §3.2.3**: `expires_in` は「アクセストークンの有効期間（秒）」。
  広告する `expires_in` は**実際の有効期限を反映**しなければ、リソースサーバとクライアントの判断がずれる。
- **RFC 7519 §4.1.4（`exp`）**: 「現在時刻が `exp` 以降（on or after）であってはならない」
  → 慣例上 `now >= exp` で失効（= `exp <= now` で失効）。JWT の `exp` 慣例に合わせるなら境界は統一すべき。
- **OAuth 2.1 §4.1.2**: 認可コードは短命であるべき。境界 1 秒の差そのものは MUST 違反ではないが、
  **同一実装内の不一致**は正しさ・保守性の欠陥。

## 3. 参照資料

- RFC 6749 §5.1（`expires_in`）: https://www.rfc-editor.org/rfc/rfc6749#section-5.1
- OAuth 2.1 §3.2.3 / §4.1.2: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 7519 §4.1.4（`exp` の on-or-after 判定）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.4

## 4. 現在の実装確認

- **境界演算子の不一致**: `packages/core/src/token-request.ts`
  - 認可コード（`:593-595`）:
    ```ts
    // RFC 7519 convention: exp <= now means expired (same as JWT exp claim)
    const now = Math.floor(Date.now() / 1000);
    if (authCode.expiresAt <= now) { throw ... } // now と同値で失効
    ```
  - リフレッシュトークン（`:493-496`）:
    ```ts
    const nowForRefresh = Math.floor(Date.now() / 1000);
    if (refreshTokenInfo.expiresAt < nowForRefresh) { throw ... } // now と同値ではまだ有効
    ```
  - 同一関数内で `<=` と `<` が混在。コメントは RFC 7519 慣例（`<=`）を謳うのに、リフレッシュ側は逆。
- **Opaque トークンの有効期限バインディング**:
  - Opaque issuer: `packages/core/src/access-token-issuer.ts:66` 付近
    ```ts
    async issue() { return generateRandomString(byteLength); } // payload（exp 含む）を捨てる
    ```
  - レスポンスの `expires_in`: `packages/core/src/token-response.ts:371` 付近で `accessTokenExpiresIn` を出力。
  - store の `expiresAt`: 生成テンプレート側（`packages/cli/src/frameworks/*/templates.ts` の token ルート）で
    `issuedAt + config.accessTokenExpiresIn` を**別の `Date.now()`** から計算。
  - JWT トークンは自己記述的な `exp` を持つため整合するが、Opaque トークンは store レコードのみが真実で、
    `expires_in` とは独立に計算されている。

## 5. 現在の実装との差分

- **満たしていること**
  - JWT アクセストークンは `exp` を内包し、広告と実態が一致。
  - 認可コード／リフレッシュとも、概ね妥当な範囲で失効判定している。
- **不足している可能性があること**
  - 境界演算子が同一関数内で不一致（`<=` と `<`）。conformance のタイミング系テストや保守時に混乱を招く。
  - Opaque トークンで `expires_in`（レスポンス）と `expiresAt`（store）が別計算のため、
    将来的なドリフト／呼び出し側の上書きで「広告と実失効のズレ」が起こりうる。
- **セキュリティ／相互運用性**
  - ズレは「広告失効前に拒否」または「広告失効後も受理」という形で表面化しうる（軽微だが不正確）。
- **Basic OP として確認すべきこと**
  - 必須テスト項目ではない。Fidelity / 保守性の観点での改善。

## 6. 改善・追加を検討する理由

- **正しさ・保守性**: 同一関数内の境界不一致は明確なコードスメル。意図せぬ 1 秒差リグレッションの温床。
- **バインディングの単一情報源**: Opaque トークンの「広告した寿命 = 保存した寿命」を構造的に保証すれば、
  リソースサーバ側の検証と齟齬が出ない。
- **導入しやすさ**: 境界統一は演算子 1 つ＋テスト。バインドは `generateTokenResponse` が計算済みの `exp`
  （`token-response.ts:291` 付近で `now + accessTokenExpiresIn`）を**返して呼び出し側に保存させる**配線で済む。
- **利用者メリット**: 生成コードをカスタムする利用者が `expiresAt` を二重計算せず、issuer 返却値をそのまま保存できる。
- **実装しない場合のリスク**: 境界不一致と二重計算が残り、タイミング起因の不具合が再発しうる。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

### 境界演算子の統一

- 方針A（推奨）: JWT `exp` 慣例に合わせ、認可コード・リフレッシュとも `expiresAt <= now` で失効に統一。
  コメントと境界秒を固定するテストを追加。
- 方針B: 逆に両方 `<` に統一。いずれにせよ「同一にする」ことが目的。

### Opaque トークンのバインディング

- 方針A（推奨）: `generateTokenResponse` が計算済みの `exp`（絶対時刻）を結果に含めて返し、
  生成テンプレートの token ルートはその値を store の `expiresAt` として保存（`Date.now()` 再計算をやめる）。
- 方針B: 現状維持＋「Opaque は store レコードが有効期限の単一情報源であり、`expires_in` と必ず一致させること」を
  型 doc / 生成コードコメントで契約として明記。

## 8. タスク案

- [ ] `validateTokenRequest` の認可コード／リフレッシュの失効境界を統一（演算子 + コメント整合）するテストを先行作成 → 実装
- [ ] `generateTokenResponse` の結果に算出済み `exp`（絶対時刻）を含め、生成テンプレートが `expiresAt` を再計算せず保存する配線を検討
- [ ] Opaque トークンで「`expires_in` と store `expiresAt` が一致する」ことの回帰テスト
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパス
