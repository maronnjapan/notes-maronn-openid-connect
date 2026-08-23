# Refresh 再発行 ID Token の `aud` / `azp` 同一性（OIDC Core §12.2 の MUST）が multi-audience 構成で破れる

## 1. タイトル

`refresh_token` grant で再発行する ID Token の `aud` / `azp` が、初回認証時に発行した ID Token と同一であることを保証する経路が存在しない問題の確認と、保証方式の整理。

## 2. このトピックで確認したいこと

OIDC Core 1.0 §12.2 は、refresh で ID Token を返す場合に `aud` と `azp` が**初回認証時の ID Token と同じ値でなければならない（MUST）**と規定する。本リポジトリには ID Token の `aud` を複数化する公式の口（`TokenResponseOptions.idTokenAudiences`）があるが、その値は refresh token に永続化されない。したがって:

- 既定構成（`idTokenAudiences` 未使用）では `aud` は常に単一の `clientId`、`azp` は常に不在なので §12.2 は自明に成立する。
- **利用者が公開 API どおり `idTokenAudiences` を使った瞬間、authorization_code 経路と refresh 経路で `aud` の型も値も、`azp` の有無も食い違う。**

さらに、生成 OP には `RefreshTokenInfo.azp` を永続化するコードがあるが、**初回発行（authorization_code grant）では常に `undefined` を書いており、値が入る経路が無い**。つまり §12.1 / §12.2 のために用意されたフィールドが実質デッドコードになっている。

本ファイルで確認したいのは以下。

- 上記 2 点がコード上で実際に成立するか
- §12.2 の MUST に対して、どこからが違反でどこまでが「自明に成立」なのか
- `aud` / `azp` の同一性を保証する実装方式の選択肢と、そのコスト

### 既存ファイルとの差分（重複回避）

- `study-material/done/id-token-azp-claim-policy.md`
  → **発行側の `aud` / `azp` 合成ポリシー**（単一 audience なら `azp` を出さない、複数なら必ず出す）を扱い、`buildIdTokenAudience` への集約として実装済み。**refresh 経路での同一性は扱っていない**（同ファイルに `refresh` の記述は無い）。
  → 本ファイルは「合成ポリシーは正しいが、**refresh でそのポリシーへの入力が復元できない**」という差分に限定する。
- `study-material/done/refresh-id-token-nonce-omission.md`
  → §12.2 が列挙する保持対象クレームの一覧と、`nonce` がそこに含まれない件。**`aud` / `azp` が列挙されていること自体はこのファイルで確認済み**なので、条文の再掲は最小限にする。
- `tasks/done/p3-id-token-azp-single-audience-regression.md`
  → 単一 audience のとき `azp` を出さない回帰テスト。refresh 経路は対象外。
- `tasks/done/p0-refresh-acr-amr-persistence.md` / `tasks/done/T-015-acr-amr-resolver.md`
  → `acr` / `amr` の refresh 保持。**同じ §12.1 / §12.2 の要請に対する `acr` / `amr` 版の解決策**であり、本件はその `aud` / `azp` 版にあたる。実装方式の先例として参照する。

## 3. 関連する仕様・基準（このトピック固有の差分）

### 3.1 OIDC Core 1.0 §12.2 Successful Refresh Response

refresh で ID Token を返す場合の要件のうち、本件に関係するのは次の 2 点（列挙全体は `study-material/done/refresh-id-token-nonce-omission.md` §3 を参照）。

- `aud` の値は、**初回認証時に発行した ID Token と同じでなければならない（MUST）**。
- `azp` の値も、**初回認証時に発行した ID Token と同じでなければならない（MUST）**。加えて、**初回の ID Token に `azp` が無かった場合、新しい ID Token にも `azp` があってはならない（MUST NOT）**。

この 2 点は「同一性」の要求であり、値そのものの正しさ（`aud` に client_id が含まれるか等）とは別軸である。`acr` / `amr` が SHOULD 相当の保持であるのに対し、**`aud` / `azp` は MUST** である点が重要。

### 3.2 OIDC Core 1.0 §2 / §3.1.3.7 — `azp` が現れる条件

- §2: `azp`（Authorized party）は ID Token の発行先を示す。ID Token の `aud` が単一で、それが authorized party と同一の場合、`azp` は含めるべきでない（SHOULD NOT）。
- §3.1.3.7 (4)-(5): クライアントは `aud` に自身の client_id が含まれることを検証し、`aud` が複数値のときは `azp` の存在を要求する（REQUIRED）。

この 2 条から、**`aud` の要素数と `azp` の有無は連動する**。したがって §12.2 の「`aud` 同一」「`azp` 同一」は独立した 2 要件ではなく、実質「初回に決めた audience 集合を再現できること」という 1 つの要件になる。現実装の `buildIdTokenAudience` はこの連動を正しく実装しているが（`id-token-azp-claim-policy.md` 参照）、**refresh でその関数へ渡す `additional` を復元できない**。

