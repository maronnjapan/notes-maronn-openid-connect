# `redirect_uri` の必須化：OIDC Core §3.1.2.1（登録 1 件時の省略許容が仕様と乖離）

## ステータス

🟡 Medium / 未着手（方針未確定 = 検討中）

## 1. このトピックで確認したいこと

認可エンドポイントで **`redirect_uri` パラメータが省略された**ときの挙動を確認する。具体的には:

- 現状は「登録済み redirect_uri が **1 件だけ**なら `redirect_uri` を省略してもよい」という
  OAuth 2.0 由来の緩い挙動を取っている（`resolveRedirectUri`）。
- 一方 **OpenID Connect Core 1.0 §3.1.2.1 は Authentication Request の `redirect_uri` を
  REQUIRED として定義**しており、OAuth 2.0（RFC 6749 §3.1.2.3 では条件付き/任意）より厳格である。
- 本ライブラリは「Fidelity（仕様への忠実さ）」を差別化軸に掲げているため、この差分を
  「意図した緩和」として明示するのか、「OIDC 準拠として `redirect_uri` を常に必須化」するのかを
  判断したい。

> 本トピックは redirect_uri の**存在要件**に限定する。以下の既存論点とは扱う差分が異なるため重複しない:
> - fragment 拒否 / 危険スキーム拒否 / 登録済み URI 検査: `study-material/current-implementation-documentation-backlog.md`（§redirect_uri の検証）、`tasks/done/p0-redirect-uri-fragment-rejection.md` / `tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md`
> - Token Endpoint での redirect_uri 一致要件（`redirectUriExplicit`）: `packages/core/src/token-request.ts`（既実装）
> - 複数登録時に必須化する挙動: 既に実装済み（本トピックは「1 件登録時の省略」だけが対象）

## 2. 関連する仕様・基準（このトピック固有の差分）

Basic OP の定義・共通仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。
ここでは `redirect_uri` の**存在要件**に直接効く条文だけを引く。

### 2.1 OpenID Connect Core 1.0 §3.1.2.1 Authentication Request

Authentication Request のパラメータ表で `redirect_uri` は **REQUIRED** と明記されている。

> **redirect_uri** — REQUIRED. Redirection URI to which the response will be sent. This URI
> MUST exactly match one of the Redirection URI values for the Client pre-registered at the
> OpenID Provider ...

つまり OIDC の Authentication Request では、登録 URI の件数に関わらず `redirect_uri` を
**常に送る**ことがクライアントに要求される。省略された場合は仕様上は不正なリクエストである。

### 2.2 RFC 6749 §3.1.2.3（OAuth 2.0 との差分）

OAuth 2.0 では `redirect_uri` は「登録が 1 件で完全一致するなら省略可」という条件付きパラメータ。
現状の実装（`registeredUris.length === 1` なら省略許容）はこの OAuth 2.0 の規則に沿っている。
**OIDC はこれを上書きして REQUIRED に格上げしている**点が本トピックの核心。

### 2.3 セキュリティ上の位置づけ

- 現状でも open redirect は防げている。`redirect_uri` が送られた場合は登録 URI と RFC 3986
  Simple String Comparison で完全一致検証しており、`redirect_uri` を省略した場合は登録済みの
  唯一の URI を使うため、任意 URI へのリダイレクトは発生しない。
- したがってこれは**セキュリティ欠陥ではなく仕様適合（Fidelity）の差分**である。
  ただし「厳格な OIDC RP / バリデータが不正とみなすリクエストを OP が受理してしまう」点で、
  相互運用性・仕様忠実性の観点の課題になる。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
  （`redirect_uri` が REQUIRED である根拠）
- OpenID Connect Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User — https://openid.net/specs/openid-connect-core-1_0.html
- RFC 6749 §3.1.2.3 Dynamic Configuration of Redirection Endpoint — https://www.rfc-editor.org/rfc/rfc6749#section-3.1.2.3
  （OAuth 2.0 では省略可＝現状実装の由来）
- 本リポジトリ内: `study-material/current-implementation-documentation-backlog.md`（現状挙動の記録。ただし OIDC §3.1.2.1 との衝突としては未フラグ）

## 4. 現在の実装確認

`packages/core/src/authorization-request.ts` の `resolveRedirectUri`（450-485 行付近）:

```ts
function resolveRedirectUri(
  requestRedirectUri: string | undefined,
  registeredUris: string[],
  clientType?: 'confidential' | 'public'
): string {
  if (requestRedirectUri !== undefined) {
    // ... fragment 拒否 → 登録 URI と照合 → return
  }

  // redirect_uri が省略された場合
  if (registeredUris.length === 1) {
    return registeredUris[0] as string;   // ← ここで OIDC §3.1.2.1 REQUIRED を満たさない
  }

  // 複数の登録済みURIがある場合は redirect_uri が必須
  throw new AuthorizationError(
    AuthorizationErrorCode.InvalidRequest,
    'redirect_uri is required when multiple redirect URIs are registered'
  );
}
```

