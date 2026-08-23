# トークン値の生成（minting）抽象の非対称：`AccessTokenIssuer` はあるが Refresh Token / Authorization Code には無い

## 1. このトピックで確認したいこと

`packages/core` は **アクセストークンの発行形式**を差し替えるための抽象 `AccessTokenIssuer`（JWT / Opaque）を公開している。
一方で、同じく「OP が発行する Bearer 相当のクレデンシャル」である

- Refresh Token
- Authorization Code
- `grantId`

の値は、いずれも `generateRandomString(32)` を **呼び出し箇所に直接ハードコード**して生成している。
本ファイルでは、この非対称が意図的な設計なのか、拡張点の抜けなのかを整理し、
「値の生成（minting）」を抽象化した場合に何が可能になり、何が壊れるかの判断材料をまとめる。

> 「生成した値をストアへどう保存するか（平文 vs ハッシュ）」は `study-material/credential-at-rest-hashing.md` が扱う。
> 本ファイルは **値を作る側の拡張点**に限定する。両者は「minting 抽象があれば at-rest ハッシュ化が差し込みやすくなる」
> という依存関係にあり、その接続だけを本ファイルで述べる。

## 2. 関連する仕様・基準

共通の Refresh Token / 認可コードの仕様説明は `study-material/basic-op-requirement-traceability.md` §3.3 の索引と
既存トピック（`refresh-token-rotation-replay-grace.md` 等）を参照し、ここでは **値そのものに対する要件**だけを挙げる。

### 2.1 値のエントロピーに対する要件

- **RFC 6749 §10.10 (Credentials-Guessing Attacks)**: 「ハンドル」（認可コード・アクセストークン・リフレッシュトークン）の
  推測確率は **2^-128 以下でなければならず（MUST）、2^-160 以下であるべき（SHOULD）**。
  さらに値は暗号学的に安全な擬似乱数生成器で作られなければならない。
- 現行の `generateRandomString(32)` は 32 バイト = 256 ビットの CSPRNG 出力であり、この要件を満たす。
  **したがって現状にエントロピー上の欠陥は無い**。本ファイルの論点はセキュリティ欠陥ではなく拡張性である。

### 2.2 値の「形」に要件が生じる拡張仕様

将来の拡張を入れる際、トークン値そのものの生成方法に制約が生じる。

- **RFC 9449 (DPoP)** / **RFC 8705 (mTLS, certificate-bound tokens)**: sender-constrained token では、
  アクセストークンに `cnf` クレームを載せる（JWT の場合）か、ストア側で束縛情報を保持する必要がある。
  リフレッシュトークンも public client では sender-constrain するか rotation するかの二択（OAuth 2.1 §4.3.1）。
- **RFC 9068 (JWT Profile for Access Tokens)**: アクセストークンを JWT にする場合の要件。
  既に `createJwtAccessTokenIssuer` が対応している。
- **運用上の要件（仕様外）**: トークン値へのプレフィックス付与（GitHub の `ghp_` 相当）、
  マルチテナントのテナント ID 埋め込み、シャーディングキーの埋め込みなど。これらは仕様ではないが、
  本番運用の秘密情報スキャンやルーティングで広く使われる。

### 2.3 本リポジトリの設計方針

- CLAUDE.md「`core` はロジック層（高度な組み込みユースケース向け）」——差し替え可能な拡張点を持つことが
  `core` の価値になる。
- 生成コードは「ステップ関数を消したり足したりできる」形で出力される。つまり **拡張は生成コード側で行う**という
  設計思想も同時に存在する。この 2 つのどちらを minting に適用するかが本ファイルの判断ポイントである。

## 3. 参照資料

- RFC 6749 §10.10 Credentials-Guessing Attacks — https://datatracker.ietf.org/doc/html/rfc6749#section-10.10
  （2^-128 MUST / 2^-160 SHOULD、CSPRNG 要求の根拠）
