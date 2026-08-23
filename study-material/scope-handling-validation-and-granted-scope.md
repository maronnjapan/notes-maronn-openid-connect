# Scope の検証・未知スコープの扱い・付与スコープの返却（`invalid_scope` / granted scope）

## ステータス

🟡 Medium / 未着手（方針未確定 = 検討中）

## 1. このトピックで確認したいこと

認可エンドポイント／トークンエンドポイントにおける **`scope` の扱い全般**を確認する。具体的には:

- 要求された `scope` のうち、OP がサポートしない（未知の）スコープが来たときの挙動
  （`invalid_scope` で拒否するか、無視してフィルタするか）
- 実際に **付与されたスコープ（granted scope）** をクライアントへ正しく通知できているか
  （RFC 6749 §3.3 の「要求と付与が異なる場合は MUST で `scope` を返す」要件）
- 同意画面での **部分同意（scope の取捨選択）** に対応できる余地があるか

`openid` 必須・`offline_access` の許可条件は **別ファイルで確定済み**なので、本ファイルでは
それ以外の「未知スコープ／付与スコープ通知／部分同意」に絞る。

> 関連既存ファイル（重複記載しない）:
> - `openid` 必須・PKCE 等の基本検証: `study-material/basic-op-requirements-baseline.md` §5
> - `offline_access` の許可ポリシー: `study-material/offline-access-scope-grant-policy.md`
> - refresh 時のスコープ縮小: `tasks/p1-refresh-scope-offline-access-rotation.md` / `tasks/done/T-020-refresh-scope-claims-filter.md`
> - Discovery の `scopes_supported` 広告: `tasks/T-021-discovery-metadata.md`
> - scope→claims マッピング: `study-material/userinfo-endpoint-comprehensive.md` §3.3

## 2. 関連する仕様・基準（このトピック固有の差分）

Basic OP の定義・共通仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照。
ここでは scope の「未知値の扱い」と「付与スコープ通知」に直接効く条文だけを引く。

### 2.1 RFC 6749 §3.3 Access Token Scope

- `scope` はスペース区切り・大文字小文字を区別する文字列。
- **「認可サーバは要求された scope を全部または一部 *無視してよい*（MAY）」**。
- **「発行された scope が要求と異なる場合、認可サーバは付与した実スコープを伝えるため
  `scope` レスポンスパラメータを *含めなければならない（MUST）*」**。
- scope が無効・未知・不正形式（invalid, unknown, malformed）のときは `invalid_scope` を返してよい。

→ つまり仕様は **「未知スコープを無視する」も「`invalid_scope` で弾く」も両方許容**している。
ただし **どちらを選んでも「実際に付与した scope を返す」義務は共通**である点が重要。

### 2.2 OAuth 2.1 §1.4.1 / §3.2.2.1 / §3.2.3.1（要一次資料確認: 章番号）

- scope の意味論は RFC 6749 を踏襲。token response でも「付与 scope が要求と異なる場合は `scope` を返す」。
- OAuth 2.1 でも未知スコープの無視は許容される（AS のポリシー）。

### 2.3 OIDC Core 1.0 §3.1.2.1 / §5.4

- `scope` は REQUIRED で `openid` を含むこと（実装済み）。
- `profile` / `email` / `address` / `phone` / `offline_access` が標準スコープ（§5.4 / §11）。
- 標準外スコープの扱いは OIDC Core では規定せず、OAuth の scope ポリシーに委ねられる。

## 3. 参照資料

- RFC 6749 §3.3 Access Token Scope — https://www.rfc-editor.org/rfc/rfc6749#section-3.3
  （「MAY ignore」「異なれば `scope` を MUST で返す」「`invalid_scope`」の根拠）
- RFC 6749 §5.1 Successful Response — https://www.rfc-editor.org/rfc/rfc6749#section-5.1
  （token response の `scope` パラメータ）
- RFC 6749 §4.1.2.1 Error Response — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1
  （`invalid_scope` を認可エラーとして返す場合）
- OAuth 2.1 draft — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
  （§1.4.1 / §3.2.2.1 / §3.2.3.1。章番号は一次資料で確認推奨）
