# Consent（同意）の記録・永続化と再利用、Grant 管理

## ステータス

🟠 High（Basic OP の `prompt` 挙動の実効性 / OSS UX / セキュリティ）/ 未着手（方針未確定 = 検討中）

## 1. このトピックで確認したいこと

OP が End-User から取得した **consent（クライアントへのスコープ付与の同意）** を、

1. **いつ記録するか**（同意 UI で承認された瞬間に永続化されるか）
2. **どこに永続化するか**（`(subject, clientId, grantedScopes)` を保持するストアがあるか）
3. **どう再利用するか**（再訪時に既存同意を参照して同意 UI をスキップできるか、`prompt=none` の `consent_required` 判定に使えるか）
4. **どう管理・失効するか**（ユーザーが同意を取り消す、スコープが増えたときの incremental consent）

という consent のライフサイクルが、現状の core / sample / CLI 生成コードで**成立していない**点を確認する。

本リポジトリには既に **読み取り側の `ConsentResolver.hasConsent(subject, clientId, scopes)`** が存在し（`tasks/done/p0-consent-resolver.md` で追加、`prompt=none` 経路の `checkPromptNone` が利用）、`offline_access` の付与条件フック `isOfflineAccessGranted` も実装されている。しかし **「同意を記録する書き込み側」と「対話フローで既存同意を参照して再同意を省く経路」が欠落**しており、読み取り側のインターフェースが**実データを持たないまま宙に浮いている**。

> 関連する既存ファイルとの差分（重複させない）:
> - `study-material/done/cli-generated-provider-browser-session-and-sso.md` / `tasks/p1-generated-provider-browser-session-sso.md`
>   → **認証セッション（OP ログイン状態）の永続化**を扱う。`prompt=none` の *session* 判定の前提を整える。
>   本ファイルは **consent（同意）の永続化**という直交した別レイヤを扱う（session が通っても consent が無ければ `consent_required`）。
> - `study-material/offline-access-scope-grant-policy.md`
>   → `offline_access` を付与してよいかの判定フック（`isOfflineAccessGranted`）を扱う。
>   本ファイルは「同意そのものの記録・再利用」を扱い、`offline_access` 判定はその一利用先に過ぎない。
> - `tasks/done/p0-consent-resolver.md`
>   → `ConsentResolver.hasConsent`（読み取り）と `checkPromptNone` への統合を扱う（**読み取り側のみ**）。
>   本ファイルは **書き込み側（記録）と対話フローでの参照** という未実装の差分に絞る。

## 2. 関連する仕様・基準（このトピック固有の差分）

共通の `prompt` / Basic OP の仕様索引は `study-material/basic-op-requirement-traceability.md` および
`study-material/done/cli-generated-provider-browser-session-and-sso.md` を参照（重複説明しない）。
本トピックに固有の根拠を以下に絞る。

### 2.1 OIDC Core 1.0 §3.1.2.4 — Authorization Server Obtains End-User Consent/Authorization

OP は認可コードを発行する前に、End-User から **クライアントへの認可（consent）** を取得する責務を負う。
仕様は「同意を取得すること」を求めるが、**毎回取得し直すか、過去の同意を再利用してよいか**は OP の裁量に委ねている。
実運用の OP（Google / Auth0 / Keycloak 等）は、**初回に同意を記録し、同一 `(user, client, scope)` の再訪では同意 UI を省略**するのが一般的挙動である。

### 2.2 OIDC Core 1.0 §3.1.2.1 — `prompt` パラメータ

- `prompt=none`: OP は**いかなる認証・同意 UI も表示してはならない（MUST NOT）**。
  認証が無ければ `login_required`、**同意が取得されていなければ `consent_required`** を返す。
  → これは「OP が **過去の同意を参照できる**（= 記録されている）」ことを前提にした分岐である。
  記録機構が無ければ、`prompt=none` は **常に `consent_required`** になり、silent な再認可が永久に成立しない。
- `prompt=consent`: OP は**過去の同意の有無にかかわらず、同意 UI を再表示しなければならない（MUST）**。
  → これは「既存同意で UI をスキップする」最適化を入れた場合に、`prompt=consent` だけは**スキップ対象外**にする必要があることを意味する。
- `prompt` 省略時: OP は同意を取得済みなら UI をスキップしてよい（MAY）。

### 2.3 OIDC Core 1.0 §11 — `offline_access`