- OAuth 2.1 draft §4.3.1（public client の refresh token は sender-constrained または rotation）— https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 9449 OAuth 2.0 Demonstrating Proof of Possession (DPoP) — https://datatracker.ietf.org/doc/html/rfc9449
- RFC 8705 OAuth 2.0 Mutual-TLS Client Authentication and Certificate-Bound Access Tokens — https://datatracker.ietf.org/doc/html/rfc8705
- RFC 9068 JWT Profile for OAuth 2.0 Access Tokens — https://datatracker.ietf.org/doc/html/rfc9068
- 本リポジトリ `packages/core/src/access-token-issuer.ts`（既存の抽象）
- 本リポジトリ `packages/core/src/token-response.ts:587`、`packages/core/src/authorization-code.ts:90-91`
- 本リポジトリ `packages/cli/src/frameworks/hono/templates.ts`（`refreshTokenValueExpression`）

## 4. 現在の実装確認

### 4.1 アクセストークンだけが抽象化されている

```ts
// packages/core/src/access-token-issuer.ts
export interface AccessTokenIssuer {
  readonly format: AccessTokenFormat;      // 'jwt' | 'opaque'
  issue(ctx: AccessTokenIssuanceContext): Promise<string>;
}
export function createJwtAccessTokenIssuer(): AccessTokenIssuer;
export function createOpaqueAccessTokenIssuer(byteLength = 32): AccessTokenIssuer;
```

`generateTokenResponse` は `options.accessTokenIssuer ?? createJwtAccessTokenIssuer()` で注入を受け付ける
（`packages/core/src/token-response.ts:529`）。生成コードも `config.accessTokenFormat` で切り替える。

### 4.2 Refresh Token はハードコード

```ts
// packages/core/src/token-response.ts:580-591（generateTokenResponse の戻り値）
return {
  response: {
    access_token: accessToken,
    ...
    refresh_token: issueRefreshToken ? generateRandomString(32) : undefined,
  },
  ...
};
```

- 注入点が無い。`TokenResponseOptions` には `accessTokenIssuer` はあるが `refreshTokenIssuer` に相当するものが無い。
- CLI 生成コードは `generateTokenResponse` を使わずステップ関数を並べる形だが、そちらでも同じくハードコードである:

```ts
// packages/cli/src/frameworks/hono/templates.ts（refreshTokenValueExpression）
refresh_token: grantHasOfflineAccess ? generateRandomString(32) : undefined,
```

つまり **core 側の合成 API と生成コードの両方に、同じリテラルが独立して存在する**。

### 4.3 Authorization Code / grantId もハードコード

```ts
// packages/core/src/authorization-code.ts:90-91
const code = generateRandomString(32);
const grantId = generateRandomString(32);
```

`CreateAuthorizationCodeOptions` に値生成の差し替え点は無い。

### 4.4 結果として生じている状態

| 発行物 | 値の生成 | 差し替え可能か | 形式の選択肢 |
|---|---|---|---|
| Access Token | `AccessTokenIssuer.issue()` | ✅ 注入可 | JWT / Opaque |
| Refresh Token | `generateRandomString(32)` リテラル（2 箇所） | ❌ | Opaque のみ |
| Authorization Code | `generateRandomString(32)` リテラル | ❌ | Opaque のみ |
| `grantId` | `generateRandomString(32)` リテラル | ❌ | Opaque のみ |

## 5. 現在の実装との差分

満たしていること:

- ✅ **RFC 6749 §10.10 のエントロピー要件は全て満たしている**（256 ビット CSPRNG）。仕様違反ではない。
- ✅ アクセストークンについては形式選択の拡張点があり、Opaque 選択時の失効即時性という運用要件に応えられる。
- ✅ 認可コード / リフレッシュトークンを Opaque に固定していること自体は、
  「即時失効が効く」「JWT の巨大化を避ける」という点でむしろ安全側の既定である。

不足している可能性があること:

- 🟡 **拡張点の非対称が説明されていない**。なぜアクセストークンだけ抽象化したのかがコード上に記述されていない。
  `access-token-issuer.ts` の冒頭コメントは「Opaque は RFC 7662 / RFC 7009 と相性が良い」と述べるが、
  「なぜ RT / code には同じ抽象を用意しないのか」には触れていない。
- 🟡 **同じリテラルが core と生成テンプレートに二重に存在する**。将来バイト長やアルファベットを変える判断をした場合、
  片方だけ変更する事故が起こり得る。少なくとも定数（例: `DEFAULT_TOKEN_ENTROPY_BYTES`）として一元化する余地がある。
