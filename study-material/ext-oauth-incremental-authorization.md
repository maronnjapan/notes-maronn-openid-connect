# 拡張: OAuth 2.0 Incremental Authorization（`include_granted_scopes`）

## ステータス

🟢 拡張機能（相互運用性 / UX / scope 設計）/ 未着手

## 1. このトピックで確認したいこと

認可リクエストに `include_granted_scopes=true` を付けると、**過去に同じクライアントへ
付与済みのスコープを、今回の新しい認可付与（grant）にマージして 1 本のトークンにまとめる**、
という OAuth 2.0 Incremental Authorization（`draft-ietf-oauth-incremental-authz`）を
本ライブラリで拡張提供すべきかを確認する。

確認したい中心点は次の 3 つ。

1. 本リポジトリは「必要になったスコープを必要なときに少しずつ要求する（incremental）」運用を
   **プロトコルレベルで**支援できるか（現状は支援していない）。
2. 既に実装済みの**同意記録（consent grant の永続化）**と、本ドラフトの**スコープ・マージ**は
   どこまで重なり、どこが新規論点なのか。
3. 「過去付与スコープを silent に新トークンへ載せる」ことの**セキュリティ上の含意**
   （scope 昇格・意図しない権限の蓄積）をどう扱うか。

### 既存の関連ファイルとの差分（重複回避）

このトピックは scope / consent 周りの既存ファイルと隣接するため、**重複させずに差分だけ**を扱う。

- `study-material/done/consent-grant-persistence-and-management.md` /
  `tasks/done/p1-consent-persistence-prompt-none.md`:
  扱うのは **incremental consent**（＝新規スコープが過去同意に含まれない場合に
  **再同意プロンプトを強制する**こと）。これは「同意 UI をいつ出すか」の話。
  → 本ファイルは **incremental authorization**（＝`include_granted_scopes` という
  **リクエストパラメータ**で過去付与スコープを**トークンへマージ**するプロトコル機能）を扱う。
  両者は名前が似ているが**別レイヤ**：前者は「同意の取り直し」、本ファイルは「発行トークンの scope 合算」。
- `study-material/scope-handling-validation-and-granted-scope.md`:
  scope の検証・未知 scope・付与 scope の通知（RFC 6749 §3.3）を扱う。
  → 本ファイルは「**認可コードに載せる scope を、今回要求＋過去付与の和集合にする**」という
  scope の**決定ロジック**の差分に絞る。
- `study-material/refresh-token-grant-scope-preservation.md`:
  refresh 時の scope 上限の基準点（originally granted）を扱う。
  → 本ファイルは authorization endpoint での scope 合算が**新しい grant の originally granted**を
  どう定義するかに触れるが、refresh 側の上限判定そのものは上記ファイルに委ねる（後述 §6）。
- `study-material/offline-access-scope-grant-policy.md`:
  `offline_access` を付与する条件（`prompt=consent` 等）。
  → `include_granted_scopes` でマージする際に `offline_access` を含めてよいかは
  本ファイルの注意点として触れるが、付与条件そのものは上記ファイルを参照する。

## 2. 関連する仕様・基準

> ⚠️ 注記: 本環境からは datatracker.ietf.org / ietf.org への直接 HTTP 取得が 403 で不可だった
> （既存ファイル群と同じ制約）。以下は IETF の文書検索結果（公式ドラフトの要約）と記載者の知識に基づく。
> 逐語引用が必要な箇所は §8 のタスクで一次資料の再確認を必須とする。

### 2.1 OAuth 2.0 Incremental Authorization（`draft-ietf-oauth-incremental-authz`）

- **解決する課題**: incremental authorization が無いと、アプリは
  (a) 起動時に**将来必要になりうる全スコープをまとめて要求**する（UX が悪化し、同意のハードルが上がる）か、
  (b) **各 grant を個別に追跡**して複数のアクセストークンを使い分ける（実装が複雑化する）か、の二択になる。
  本ドラフトは「必要なスコープを必要になったときに追加要求し、**1 本のトークンに集約**する」ことを可能にする。