### 3.3 OIDF Conformance Suite の `CompareIdTokenClaims`

`tasks/p3-basic-op-conformance-module-list-confirmation.md` に記録されているとおり、Suite の `CompareIdTokenClaims` は「初回 ID Token に `azp` が無ければ再発行にも `azp` があってはならない」を実装している。既定構成では `azp` が常に不在のため現状は通るが、**利用者が `idTokenAudiences` を使った生成 OP を認定にかけると、この判定で落ちる**。

> 不明点として明記: Suite が `aud` の**値の一致**まで比較するか（`azp` の有無だけか）は、Suite ソースを直接確認していないため未確定。上記の `azp` 判定は同タスクの記録に基づく既知の事実、`aud` 比較は未確認。

## 4. 参照資料

- **OpenID Connect Core 1.0**
  - §2 ID Token（`aud` / `azp` の定義）— https://openid.net/specs/openid-connect-core-1_0.html#IDToken
  - §3.1.3.7 ID Token Validation（step 4-5: `aud` / `azp` の検証）— https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
  - §12.1 / §12.2 Using Refresh Tokens / Successful Refresh Response（再発行 ID Token のクレーム要件）— https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- 本リポジトリ内（重複説明を避けるための参照先）
  - `study-material/done/id-token-azp-claim-policy.md`（発行側の合成ポリシー）
  - `study-material/done/refresh-id-token-nonce-omission.md`（§12.2 の保持対象一覧）
  - `tasks/p3-basic-op-conformance-module-list-confirmation.md`（`CompareIdTokenClaims` の挙動記録）
  - `tasks/done/p0-refresh-acr-amr-persistence.md`（`acr` / `amr` 版の先例）

## 5. 現在の実装確認

### 5.1 発行側の合成ポリシー（正しく実装されている）

`packages/core/src/token-response.ts`

```ts
// L74: 公開オプション。ID Token に client 以外の audience を足す口。
idTokenAudiences?: string[];

// L239-246: aud / azp の合成。1 件なら単一文字列 + azp なし、複数なら配列 + azp=clientId。
export function buildIdTokenAudience(input: IdTokenAudienceInput): IdTokenAudienceResult {
  const { clientId, additional } = input;
  const deduped = [...new Set([clientId, ...(additional ?? [])])];
  if (deduped.length <= 1) {
    return { aud: clientId };
  }
  return { aud: deduped, azp: clientId };
}
```

`buildIdTokenPayload`（L431-488）はこれを呼び、`aud` と（必要なら）`azp` を payload に載せる。ここまでは §2 / §3.1.3.7 に忠実。

### 5.2 永続化側: `aud` 情報が保存されない

`packages/core/src/token-request.ts` の `RefreshTokenInfo`（L173-239）が持つフィールドのうち audience 関連は次の 2 つだけ。

```ts
/** 認可時に決定された「アクセストークン」の audience。 */
audience?: string[];      // L207 — access token 用。ID Token の aud ではない。

/** Authorized Party。multiple-audience の場合に必須 (OIDC Core 1.0 Section 2)。 */
azp?: string;             // L238
```

- `audience` は**アクセストークン**の `aud`（resource indicator / UserInfo エンドポイント）であり、ID Token の `aud` とは別物。
- `idTokenAudiences` に相当するフィールドは**存在しない**。したがって refresh 時に初回の ID Token audience 集合を復元する手段が無い。

### 5.3 生成 OP: `azp` の書き込みが常に `undefined`

`packages/cli/src/frameworks/hono/templates.ts` の `refreshTokenPersistenceBlock`
→ 生成物 `samples/hono-cloudflare/src/oidc-provider/routes/token.ts:651`

```ts
azp: validatedRequest.grantType === 'refresh_token' ? validatedRequest.azp : undefined,
```

- **authorization_code grant（＝初回発行）では常に `undefined` が書かれる。**
- refresh grant では `validatedRequest.azp`（＝直前の RT に保存されていた値）を引き継ぐが、その値の出所は必ず初回発行時の `undefined` である。
- したがって `RefreshTokenInfo.azp` は**どのような構成でも `undefined` のまま**であり、`acr` / `amr` が `resolvedAcr` / `resolvedAmr` から実値を受け取っているのと対照的に、値が入る経路が無い。

### 5.4 生成 OP: refresh 時の ID Token 組み立て

同ファイル（`token.ts` の ID Token 発行ブロック）:

```ts
const idTokenPayload = buildIdTokenPayload({
  issuer: config.issuer,
  subject,
  clientId: validatedRequest.clientId,
  scope: validatedRequest.scope,
  expiresIn: config.idTokenExpiresIn,
  issuedAt,
  atHash,
  nonce,
  authTime,
  acr: resolvedAcr,
  amr: resolvedAmr,
  // ← idTokenAudiences は authorization_code / refresh のどちらでも渡されない
});
```