- OpenID Connect Core 1.0 §3.1.2.1 / §5.4 — https://openid.net/specs/openid-connect-core-1_0.html

## 4. 現在の実装確認

### 4.1 認可エンドポイント（`packages/core/src/authorization-request.ts`）

```ts
// authorization-request.ts:506-524
const scope = scopeValue.split(' ').filter((s) => s.length > 0);
if (!scope.includes('openid')) {
  throw new AuthorizationError(AuthorizationErrorCode.InvalidScope, 'scope must include openid', ...);
}
```

- `openid` の有無だけを検査する。
- それ以外の値（`profile` / 任意の未知文字列）は **一切検証せず、そのまま `scope` 配列として通過**する。
- `offline_access` のみ §11 のポリシー（`isOfflineAccessGranted`）でフィルタされる（既存実装）。
- `AuthorizationErrorCode.InvalidScope` 列挙子は存在するが、**`openid` 欠如以外では使われていない**。

### 4.2 同意（`packages/sample/src/oidc-provider/routes/consent.ts`）

```ts
// consent.ts:88-92
const grantedScope = transaction.scope.split(' ').filter((s) => {
  if (s === 'offline_access' && !clientConfig?.offlineAccessAllowed) return false;
  return Boolean(s);
});
```

- 同意時に **`offline_access` だけ**クライアント設定でフィルタする。
- それ以外のスコープはユーザーが取捨選択できず、**要求された全スコープがそのまま付与**される（all-or-nothing の approve/deny）。
- 付与スコープ（`grantedScope`）を認可コードに保存する点は正しい。

### 4.3 トークンエンドポイント（`packages/core/src/token-response.ts`）

```ts
// token-response.ts
scope: scope.join(' ')  // 認可コードに保存された scope をそのまま echo
```

- token response は認可コードに保存された scope（= granted scope）をそのまま返す。
- granted scope == 認可コード scope なので、現状は「要求と付与が一致する限り」整合する。
- ただし認可コードに保存される scope は §4.1 で未知スコープを含んだままなので、
  **「未知スコープがそのまま付与扱いで echo される」**ことになる。

## 5. 現在の実装との差分

満たしていること:

- ✅ `openid` 必須検証（Basic OP 必須）。
- ✅ `offline_access` のポリシーフィルタ（§11）。
- ✅ granted scope を認可コードに保存し token response で echo する経路は存在する。

不足・確認が必要なこと:

- 🟡 **未知スコープの方針が無い**: `openid foobar` のような要求で `foobar` がそのまま付与扱いになる。
  RFC 6749 的には「無視（フィルタ）」も「`invalid_scope` で拒否」も許容だが、**現状はどちらでもなく素通り**。
  Discovery で `scopes_supported` を広告する（T-021）と、広告内容と実挙動が乖離するリスクがある。
- 🟡 **`scopes_supported` と実挙動の整合**: T-021 で `scopes_supported` を広告するなら、
  広告外スコープの扱い（無視 or 拒否）を **core 側で一貫**させないと「広告と挙動の不一致」になる。
- 🟢 **部分同意（scope granularity）の不在**: ユーザーが一部スコープだけ許可する UX を取れない。
  Basic OP 必須ではないが、PoC で「scope ごとの同意」を検証したい利用者には価値がある。
- 🟡 **付与スコープ通知の堅牢性**: 「未知スコープを無視する」方針を採るなら、無視によって
  granted scope が要求と変わるので、RFC 6749 §3.3 の「異なれば `scope` を返す」を満たすため
  token response の `scope` が **付与後の値**であることをテストで固定する必要がある（現状は echo 任せ）。

セキュリティ／相互運用性の観点:

- 未知スコープを無視するか拒否するかは、リソースサーバ側の認可判定に影響する。
  例えばリソースサーバが「未知スコープは権限なし」と解釈する前提なら無視で問題ないが、
  「要求が通った＝権限あり」と誤解する実装と組むと過剰付与に見える。
- `scopes_supported` を広告しておきながら広告外を黙って付与すると、クライアントの自動構成が
  「このスコープは使える」と誤学習する可能性がある（相互運用性の低下）。