- **`include_granted_scopes` パラメータ**:
  - 認可リクエストに付与できる **OPTIONAL** なパラメータで、値は `"true"` / `"false"`。
  - サーバ側の対応も **MAY**（任意実装）。
  - `"true"` のとき、認可サーバは **SHOULD**「このクライアントに**過去付与済みのスコープ**を、
    今回の新しい認可付与に含める」。
  - これによりクライアントは、過去のスコープを自分で追跡しなくても、
    「ユーザがこのアプリへ与えた**全付与の合算**」を表すトークンを受け取れる。
- **発行されるトークンの scope**:
  - 検証に成功した場合、Access Token Response で発行される**新しいアクセストークン／リフレッシュトークンは、
    過去 grant のスコープを含む**ことが **MUST**（ただし RFC 6749 §3.3 に基づき
    「サーバがクライアント要求 scope を全部／一部無視する裁量」を行使する場合を除く）。
  - すなわち「今回要求 scope ∪ 過去付与 scope」が新トークンの権限になる。
- **ドラフトの現況（事実）**: 本 Internet-Draft は **`-04` で expired（no longer active）**。
  IETF 標準としては未完だが、**Google など実装系で広く使われている事実上の慣行**であり、
  相互運用性の観点で価値がある（後述 §6）。

### 2.2 ベースとなる OAuth 2.0 / OIDC の規定

本ファイル固有でない共通仕様（scope の検証・付与 scope 通知・refresh の上限）は
`study-material/basic-op-requirement-traceability.md` の「3. 関連する仕様・基準（共通参照ハブ）」
および上記 §1 の隣接ファイルを参照し、ここでは重複させない。要点のみ：

- **RFC 6749 §3.3（Access Token Scope）**: サーバはクライアント要求 scope を全部／一部無視してよい。
  実際に付与した scope が要求と異なる場合はレスポンスに `scope` を含める。
- **OIDC Core 1.0 §3.1.2 / §3.1.3**: Authorization Code Flow の scope は認可コードに紐づき、
  Token Endpoint で発行される token の権限上限となる。

## 3. 参照資料

- OAuth 2.0 Incremental Authorization（`draft-ietf-oauth-incremental-authz-04`、expired）:
  https://datatracker.ietf.org/doc/html/draft-ietf-oauth-incremental-authz
  - 本ファイルの根拠箇所: `include_granted_scopes` の定義（OPTIONAL、`true`/`false`）、
    「`true` のときサーバは過去付与 scope を含める（SHOULD）」、
    「新トークンは過去 grant の scope を含む（MUST、§3.3 の裁量を除く）」。
- RFC 6749 §3.3 Access Token Scope:
  https://datatracker.ietf.org/doc/html/rfc6749#section-3.3
- 参考（実装系の慣行）: Google OAuth 2.0 Incremental authorization
  （`include_granted_scopes=true` の振る舞いの代表例）。
- 隣接トピック（重複回避のための参照先）:
  - `study-material/done/consent-grant-persistence-and-management.md`
  - `study-material/scope-handling-validation-and-granted-scope.md`
  - `study-material/refresh-token-grant-scope-preservation.md`

## 4. 現在の実装確認

- **`include_granted_scopes` の受理・処理は無い**:
  `packages/core/src/authorization-request.ts` は scope を「今回要求された scope」としてのみ扱い、
  過去付与スコープとの和集合を取る経路が存在しない（`include_granted_scopes` は未知パラメータとして
  仕様通り無視される＝エラーにはならないが、機能もしない）。
- **同意記録の基盤は存在する**:
  consent grant の永続化（`ConsentResolver` / 同意保存）は実装済みで、
  「このクライアントに対し過去に付与されたスコープ集合」を参照する素地がある
  （詳細は `study-material/done/consent-grant-persistence-and-management.md`）。
  → Incremental Authorization の「過去付与 scope を引く」部分は、この記録を読むだけで実現できる可能性が高い。
- **scope の決定経路**:
  authorization endpoint → 認可コードに scope を保存 → Token Endpoint で token 発行、
  という流れ（`authorization-code.ts` / `token-response.ts`）。`include_granted_scopes` を効かせるなら
  **「認可コードに保存する scope を和集合にする」一点**が改修ポイントになる。