`offline_access`（= Refresh Token 発行）は「`prompt=consent` を含む」か「**その他の offline access を許可する条件が整っている**」場合にのみ付与してよい（§11、`offline-access-scope-grant-policy.md` 参照）。
informative な例として「ユーザーが事前に当該クライアントへのオフラインアクセスを許可した**記録**」が挙げられている。
→ 「同意の記録」はこの「その他の条件」を実装する基盤となり、本トピックと `isOfflineAccessGranted` を接続する。

### 2.4 RFC 6749 §10.2 / OAuth 2.0 Security 観点

- 同意を記録せず**毎回同意 UI を出す**と、ユーザーが内容を読まず反射的に承認する「consent fatigue（同意疲れ）」を招き、フィッシング耐性を下げる。
- 一方、記録した同意を**スコープ単位で厳密に**管理しないと、**scope の昇格**（後から要求された新スコープが、過去同意のスコープに含まれていないのに silent に付与される）リスクがある。記録は「付与済みスコープの集合」として保持し、**新規スコープが含まれるときは再同意を要求する（incremental consent）**必要がある。

### 2.5 Grant 管理・失効（拡張観点）

- ユーザーが「このアプリのアクセスを解除」できる **grant 失効 UI / API** は本格運用で要求される（Google「サードパーティ アクセス」相当）。
- OAuth 2.0 Grant Management for OAuth 2.0（FAPI 系の `grant_management_action` 等）は拡張仕様として存在するが、Basic OP の必須ではない。本ファイルでは「記録の最小実装」と「将来の grant 管理拡張」を分けて整理する。

## 3. 参照資料

- OpenID Connect Core 1.0
  - §3.1.2.1 Authentication Request（`prompt` の `none` / `consent` 挙動）
    — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
  - §3.1.2.4 Authorization Server Obtains End-User Consent/Authorization
    — https://openid.net/specs/openid-connect-core-1_0.html#Consent
  - §11 Offline Access
    — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- RFC 6749 The OAuth 2.0 Authorization Framework §10.2 Client Impersonation
  — https://www.rfc-editor.org/rfc/rfc6749#section-10.2
- OpenID Connect Conformance Profiles v3.0（Basic OP の `prompt` テスト要件の前提）
  — https://openid.net/certification/
- 本リポジトリ内（重複しない関連トピック）:
  - `study-material/done/cli-generated-provider-browser-session-and-sso.md`（認証セッション永続化。本ファイルの前提レイヤ）
  - `study-material/offline-access-scope-grant-policy.md`（`offline_access` 付与条件。本ファイルの一利用先）
  - `tasks/done/p0-consent-resolver.md`（`ConsentResolver.hasConsent` 読み取り側。本ファイルが書き込み側を補完）
  - `study-material/scope-handling-validation-and-granted-scope.md`（granted scope の返却。incremental consent と接続）
  - `study-material/resolver-and-store-contract.md`（store のアトミック性・TTL 契約。consent store もこの契約に従う）

## 4. 現在の実装確認

### 4.1 読み取り側（実装済み・ただし供給源が無い）

- `packages/core/src/auth-transaction.ts`:
  - `ConsentResolver.hasConsent(subject, clientId, scopes): Promise<boolean>` を定義（30-31 行付近）。
  - `checkPromptNone(transaction, sessionResolver, request, consentResolver?, ...)`: `consentResolver` が渡されれば session 確認後に `hasConsent` を呼び、false なら `consent_required` を throw。
- `packages/core/src/index.ts`: `ConsentResolver` / `checkPromptNone` を export 済み。

### 4.2 対話フロー（記録も参照もしていない）

- `packages/sample/src/oidc-provider/routes/consent.ts`:
  - GET で **無条件に同意 UI を表示**（既存同意の参照なし）。
  - POST `action=approve` で `completeAuthTransaction` → `createAuthorizationCode` → コード発行するが、
    **同意を記録するストア書き込みが一切ない**。承認の事実はトランザクション破棄とともに消える。
- `packages/sample/src/oidc-provider/routes/authorize.ts`:
  - `prompt=none` 経路で `c.get('consentResolver')` を取得するが、**未設定なら即 `consent_required`**（194-197 行）。
  - `prompt` 省略・通常経路では **必ず login → consent へ誘導**し、既存同意で consent をスキップする分岐が無い。
- `packages/sample/src/oidc-provider/resolvers.ts` / `store.ts`:
  - **`consentResolver` の登録も、consent 記録用ストアも存在しない**（`grep` で確認: consent 関連のストアは無し）。

### 4.3 帰結

- サンプル / CLI 生成 Provider では `consentResolver` が常に undefined のため、**`prompt=none` は構造的に常に `consent_required`** を返す。
  認証セッション（SSO 化、`cli-generated-provider-browser-session-and-sso.md`）を入れても、**consent 側が空のままでは `prompt=none` の silent 成功は達成できない**。