- `validateAuthorizationRequest`（756 行付近）から呼ばれる。
- 省略時、登録 1 件なら黙ってフォールバックし処理継続。複数登録時のみ `invalid_request`。
- `ValidatedAuthorizationRequest.redirectUriExplicit`（`effective.redirect_uri !== undefined`）で
  「明示送信されたか」を後段（Token Endpoint の一致要件）へ伝える設計は既にある。

## 5. 現在の実装との差分

満たしていること:

- ✅ `redirect_uri` が送られた場合の登録 URI 完全一致検証（open redirect 防止）。
- ✅ 複数登録時の `redirect_uri` 必須化。
- ✅ `redirectUriExplicit` による Token Endpoint 一致要件の連携。

不足・確認が必要なこと:

- 🟡 **OIDC Core §3.1.2.1 の REQUIRED を満たさない**: 登録 1 件時に `redirect_uri` 省略を許容している。
  厳格な OIDC RP / 適合性バリデータは「`redirect_uri` 欠落＝不正リクエスト」とみなすため、
  本 OP が受理する認可リクエスト集合が仕様より広い（Fidelity 差分）。
- 🟡 **挙動の非対称**: 同じ「省略」でも登録 1 件なら成功、複数なら `invalid_request` と分岐が割れる。
  仕様（常に REQUIRED）と揃えれば挙動が一貫する。
- 🟢 **Basic OP 認証（Conformance）への影響は限定的**: OIDF Conformance Suite は常に `redirect_uri` を
  送るため、この差分は認証テストでは顕在化しにくい（＝認証をブロックする課題ではない）。

## 6. 改善・追加を検討する理由

- **Fidelity**: 「OIDC を忠実に検証できる」を掲げる以上、Authentication Request の必須パラメータ要件は
  仕様どおりにしたい。特に「OP が仕様上不正なリクエストを受理する」挙動は、利用者が本番設計で
  「redirect_uri は省略できる」と誤学習するリスクがある。
- **相互運用性**: 実際の OIDC クライアントライブラリは通常 `redirect_uri` を常に送る。必須化しても
  正規クライアントは影響を受けず、仕様非準拠なクライアントだけが早期に検出される。
- **導入しやすさ**: 変更は `resolveRedirectUri` の 1 分岐（登録 1 件フォールバック）を
  `invalid_request` に置き換えるだけで局所的。ただし後方互換（既存 sample / テストが省略に依存していないか）と
  Conformance 互換の観点で、**既定挙動を変えるか opt-in にするか**の判断が要る。
- **実装しない場合のリスク**: 仕様と実挙動の乖離が残置し、Fidelity のシグナルが弱まる。
  利用者が「省略可」を前提にした設計を本番 IdaaS へ移行する際に齟齬が出る可能性。

## 7. 実装方針の候補（最終判断は人間）

- **方針A（既定で必須化）**: `resolveRedirectUri` の「登録 1 件フォールバック」を廃し、
  `redirect_uri` 省略時は常に `invalid_request`（非リダイレクトエラー）とする。最も仕様忠実。
  既存 sample / E2E / conformance が省略に依存していないかの回帰確認が必要。
- **方針B（opt-in 互換フラグ）**: 既定は必須化しつつ、`allowNonPkceAuthorizationCodeFlow` と同様に
  `allowOmittedRedirectUriForSingleClient?: boolean` のような互換オプションを
  `ValidateAuthorizationRequestOptions` に追加し、旧挙動を明示オプトインで残す。
  後方互換を壊さずに既定を仕様側へ倒せる。
- **方針C（現状維持＋文書化）**: 実装は変えず、「core は登録 1 件時に redirect_uri 省略を許容する
  （OAuth 2.0 互換挙動）。OIDC §3.1.2.1 は REQUIRED である点に留意」と型 doc / README に明記する。
  実装コスト最小だが Fidelity 差分は残置。

判断材料:

- Conformance Suite は常に `redirect_uri` を送るため、方針 A/B のどちらでも Basic OP 認証は通る見込み。
- 既定を変える（方針A）と、省略前提の既存テストがあれば落ちる。まず影響範囲（テスト・sample）を
  棚卸しし、影響が無ければ A、あるいは安全側で B を選ぶのが妥当。
- `RELEASE-v0.x-scope.md` の「core はポリシーを持ちすぎない」思想では B が最も整合的。

## 8. タスク案

- [ ] 既存 sample / `tests/e2e` / 各 `conformance.test.ts` が「`redirect_uri` 省略」に依存していないか棚卸しする
- [ ] 方針（A 既定必須 / B opt-in 互換 / C 文書化）を決定する
- [ ] （TDD）`authorization-request.test.ts` に「登録 1 件でも `redirect_uri` 省略は `invalid_request`」を先に追加
- [ ] （方針B採用時）`ValidateAuthorizationRequestOptions` に互換オプションを追加し、旧挙動をオプトイン化
- [ ] `resolveRedirectUri` の分岐を修正し、既定挙動を仕様（REQUIRED）へ寄せる
- [ ] `study-material/current-implementation-documentation-backlog.md` の該当記述（登録 1 件で省略可）を、決定した挙動に合わせて更新
- [ ] `study-material/basic-op-requirement-traceability.md` の Authorization Request 行に redirect_uri 必須要件を注記