- **Discovery**: `include_granted_scopes` 対応を広告する標準メタデータは存在しない
  （ドラフト由来のため）。対応する場合は独自メタデータ or ドキュメントでの告知になる。

## 5. 現在の実装との差分

満たしていること:

- 🟢 過去付与スコープの記録（consent persistence）が既にあり、マージ元データは取得可能。
- 🟢 scope の和集合・重複除去・検証ロジックは既存（`scope-handling-validation-and-granted-scope.md`）を流用できる。

不足している可能性があること:

- 🔴 `include_granted_scopes` パラメータの受理と、**「今回要求 ∪ 過去付与」を認可コードへ保存する**処理が無い。
- 🟡 マージ後の scope を**どの grant の originally granted とみなすか**が未定義。
  refresh の上限基準（`refresh-token-grant-scope-preservation.md`）と整合させる必要がある。
- 🟡 RFC 6749 §3.3 に従い、**実際に付与した scope（合算後）をレスポンスの `scope` で返す**必要がある
  （クライアントが「結局どの scope が乗ったか」を知れるように）。

セキュリティ上、改善（検討）した方がよいこと:

- 🟠 **scope の silent な蓄積**: `include_granted_scopes=true` は「過去同意した scope を
  ユーザに再提示せず新トークンへ載せる」ため、**意図しない権限の累積**が起こりうる。
  「過去に一度同意した scope」と「今このトークンに乗っている scope」の乖離がユーザから見えにくくなる。
  → 過去付与 scope は**有効な同意が残っている分だけ**マージする、同意取り消し（revocation）が
  即座に反映される、などのガードが要る。
- 🟠 **`offline_access` の扱い**: 過去に `offline_access` を付与済みでも、今回の
  `include_granted_scopes` マージで**無条件に refresh token を出してよいか**は別途判断が必要
  （`offline-access-scope-grant-policy.md` の付与条件と矛盾しないこと）。

相互運用性の観点:

- 🟡 Google をはじめ主要 IdP が `include_granted_scopes=true` を実装しているため、
  そこへ移行予定の利用者が「同じ挙動を手元で検証したい」というニーズに応えられる。

Basic OP として提供する上で確認すべきこと:

- 🟢 **Basic OP 必須ではない**（認定プロファイルに含まれない拡張）。
  Basic OP の定義は `study-material/basic-op-requirement-traceability.md` を参照。
  本機能の有無は Basic OP 認定可否に影響しない。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**:
  - PoC・本番移行を見据える開発者が「スコープを段階的に要求する設計」を**手元で忠実に検証**できる。
    本ライブラリのコンセプト（最新仕様・忠実な検証）に合致する。
  - 主要 IdP の `include_granted_scopes` 挙動を再現でき、**移行前の挙動差分の事前確認**に使える。
- **Basic OP として必要か / 拡張か**: 拡張。Basic OP 必須要件ではない。
- **導入しやすいか / しにくいか**:
  - 🟢 **しやすい**側面: 過去付与 scope の記録（consent persistence）と scope 合算ロジックが既にあり、
    改修は「authorization endpoint で和集合を取り認可コードへ保存する」ほぼ一点に局所化できる。
  - 🟡 **注意**側面: 「originally granted の定義」「refresh 上限との整合」「scope 蓄積のセキュリティガード」
    という**設計判断**が伴うため、コード量より方針決定のコストが大きい。
- **既存実装との接続**:
  - `ConsentResolver` / consent 記録 →「過去付与 scope 集合」を取得。
  - `authorization-request.ts` の scope 決定箇所で `include_granted_scopes=true` のとき和集合を採用。
  - `authorization-code.ts` に和集合後の scope を保存 → 既存の Token 発行経路がそのまま新 scope を載せる。
- **利用者・開発者・運用者のメリット**:
  - 利用者（RP 開発者）: 初回に全 scope を要求しなくてよく、UX 設計の自由度が上がる。
  - 運用者: 主要 IdP と同じ段階的同意の挙動を検証でき、移行リスクを下げられる。
- **実装しない場合のリスク / 制約**:
  - 段階的スコープ要求を前提とするアプリの挙動を本ライブラリで再現できない（移行検証の穴）。
  - ただし「全 scope 一括要求」で代替可能なため、**機能欠如としての実害は限定的**。

