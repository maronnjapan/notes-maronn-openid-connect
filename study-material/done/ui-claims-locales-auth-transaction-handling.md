# `ui_locales` / `claims_locales` の AuthTransaction 欠落と OP 側ハンドリングの整備

## 1. タイトル

Authorization Request で受理した `ui_locales` / `claims_locales` パラメータが `AuthTransaction` に保持されず、ログイン UI・クレーム生成へ伝搬できない問題と、OSS 利用者が国際化（i18n）対応を実装するための拡張ポイント整備の検討。

## 2. このトピックで確認したいこと

- `validateAuthorizationRequest` は `ui_locales` / `claims_locales` を解析して `ValidatedAuthorizationRequest` に格納するが、`createAuthTransaction` が `AuthTransaction` に**転記していない**ため、後続のログイン画面・同意画面・クレーム生成からこれらの値を参照できない。これがハンドリングの抜けとして妥当か
- 比較対象として、同じく OP 側ヒント系の `login_hint` は `AuthTransaction` に保持されている（`auth-transaction.ts`）。`ui_locales` / `claims_locales` だけが落ちているのは非対称であり、設計意図か漏れかを確認したい
- OIDC Core 上これらは OPTIONAL であり、OP は処理を MAY とされる。したがって Basic OP 必須要件ではない。本トピックは「OSS 実行利用者が国際化を実装しやすくする拡張性・利便性」の論点として扱う
- 既存ファイルとの関係（重複回避）:
  - `study-material/discovery-optional-metadata-fields.md` … `ui_locales_supported` / `claims_locales_supported` という **Discovery 広告メタデータ**を扱う。本ファイルは **リクエスト側パラメータの受理後ハンドリング（transaction 保持・UI への伝搬）** に絞り、Discovery 広告の話は当該ファイルを参照するに留める
  - `study-material/resolver-and-store-contract.md` … Store/Resolver の契約一般。本ファイルは AuthTransaction の**フィールド充足**に限定
  - 仕様共通索引は `study-material/basic-op-requirements-baseline.md` を参照

## 3. 関連する仕様・基準

共通の Basic OP 仕様索引は `study-material/basic-op-requirements-baseline.md`、Discovery 広告フィールドは `study-material/discovery-optional-metadata-fields.md` を参照。本トピック固有の差分のみ記載する。

### 3.1 OIDC Core 1.0 §3.1.2.1（Authentication Request）

- `ui_locales`: OPTIONAL。End-User のログイン/同意 **UI 表示**の優先言語をスペース区切り BCP47 言語タグで指定。「OP は MAY で尊重する（its use is OPTIONAL ... MUST NOT cause an error）」。
- `claims_locales`: OPTIONAL（詳細は §5.2）。

### 3.2 OIDC Core 1.0 §5.2（Claims Languages and Scripts）

- `claims_locales`: クレーム**値**（`name`, `address` など人間可読クレーム）の優先言語。OP は対応する言語のクレーム値を返すことを試みる MAY。
- 言語タグ付きクレーム名（例 `name#ja`）の表現方法も §5.2 に定義されるが、本トピックの主眼ではない（クレーム値の i18n を実装する場合の発展論点として記録）。

### 3.3 OIDC Core 1.0 §3.1.2.1 のエラー非発生要件

- これらのパラメータは「未対応でもエラーにしてはならない（受理して無視は許容）」。本リポジトリは受理（パース）まで実施済みで、この点は満たす。論点は「受理した値を利用可能にするか」。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 — Authentication Request（`ui_locales` / `claims_locales` の定義、OP は MAY で尊重・エラー非発生）
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §5.2 — Claims Languages and Scripts（`claims_locales` のクレーム値 i18n）
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimsLanguagesAndScripts
- OpenID Connect Discovery 1.0 §3 — `ui_locales_supported` / `claims_locales_supported`（広告側は `study-material/discovery-optional-metadata-fields.md` 参照）
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata

## 5. 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - パース: L566-567 `const uiLocales = params.ui_locales; const claimsLocales = params.claims_locales;`
  - 返却: L597-598 で `ValidatedAuthorizationRequest.uiLocales` / `claimsLocales` として返す（型定義 L158-159）。
  - `loginHint` も同様にパース・返却（L569, L600 / 型 L161）。
- `packages/core/src/auth-transaction.ts`
  - `AuthTransaction` 型に保持されるフィールド: `nonce`(L95) / `maxAge`(L99) / `acrValues`(L100) / `loginHint`(L101)。
  - `createAuthTransaction` の転記: `nonce`(L197-198) / `maxAge`(L203-204) / `acrValues`(L206-207) / `loginHint`(L209-210)。
  - **`uiLocales` / `claimsLocales` はフィールドにも転記処理にも存在しない** → 受理後に破棄される。
- 結果: ログイン UI（`templates.ts` の login route）や同意画面は `transaction` を読むが、`ui_locales` を取得できないため言語切替に使えない。`claims_locales` も UserInfo/ID Token クレーム生成に渡せない。