- 🟡 **at-rest ハッシュ化（`credential-at-rest-hashing.md`）の実装難度が上がる**。
  ハッシュ化は「値を作る場所」と「保存する場所」の両方に触る必要があるが、値を作る場所が
  core の合成 API とテンプレートに分散しているため、差し込み点が 1 箇所に定まらない。
- 🟡 **sender-constrained refresh token（DPoP / mTLS）を入れる際の接続先が無い**。
  `tasks/T-019-dpop.md` を実装する段階で、リフレッシュトークンに束縛情報を持たせるなら
  「値の生成 + メタデータの付与」をまとめて扱える場所が要る。現状はテンプレートを直接書き換えることになる。

セキュリティ上、改善した方がよいこと:

- 🟢 現時点で具体的な脆弱性は無い。**本トピックはセキュリティ課題ではなく拡張性課題**である点を明確にしておく。
- 🟡 ただし「値の生成箇所が分散している」こと自体は、将来の変更で片方だけ弱くなる（例: バイト長を減らす）
  リグレッションの余地を残す。定数の一元化はこのリスクを消す。

相互運用性の観点:

- 🟢 トークン値は OP 内部でのみ意味を持つ不透明文字列であり、RP との相互運用に影響しない。
  ただし `refresh_token` / `code` の長さが極端に長い場合に古い RP が切り詰めるという実務上の問題は存在する。
  現行 43 文字（32 バイトの base64url）は実用上問題ない範囲。

Basic OP として提供する上で確認すべきこと:

- 🟢 Basic OP 認定要件に minting 抽象の有無は含まれない。認定可否には影響しない。

## 6. 改善・追加を検討する理由

**なぜ価値があるのか**

- `core` の売りは「高度な組み込みユースケース向けのロジック層」であり、
  本番運用でよくある要件（トークンプレフィックス、テナント埋め込み、at-rest ハッシュ、sender-constrain）に
  対して拡張点を持つことが直接の価値になる。
- 逆に「拡張点を増やしすぎると API 表面が膨らみ、利用者が読むべき型が増える」というコストもある。
  本リポジトリは既に `core` の export が 100 を超えており、**追加する前にコスト側を評価すべき段階**にある。

**Basic OP 必須か、拡張として有用か**

- 拡張として有用。Basic OP には不要。したがって v0.x のリリースブロッカーではない
  （`study-material/RELEASE-v0.x-scope.md` の Tier 分類上は後回しでよい）。

**現在の構成から見た導入しやすさ**

- 🟢 型の追加自体は容易（`AccessTokenIssuer` と同形の小さなインターフェース）。
- 🟡 **注入経路が 2 系統ある**のが難所。core の `generateTokenResponse`（後方互換 API）と、
  CLI 生成コードのステップ関数列の両方に注入点を作ると、利用者から見て「どちらで設定するのか」が分かりにくくなる。
- 🟡 生成テンプレートを変えると 4 フレームワーク分の期待出力テストと 4 サンプルの `conformance.test.ts` 生成元に波及する。

**既存実装との接続**

- `AccessTokenIssuer` と同じ形にすれば、`generateTokenResponse` の options に 1 フィールド足すだけで済む。
- `credential-at-rest-hashing.md` の方針が「保存時にハッシュ」なら minting 抽象は不要（保存側で完結する）。
  「クライアントへ返す値と保存する値を別にする（例: `id.secret` 形式）」なら minting 抽象がほぼ必須になる。
  **したがって本トピックの要否は at-rest ハッシュ化の方針決定に従属する。**
- `tasks/T-019-dpop.md`（DPoP）を実装する場合、RT の束縛情報保存が必要になるため接続点になる。

**利用者・開発者・運用者のメリット**

- 秘密情報スキャン（GitHub Secret Scanning など）に引っかかるプレフィックス付きトークンを発行できる。
- マルチインスタンス／マルチテナントでのルーティングやシャーディングをトークン値だけで判断できる。
- at-rest ハッシュ化を「生成コードを書き換えずに」導入できる。

**実装しない場合に残る制約・リスク**