## 7. 実装方針の候補

> 最終判断は人間が行う。特に「既定で有効にするか」「scope 蓄積をどこまで許すか」は方針判断であり AI 側で確定しない。

### 方針A（最小実装: authorization endpoint で和集合）

- `include_granted_scopes=true` を受理し、`ConsentResolver` から過去付与 scope を取得。
- **今回要求 scope ∪ 過去付与 scope** を計算し、未知 scope を除去・重複除去した結果を認可コードへ保存。
- 過去付与 scope が**今回同意の対象外**でも、有効な同意が残っている分だけマージ（同意取り消し分は除外）。
- Token Endpoint は既存経路のまま合算 scope を載せ、RFC 6749 §3.3 に従い `scope` を返す。
- メリット: 改修が局所的。デメリット: 「originally granted の再定義」「refresh 上限整合」を別途決める必要。

### 方針B（設定可能化）

- `ProviderConfig` に `incrementalAuthorization: 'off' | 'merge-granted'`（既定 `off`）を追加し、
  利用者が明示的に有効化したときだけ和集合を取る。
- メリット: 安全側の既定（silent 蓄積を既定で防ぐ）。OSS 検証ツールとして「試したい人だけ試せる」。
- デメリット: 設定・テストの分岐が増える。

### 方針C（非対応の明文化）

- ドラフトが expired であることを理由に**非対応とし、ロードマップ／ドキュメントに記載**する。
- `include_granted_scopes` は仕様通り未知パラメータとして無視される旨を明記。
- メリット: 実装コスト 0、セキュリティ上の新たな攻撃面を増やさない。
- デメリット: 主要 IdP 挙動の手元検証ができない。

判断材料:

- 「主要 IdP 挙動の忠実な検証」を重視 → 方針 A または B（既定 off の B が安全側）。
- 「ドラフト expired・Basic OP 範囲に集中」を重視 → 方針 C。
- いずれにせよ **refresh の scope 上限基準**（`refresh-token-grant-scope-preservation.md`）と
  **同意記録**（consent persistence）と**同時に**設計するのが整合的。

## 8. タスク案

- [ ] `draft-ietf-oauth-incremental-authz`（-04）の `include_granted_scopes` 規範文を一次資料で逐語確認し、
      本ファイル §2 の引用（OPTIONAL / SHOULD / MUST の主語）を確定する
- [ ] ドラフトが expired である事実を踏まえ、対応方針（A / B / C）を人間が決定する
- [ ] 方針 A / B を採用する場合:
  - [ ] `ConsentResolver` から「クライアント × subject の有効な過去付与 scope」を取得する口を確認・追加する
  - [ ] authorization endpoint で `include_granted_scopes=true` 時に「今回要求 ∪ 有効な過去付与」を計算する
        （同意取り消し済み scope は除外、未知 scope は除去、重複除去）
  - [ ] 和集合後の scope を認可コードへ保存し、Token レスポンスで `scope`（RFC 6749 §3.3）を返す
  - [ ] `offline_access` を和集合に含める条件を `offline-access-scope-grant-policy.md` と整合させる
  - [ ] refresh の scope 上限基準（originally granted）を `refresh-token-grant-scope-preservation.md` と
        矛盾なく定義する（マージ後 scope を新 grant の originally granted とみなすか等）
  - [ ] CLI テンプレート（`packages/cli`）と sample・`conformance.test.ts` 生成コードを同期する
- [ ] テスト要件（方針 A / B 採用時）:
  - [ ] 過去に `openid email` を付与済みのクライアントが `scope=openid profile&include_granted_scopes=true` で
        認可 → 発行トークン scope が `openid email profile` になる
  - [ ] `include_granted_scopes` 省略 or `false` のときは従来通り「今回要求 scope のみ」になる
  - [ ] 過去付与のうち**同意取り消し済み**の scope はマージされない
  - [ ] 未知 scope はマージ対象から除外される
  - [ ] 方針 C を選ぶ場合は「`include_granted_scopes` が無視され scope が合算されない」ことをテストで固定し、
        ドキュメントに非対応を明記する
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` および cli テストがパスすること