## 6. 改善・追加を検討する理由

- **Fidelity**: 「OIDC/OAuth を忠実に検証できる」を掲げる以上、scope の付与・通知が
  RFC 6749 §3.3 に沿っていることを保証したい。特に「付与 scope を返す」契約はテストで固定すべき。
- **相互運用性**: `scopes_supported`（T-021）を広告する計画があるため、広告と実挙動の一貫性は
  先に方針を決めておかないと、後でクライアント側の自動構成と齟齬が出る。
- **利用者体験**: 部分同意は Basic OP 必須ではないが、「scope ごとの同意フローを試したい」という
  PoC ニーズは現実的にある。core がポリシーを持たず resolver/設定で注入する既存思想と相性がよい。
- **実装しない場合のリスク**: 未知スコープが素通りする挙動は、利用者が「OP が scope を検証している」と
  誤認したまま本番設計に進むと、リソースサーバ側の過剰付与解釈につながりうる。

## 7. 実装方針の候補（最終判断は人間）

未知スコープの扱いについて、RFC 6749 が許容する 2 系統 ＋ 注入方式:

- **方針A（無視・フィルタ）**: サポート集合（`scopes_supported`）外のスコープを認可時に黙って除外し、
  granted scope を縮小する。token response は縮小後の `scope` を返す（§3.3 MUST を満たす）。
  主要 IdP（Google 等）に近い挙動で相互運用性が高い。`openid` は必須のまま。
- **方針B（拒否）**: 広告外スコープが含まれていたら `invalid_scope` で拒否する。厳格だが、
  クライアントの軽微な誤りでもフロー全体が落ちるため PoC 体験は下がりうる。
- **方針C（resolver/設定注入）**: `ScopePolicy`（サポート集合 ＋ 無視/拒否の選択）を
  `validateAuthorizationRequest` のオプションとして注入できるようにし、core はデフォルトを持たない。
  既定は後方互換のため「素通り」を維持し、利用者がオプトインで A/B を選べる。
  既存の `isOfflineAccessGranted` 注入と同じパターンで自然に接続できる。
- **方針D（現状維持＋文書化）**: 実装は変えず、「core は `openid` 以外を検証しない。未知スコープの
  フィルタ／拒否は利用者責務」と型 doc / README に明記する。

部分同意（scope granularity）について:

- **方針E**: 同意フォームを scope ごとのチェックボックスにし、選択結果を granted scope として
  認可コードに保存する。core は既に granted scope を受け取る構造なので、sample/CLI 側の UI 拡張で完結する。
  ただし `openid` は外せない／必須スコープの定義が要る。

判断材料:

- 方針 C は「core はポリシーを持たない」設計（`RELEASE-v0.x-scope.md` の責務境界）と最も整合する。
- 方針 A をデフォルトにすると後方互換が崩れる可能性（既存テストが未知スコープ素通りを前提にしている場合）。
  → デフォルトは D（素通り維持）、オプトインで C、というのが安全側。
- `scopes_supported` 広告（T-021）の実装時期と歩調を合わせると、広告と挙動の一貫性を一度に固められる。

## 8. タスク案（方針確定後に着手）

- [ ] 未知スコープの方針（A/B/C/D）を決定する（人間判断）。`scopes_supported`（T-021）との整合を条件にする
- [ ] 部分同意（方針E）を v0.x に含めるか、後続ロードマップ送りかを決定する
- [ ] （方針C採用時・TDD）`authorization-request.test.ts` に以下を追加:
  - サポート集合外スコープが granted scope から除外される（無視モード）
  - サポート集合外スコープで `invalid_scope` が返る（拒否モード）
  - `openid` は常に残る／必須スコープが落とされない
  - token response の `scope` が **付与後の値**であること（RFC 6749 §3.3）
- [ ] （方針E採用時）`consent.ts` / `views.ts` / CLI テンプレートに scope ごとの同意 UI を追加
- [ ] `study-material/basic-op-requirement-traceability.md` の Scope 行に方針と挙動を注記