## 6. 現在の実装との差分

| 観点 | 状態 |
|---|---|
| `ui_locales` / `claims_locales` を受理しエラーにしない（§3.1.2.1） | ✅ 満たす（パースのみ） |
| 受理した値を `AuthTransaction` に保持し UI へ伝搬 | ❌ `uiLocales` / `claimsLocales` は transaction に未保持 |
| `login_hint` との一貫性 | ⚠️ `login_hint` は保持されるが locales は落ちる（非対称） |
| 相互運用性 | ⚠️ Discovery で `ui_locales_supported` を広告しても（`discovery-optional-metadata-fields.md`）、実際にはリクエストの `ui_locales` を消費できず、広告と挙動が不整合になりうる |
| Basic OP 必須要件 | ✅ 必須ではない（OPTIONAL / MAY）。本件は拡張性・利便性の論点 |

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: CLAUDE.md は日本語 PoC を主要ユースケースに想定しており、`discovery-optional-metadata-fields.md` でも `ui_locales_supported: ["ja","en"]` を出せると分かりやすい旨が記録されている。広告（supported）と実消費（リクエスト `ui_locales`）が揃って初めて i18n が成立するが、現状は消費側が欠けている。
- **Basic OP として必須か / 拡張か**: **拡張（利便性）**。Basic OP の必須機能ではない。ただし OSS 実行利用者が「自前で多言語ログイン画面を作る」際に、core が値を transaction まで運んでくれないと利用者側で別途リクエストを再パースする必要があり、使い勝手が落ちる。
- **導入しやすさ**: 既に `ValidatedAuthorizationRequest` に値があり、`login_hint` と同じパターンで `AuthTransaction` に 2 フィールド足して転記するだけ。**極めて局所的・低リスク**。
- **既存実装との接続**: `auth-transaction.ts` の既存転記ブロック（L197-210）に追記。ログイン UI テンプレート（`templates.ts`）から `transaction.uiLocales` を読んで言語選択するサンプルを添えると利用者が拡張しやすい。
- **メリット**: 利用者が i18n ログイン UI / ローカライズドクレームを実装する際の入口が整う。Discovery 広告との整合も取れる。
- **実装しない場合の制約**: 利用者が `ui_locales` を使いたければ authorize ハンドラで生リクエストを再取得・再パースする必要があり、core の抽象（AuthTransaction で完結）を破る。`claims_locales` も同様。

## 8. 実装方針の候補（最終判断は人間）

- **方針 A: AuthTransaction にフィールド追加（最小）**
  - `AuthTransaction` に `uiLocales?: string` / `claimsLocales?: string` を追加し、`createAuthTransaction` で `login_hint` と同様に転記する。
  - 値は「OP が尊重する MAY」なので core はパススルーのみ（実際の言語選択は利用者 UI に委ねる）。
  - 長所: 低リスク、`login_hint` と一貫。短所: 実消費ロジック（UI 言語切替）は利用者任せのまま。

- **方針 B: A に加えてサンプル wiring を提供**
  - CLI 生成ログインテンプレートに `transaction.uiLocales` を読み、最初に一致する対応言語でメッセージを出す最小サンプルを添える。
  - 長所: 利用者が「ここを直せば良い」と分かる。短所: テンプレートの複雑度がわずかに増す。

- **方針 C: `claims_locales` のクレーム値 i18n まで踏み込む**
  - UserInfo/ID Token クレーム生成 resolver に `claimsLocales` を渡し、言語タグ付きクレーム（§5.2）対応の足場を作る。
  - 長所: 本格 i18n。短所: スコープ大・要設計。現時点は**検討段階**として分離推奨。

- 推奨整理: **方針 A（フィールド追加）を確実な改善として先行**し、方針 B はサンプル提供として併走可。方針 C は別トピックとして切り出すのが妥当。

## 9. タスク案

- [ ] **（A）** `AuthTransaction` 型に `uiLocales?: string` / `claimsLocales?: string` を追加する（`packages/core/src/auth-transaction.ts`）。
- [ ] **（A）** `createAuthTransaction` で `ValidatedAuthorizationRequest.uiLocales` / `claimsLocales` を `login_hint` と同じパターンで転記する。
- [ ] **（A）テスト**: `ui_locales` / `claims_locales` を含む認可リクエスト → `createAuthTransaction` の戻り値に当該フィールドが保持されることを検証する単体テストを追加する（`packages/core/src/auth-transaction.test.ts`）。未指定時に `undefined` であることも検証する。
- [ ] **（B・任意）** CLI ログインテンプレートに `transaction.uiLocales` を参照する最小サンプル（コメント付き）を追加するか検討する。
- [ ] **（C・検討段階）** `claims_locales` によるクレーム値 i18n（§5.2、言語タグ付きクレーム名）は別トピックとして分離検討する。本タスクには含めない。