- 通常フローでは、同一クライアント・同一スコープへの再訪でも**毎回同意 UI**が出る（consent fatigue）。

## 5. 現在の実装との差分

満たしていること:

- ✅ 読み取り側インターフェース `ConsentResolver.hasConsent` と `checkPromptNone` への統合（`prompt=none` の consent 判定の「受け口」は存在）。
- ✅ `isOfflineAccessGranted` フックで「その他の条件」（§11）を差し込む拡張点は存在。
- ✅ scope のフィルタリング（`offline_access` をクライアント設定で除外）は consent POST / `prompt=none` 双方で実装済み。

不足／曖昧:

- 🟠 **書き込み側（記録）が無い**: 同意承認時に `(subject, clientId, grantedScopes)` を永続化する経路もストアも未定義。読み取り側が常に空を引く。
- 🟠 **対話フローで既存同意を参照しない**: `prompt` 省略時に `hasConsent` を見て同意 UI をスキップする分岐が無い（毎回プロンプト）。
- 🟠 **`prompt=none` が構造的に成立しない**（サンプル/CLI）: consent 供給源が無く Basic OP の `prompt=none` 系挙動を実機で満たせない。
- 🟡 **incremental consent / scope 昇格防御が未定義**: 記録を入れる際、新規スコープが過去同意に含まれない場合に**再同意を強制**するルールが必要だが未整理。
- 🟡 **`prompt=consent` のスキップ除外**: 既存同意スキップ最適化を入れる場合、`prompt=consent` は必ず UI 再表示（§3.1.2.1 MUST）にする分岐が必要。
- 🟡 **grant 失効 UI / API が無い**: 記録した同意をユーザーが取り消す手段が無い（本格運用での要件）。
- 🟢 **Basic OP 認定の合否**: 認定は「session + consent を OP が参照して `prompt` を出し分ける」ことを検証する。session 側（既存タスク）と本 consent 側の両方が揃って初めて `prompt=none` 系テストに耐える。

セキュリティ観点:

- 記録の **粒度はスコープ集合**で持ち、`hasConsent` は「要求スコープ ⊆ 付与済みスコープ」のときのみ true を返すこと。部分一致での true は scope 昇格を招く。
- consent store は `resolver-and-store-contract.md` の契約（参照一貫性・失効反映）に従う。同意失効が次の `prompt=none` に即反映されないと、取り消し後も silent 認可が通ってしまう。

## 6. 改善・追加を検討する理由

- **Basic OP の実効性**: `prompt`（none/login/consent/select_account）対応は Basic OP 必須機能（CLAUDE.md）。session 永続化だけ入れても consent 記録が無いと `prompt=none` の silent 成功が出せず、**「実装した `prompt=none` が実機で常に失敗する」**という穴が残る。本トピックは既存 `ConsentResolver`（読み取り）を**実際に機能させる最後のピース**。
- **拡張機能 ではなく 必須レイヤ寄り**: grant 管理 UI / Grant Management 拡張は「拡張機能」だが、**「同意を記録して再利用する」最小機構は Basic OP の `prompt` 挙動を満たすための準必須**。優先度を分けて扱うべき。
- **導入しやすさ**: core は既に `ConsentResolver` 抽象を持つため、**(a) 記録用メソッドを `ConsentResolver` に追加（または別 `ConsentStore` を新設）し、(b) consent POST 経路で記録、(c) authorize の通常経路で `hasConsent` を参照**するだけで接続できる。core のロジック改変は小さく、永続化は既存の resolver/store 注入思想に沿って利用者責務にできる。
- **既存実装との接続**: `isOfflineAccessGranted` に「記録済み同意があれば true」を渡せるようになり、§11 の「その他の条件」が自然に実装できる。`scope-handling-validation-and-granted-scope.md` の granted scope 返却とも整合する。
- **利用者メリット**: PoC 段階では「毎回同意で OK」だが、本番志向ユーザー（CLAUDE.md ターゲット）は「再訪で同意省略」「ユーザーによる解除」を求める。記録機構があれば段階的に grant 管理 UI へ拡張できる。
- **実装しない場合のリスク**: `prompt=none` が実機で常に失敗し、Conformance の `prompt` 系テストに通らない。さらに consent fatigue でフィッシング耐性が下がる。読み取り側 `ConsentResolver` が「使えないインターフェース」として残り続ける。

## 7. 実装方針の候補（最終判断は人間）

### 記録の置き場所