`idTokenAudiences` は**両経路とも渡されない**ため、生成 OP の既定出力では `aud` が常に単一の `clientId`、`azp` が常に不在になる。この範囲では §12.2 は自明に成立する。

### 5.5 破れるのは利用者が公開 API を使ったとき

生成コードは「ここに独自クレームを足せる」ことを前提にした構造（`// Add your own ID Token claims here` のコメント付き）であり、`idTokenAudiences` は core の公開オプションとして JSDoc で使い方まで説明されている。利用者が

- 生成コードの authorization_code 経路にだけ `idTokenAudiences` を足す、または
- core の `generateTokenResponse()` を直接使い `idTokenAudiences` を渡す

と、初回 ID Token は `aud: [client, extra]` / `azp: client`、refresh の ID Token は `aud: "client"` / `azp` なしとなり、**§12.2 の 2 つの MUST を同時に破る**。RP 側は §3.1.3.7 の検証で `aud` の不一致を検知しうる。

## 6. 現在の実装との差分

### 満たしていること

- 発行時点の `aud` / `azp` 合成は §2 / §3.1.3.7 に準拠している（`buildIdTokenAudience`）。
- 既定生成物（`idTokenAudiences` 未使用）では、refresh 経路でも `aud` は単一 `clientId`、`azp` は不在で、§12.2 の同一性は結果的に成立する。
- `acr` / `amr` については §12.1 / §12.2 の保持が永続化経路つきで実装済み（`resolvedAcr` / `resolvedAmr` → `RefreshTokenInfo`）。

### 不足している可能性があること

- ID Token の audience 集合を refresh へ引き継ぐ永続化フィールドが無い。`RefreshTokenInfo.audience` は access token 用であり流用できない。
- `RefreshTokenInfo.azp` は初回発行で常に `undefined` が書かれるため、値を運べない。フィールドの JSDoc（「refresh 時にも同じ値を保持する」）と実際の書き込みが矛盾している。
- `idTokenAudiences` を使うことが §12.2 違反につながる旨の警告が、JSDoc にも生成コードのコメントにも無い。

### 実装はあるが仕様上の確認が必要なこと

- 「既定構成では自明に成立する」ことを固定するテストが無い。将来 `idTokenAudiences` を生成コードから渡すよう変更されたとき、§12.2 違反に気づける仕組みが存在しない。

### セキュリティ上、改善した方がよいこと

- 直接の脆弱性ではない。ただし `aud` は ID Token の受領者を限定する主要な手段であり、refresh で `aud` が縮む（`[client, extra]` → `client`）方向の変化は、`extra` を信頼していた検証側の前提を静かに崩す。逆方向（refresh で広がる）は現状起きない。

### 相互運用性の観点で改善した方がよいこと

- §3.1.3.7 に忠実な RP は、`aud` が配列から文字列に変わったこと自体では失敗しないが、`azp` の消失を検知する実装（`aud` 複数時に `azp` 必須というルールを両方向に適用する実装）では refresh が失敗しうる。
- Suite の `CompareIdTokenClaims` は `azp` の有無の一貫性を見るため、`idTokenAudiences` を使った OP は認定で落ちる。

### Basic OP として提供する上で確認すべきこと

- **既定生成物は Basic OP 認定に影響しない**（`aud` 単一・`azp` 不在で一貫）。
- 一方、本リポジトリは「生成コードを改造して仕様を検証する」ことを利用者の入口に据えている。**改造の結果が静かに MUST 違反になる公開 API が残っている**状態は、Fidelity を掲げる方針と整合しない。

## 7. 改善・追加を検討する理由

- **なぜ入れる価値があるのか**: 本リポジトリの差別化軸は Fidelity（Conformance 準拠を信頼のシグナルにする）である。公開オプションを仕様どおりに使ったら仕様違反になる、という状態は最も避けたい種類の欠陥にあたる。しかも既定構成では露見しないため、利用者が自分で踏むまで気づけない。
- **Basic OP として必要か、拡張として有用か**: **Basic OP の必須要件ではない**（既定構成は準拠している）。ただし「拡張機能」でもなく、**既存の公開 API に対する仕様準拠の穴埋め**である。
- **現在の構成から見て導入しやすいか**: 導入しやすい。`acr` / `amr` について**まったく同じ形の解決（発行時に確定した値を `RefreshTokenInfo` に保存し、refresh 時に直接渡す）が既に実装済み**であり、その型・テンプレート・契約テストのパターンをそのまま流用できる。
- **既存実装との接続**: `GenerateTokenResponseResult` が `resolvedAcr` / `resolvedAmr` を返して呼び出し側に永続化させているのと同じ形で、確定した ID Token audience 集合を返せばよい。`buildIdTokenAudience` は既に単一の合流点になっているため、そこから取り出せる。
- **利用者・開発者・運用者のメリット**: multi-audience ID Token を PoC で試したい利用者が、refresh まで含めて仕様どおりに動く OP を得られる。何もしない利用者には影響が無い（既定挙動は不変）。
- **実装しない場合に残るリスク**: `idTokenAudiences` は core の公開 API として型と JSDoc に残り続けるため、利用者が踏み続ける。また `RefreshTokenInfo.azp` の JSDoc が実装と矛盾したままになり、生成コードを読む利用者を誤解させる。