- 上記の運用要件を持つ利用者は、生成コードのテンプレート出力を直接書き換えることになる。
  これは `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` が指摘する
  「再生成で失われる改造」を増やす方向に働く。
- リテラルの二重管理が残り、将来のエントロピー変更でリグレッションの余地が残る。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 現状維持 + 意図の明文化（最小）

- `access-token-issuer.ts` に「RT / code / grantId は意図的に Opaque 固定（即時失効性を優先）」というコメントを追加。
- `generateRandomString(32)` の `32` を core の共有定数（例: `DEFAULT_CREDENTIAL_ENTROPY_BYTES = 32`）へ切り出し、
  core とテンプレートの両方がそれを参照するようにする。RFC 6749 §10.10 の根拠を定数の JSDoc に書く。
- 利点: API 表面を増やさずリグレッション余地だけ消せる。コストが最小。
- 欠点: 拡張要件は満たさない。

### 方針B: `CredentialIssuer` 1 本で統一

- `AccessTokenIssuer` を一般化した `CredentialIssuer`（`issue(purpose, ctx): Promise<string>` 等）を導入し、
  RT / code / grantId / access token を同じ抽象で扱う。
- 利点: 概念が 1 つで済む。at-rest ハッシュ化・プレフィックス・DPoP のいずれにも 1 箇所で対応できる。
- 欠点: 既存 `AccessTokenIssuer` の破壊的変更になる（`format: 'jwt' | 'opaque'` という概念が
  RT / code には無意味であるため、そのまま一般化できない）。メジャーバージョンの区切りが要る。

### 方針C: `RefreshTokenIssuer` だけ追加（範囲限定）

- RT のみ差し替え可能にする（`TokenResponseOptions.refreshTokenIssuer`）。code / grantId は据え置き。
- 利点: DPoP / sender-constrained RT の要件に的を絞れる。破壊的変更にならない（optional 追加）。
- 欠点: 非対称がさらに増える（access / refresh は抽象あり、code は無し）。

### 方針D: 抽象化せず「生成コード側で差し替える」を公式手順にする

- core には手を入れず、生成テンプレートの該当行にコメントで
  「トークン値の形式を変えたい場合はここを書き換える」と明記し、ドキュメントに手順を書く。
- 利点: API 表面ゼロ。生成コード方式の思想と一貫する。
- 欠点: 再生成で失われる。`credential-at-rest-hashing.md` の実装が利用者任せになる。

**判断材料の要約**

- 方針A は他のどの方針を採る場合にも先に入れてよい（定数一元化は独立して有益）。
- 方針 B/C/D の選択は **`credential-at-rest-hashing.md` の方針決定と DPoP の実装判断に従属する**。
  それらが決まる前に minting 抽象だけ先に入れると、後から形が合わずに二重の抽象を抱えるおそれがある。
- したがって本ファイルは **方針A のみを先行タスク候補**とし、B/C/D はタスク化しない。

## 8. タスク案

**タスク化するもの（方針A の一部）**

- [ ] `generateRandomString(32)` の `32` を core の共有定数へ切り出し、RFC 6749 §10.10 を JSDoc に明記する
- [ ] CLI テンプレート側もその定数を参照する形に揃え、リテラルの二重管理を解消する
- [ ] `access-token-issuer.ts` に「RT / code / grantId を Opaque 固定としている理由」を明記する

**タスク化しないもの（方針決定待ち）**

- 方針 B / C / D の選択は、`credential-at-rest-hashing.md` の保存方式決定と `tasks/T-019-dpop.md` の
  実装判断の後に行う。順序が逆になると抽象の形が決められない。

## 関連トピック

- `study-material/credential-at-rest-hashing.md` — 保存側（at-rest）の話。本ファイルは生成側。方針決定の順序で本ファイルが従属する。
- `tasks/T-019-dpop.md` — sender-constrained token。RT 側の束縛情報を持たせる際の接続点。
- `study-material/refresh-token-rotation-replay-grace.md` / `study-material/refresh-token-public-client-rotation-enforcement.md`
  — RT のライフサイクル側。値の生成方法とは独立。
- `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` — 方針D を採った場合に増える改造が失われる問題。