- **方針A（`ConsentResolver` に書き込みを追加）**: 既存 `ConsentResolver` に
  `recordConsent(subject, clientId, scopes): Promise<void>` / `revokeConsent(subject, clientId): Promise<void>` を足す。
  読み取りと書き込みが 1 インターフェースに集約され、利用者が一箇所を実装すればよい。後方互換のため任意メソッド化も検討。
- **方針B（別 `ConsentStore` を新設）**: 読み取り（`hasConsent`）と書き込み（`record`/`revoke`/`list`）を分離。
  責務分離は綺麗だが利用者が実装する型が増える。

### 対話フローでの参照

- **方針C（authorize 通常経路で `hasConsent` を参照）**: `prompt` に `consent` が無く、`hasConsent(subject, clientId, requestedScopes)` が true なら **consent UI をスキップ**して直接コード発行へ。
  `prompt=consent` のときは必ず UI 表示（§3.1.2.1 MUST）。`max_age` / `prompt=login` の既存分岐と順序整合を取る。
- **方針D（consent POST で記録）**: `action=approve` 時に `recordConsent(subject, clientId, grantedScope)` を呼ぶ。
  これにより以降の `prompt=none` / 通常再訪で `hasConsent` が true を返すようになる。

### incremental consent

- **方針E（差分スコープのみ再同意）**: 要求スコープのうち**未同意の差分だけ**を同意 UI に出し、承認後に付与済み集合へ**マージ**する。`hasConsent` は「要求 ⊆ 付与済み」で判定。
  最も正しいが UI ロジックが増える。最小実装では「要求 ⊆ 付与済みなら全スキップ、そうでなければ全スコープを再同意」でも可。

### サンプル / CLI

- **方針F（最小リファレンス実装）**: sample に in-memory / KV ベースの consent store と `consentResolver` 登録を追加し、`prompt=none` が実機で silent 成功することを e2e で示す。CLI テンプレートにも反映（`packages/cli` 修正で生成物に入れる。CLAUDE.md のルール: 生成コードの修正は cli 側で行う）。

判断材料:

- 方針 A + C + D + F が「最小で `prompt=none` を成立させる」現実的セット。incremental（E）は段階導入でよい。
- grant 失効 UI / Grant Management 拡張は別ロードマップ（`RELEASE-v0.x-scope.md` 準拠で v0.x 範囲か判断）。
- consent store のアトミック性・失効反映は `resolver-and-store-contract.md` の契約に従わせる（KV の eventual consistency では失効が遅延し silent 認可が残る点に注意）。
- session 永続化（`cli-generated-provider-browser-session-and-sso.md`）と**セットで**入れないと `prompt=none` は完成しない。実装順序の依存関係を明示すること。

## 8. タスク案

- [x] 記録の置き場所を決定（方針A: `ConsentResolver` 拡張 / 方針B: 別 `ConsentStore`）— 採用: 方針A（`ConsentResolver` に任意の `recordConsent`/`revokeConsent` を追加）＋ sample 側の具象 `ConsentStore` を併用
- [x]（TDD）core: `hasConsent` を「要求スコープ ⊆ 付与済みスコープ」で判定する契約をテストで固定（部分集合判定。scope 昇格を false にする）— `packages/sample/src/oidc-provider/store.test.ts` の `ConsentStore` テストで固定、core 側はインターフェース doc で契約明文化
- [x]（TDD）core: consent 記録メソッド（`recordConsent` 等）の型と、`prompt=consent` のときは既存同意があってもスキップしない分岐ロジックのテスト — `consent-persistence.test.ts` の prompt=consent 再表示テストで固定
- [x] sample: consent 記録用ストア（`consentStore`）と `consentResolver` の登録を追加し、`resolvers.ts` / `store.ts` に配線
- [x] sample `routes/consent.ts`: `action=approve` 時に付与スコープを記録（incremental は最小実装: 要求⊄付与なら全再同意）
- [x] sample `routes/authorize.ts`: 通常経路で `hasConsent` を参照し、`prompt!=consent` かつ既存同意ありなら consent UI をスキップ
- [ ] `isOfflineAccessGranted` に「記録済み同意があれば許可」を接続できることを example として `offline-access-scope-grant-policy.md` から相互参照
- [x]（e2e）`prompt=none` が session + consent 双方を満たすとき silent にコード発行されることを検証（`cli-generated-provider-browser-session-and-sso.md` のセッション実装に依存）
- [x] CLI（`packages/cli`）テンプレートへ反映（生成コードの修正は cli 側で行う）
- [ ] （将来・別ファイル化候補）grant 失効 UI / API、OAuth Grant Management 拡張の検討