## 8. 実装方針の候補

> **最終判断は人間が行う。以下は判断材料の整理であり、推奨の確定ではない。**

### 方針 A: 発行時に確定した ID Token audience を永続化して引き継ぐ（`acr` / `amr` と同型）

- `RefreshTokenInfo` に `idTokenAudiences?: string[]`（あるいは確定後の `idTokenAud: string | string[]` と `idTokenAzp?: string`）を追加する。
- `generateTokenResponse` / 生成コードの ID Token 発行ブロックで確定した値を呼び出し側へ返し、refresh token 永続化時に保存する。
- refresh 時は保存値を `buildIdTokenPayload` の `idTokenAudiences` へ渡す。
- 併せて `azp: ... : undefined` の初回書き込みを、実際に発行した `azp` を書くよう直す。
- メリット: §12.2 の 2 つの MUST を構造的に満たす。既存の `acr` / `amr` と同じ形なので理解コストが低い。
- コスト: `RefreshTokenInfo` の型追加、CLI テンプレートと 4 sample の再生成、`conformance.test.ts` の更新。既存ストアの旧レコードには値が無いので、`undefined` = 「単一 audience」として扱うフォールバックが要る（既定挙動と一致するため安全）。

### 方針 B: audience 集合をクライアント登録メタデータから決定論的に再計算する

- ID Token の追加 audience をリクエスト時の状態ではなく**クライアント登録の関数**と定義し、authorization_code / refresh の両経路で同じ関数を呼ぶ。
- メリット: 永続化不要。ストアのスキーマを変えずに済む。
- コスト: 「リクエストごとに audience を変える」用途を諦めることになる。現在の `idTokenAudiences` は呼び出しごとに任意の値を渡せる設計なので、公開 API の意味論を変える破壊的変更になる。登録メタデータに対応する項目（OIDC Dynamic Client Registration 1.0 に ID Token の追加 audience を表す標準メタデータは無い）を独自に定義する必要がある。

### 方針 C: multi-audience ID Token を明示的に非サポートとする

- `idTokenAudiences` を deprecated 扱いにし、生成 OP からは到達不能であることを明記する。JSDoc に「§12.2 の同一性を保証できないため refresh を伴う構成では使用しないこと」と警告を書く。
- メリット: 実装コストが最小。既定挙動も不変。
- コスト: 「最新仕様を忠実に検証できる」というコンセプトに対して機能を削る方向。`buildIdTokenAudience` の実装と `id-token-azp-claim-policy.md` の設計意図（将来 aud を複数化しても azp 付与を忘れない）を無駄にする。

### 方針 D: 方針 C を暫定採用しつつ、`azp` の書き込み矛盾だけ先に直す

- `RefreshTokenInfo.azp` の JSDoc と実装の矛盾（常に `undefined`）を、どちらかに揃える（実値を書くか、フィールドを削るか）。
- multi-audience の本格対応は方針 A として別途判断する。
- メリット: 小さく安全に着手でき、デッドコードの誤解を先に潰せる。
- コスト: §12.2 の穴自体は残る。

## 9. タスク案

- [ ] `RefreshTokenInfo.azp` の「初回発行で常に `undefined`」を確定事実としてテストで固定し、JSDoc と実装の矛盾を解消する（方針 D の前半）
- [ ] 既定生成物で「authorization_code の ID Token と refresh の ID Token の `aud` / `azp` が一致する」ことを `samples/*/conformance.test.ts` の契約テストで固定する（生成元は `packages/cli` 側を修正すること）
- [ ] `packages/core` に `buildIdTokenAudience` の出力を refresh 経路で再現できるかの単体テストを追加する
- [ ] `idTokenAudiences` を使った場合に §12.2 が破れることを JSDoc に警告として明記する
- [ ] 方針 A を採る場合: `RefreshTokenInfo` への audience フィールド追加、`GenerateTokenResponseResult` からの返却、CLI テンプレート更新、4 sample の再生成
- [ ] OIDF Conformance Suite の `CompareIdTokenClaims` が `aud` の値一致まで比較するかを Suite ソースで確認し、`tasks/p3-basic-op-conformance-module-list-confirmation.md` に追記する（現状「未確認」と明記した点の解消）
