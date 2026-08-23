# クライアント認証：`client_secret_basic` + ボディの `client_id` 同送を「多重認証」と誤検知して拒否する問題

## ステータス

🟠 High / 未着手（実装バグ・相互運用性）

## 1. このトピックで確認したいこと

Token Endpoint のクライアント認証で、**`Authorization: Basic` で認証しつつ、リクエストボディにも
`client_id` を（`client_secret` は付けずに）送る**正規のクライアントが、
現状「複数の認証方式を使用した」として `invalid_request` で拒否される問題を確認する。

- `client_id` の**単独送信は認証方式ではなく識別子**であり、RFC 6749 §3.2.1 は Basic 認証と
  併送しても許容している。
- 現状の判定は「ボディに `client_id` **または** `client_secret` があれば post 認証を使った」と
  見なしており、`client_id` だけでも多重認証と誤検知する。

> 本トピックはクライアント認証の**多重方式検知ロジックの誤判定**に限定する。以下とは差分が異なるため重複しない:
> - 認証方式ダウングレード（登録 method と実使用 method の不一致拒否）: `packages/core/src/client-auth.ts`（既実装）
> - client_secret の timing-safe 比較 / at-rest hashing: `tasks/done/p0-client-secret-timing-safe-comparison.md` / `study-material/credential-at-rest-hashing.md`
> - 認証スキームの大小文字非感度: `tasks/done/p0-case-insensitive-auth-schemes.md`
> - 未知 client の timing oracle: `study-material/client-auth-unknown-client-timing-oracle.md`
> - grant_type のパラメータ混同: `study-material/token-endpoint-grant-parameter-confusion.md`

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 6749 §2.3 Client Authentication

> The client MUST NOT use more than one **authentication method** in each request.

禁止されるのは「複数の**認証方式**の併用」。`client_secret_basic`（Authorization ヘッダ）と
`client_secret_post`（ボディの `client_secret`）を同時に使うのは禁止だが、
**識別子である `client_id` の併送はここでいう「認証方式」ではない**。

### 2.2 RFC 6749 §3.2.1 Client Authentication（Token Endpoint）

> A client MAY use the `client_id` request parameter to identify itself when sending requests
> to the token endpoint. In the `authorization_code` `grant_type` request to the token endpoint,
> a client MAY set the `client_id` parameter ...

`client_id` はリクエストボディに置いてよい識別子。Basic 認証と併送しても仕様違反ではない。
実際、多くの OAuth クライアント実装は Basic ヘッダに加えてボディにも `client_id` を無条件に付与する。

### 2.3 OAuth 2.1 §2.3 / §3.2.1

OAuth 2.1 も同様に「複数の認証方式の併用禁止」であり、`client_id` 単独の併送を禁じてはいない。
Basic + ボディ `client_id` は許容される（`client_secret` の併送のみが多重方式）。

## 3. 参照資料

- RFC 6749 §2.3 Client Authentication — https://www.rfc-editor.org/rfc/rfc6749#section-2.3
  （"MUST NOT use more than one authentication method" の原文）
- RFC 6749 §3.2.1 Client Authentication at Token Endpoint — https://www.rfc-editor.org/rfc/rfc6749#section-3.2.1
  （`client_id` を識別子としてボディに送ってよい根拠）
- OAuth 2.1 draft §2.3 / §3.2.1 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/

## 4. 現在の実装確認

`packages/core/src/client-auth.ts` の `authenticateClient`（111-121 行付近）:

```ts
const hasBasicHeader = hasAuthScheme(authorizationHeader, 'Basic');
const hasPostCredential =
  params.client_id !== undefined || params.client_secret !== undefined;  // ← ここが過剰

// OAuth 2.1 Section 2.3: 認証方式を同時に複数使ってはいけない
if (hasBasicHeader && hasPostCredential) {
  throw new TokenError(
    TokenErrorCode.InvalidRequest,
    'Multiple client authentication methods provided. Use either Authorization header or request body, not both.',
  );
}
```

- `hasPostCredential` は `client_id` **または** `client_secret` のどちらかがあれば真になる。
- そのため `Authorization: Basic ...` + ボディ `client_id`（`client_secret` なし）の正規リクエストが
  `hasBasicHeader && hasPostCredential` に該当し、`invalid_request` で落ちる。

## 5. 現在の実装との差分

満たしていること:

- ✅ Basic + ボディ `client_secret`（真の多重認証方式）の拒否。
- ✅ 認証方式ダウングレード防止、public client の secret 提示拒否、timing-safe 比較。

不足・確認が必要なこと:

- 🟠 **正規クライアントの誤拒否（相互運用性の回帰）**: Basic ヘッダに加えてボディに `client_id` を
  無条件付与するクライアント（実装として一般的）が Token 交換に失敗する。
- 🟠 **仕様（RFC 6749 §3.2.1）との乖離**: `client_id` 単独併送は許容されるべきだが拒否している。
- 🟡 **一致検証の欠如**: 併送された `client_id` が Basic の `client_id` と食い違う場合、本来は
  「不一致 → `invalid_request`（または `invalid_client`）」で弾きたいが、現状はそもそも
  併送段階で一律拒否のため、一致検証の分岐が存在しない。

## 6. 改善・追加を検討する理由

- **相互運用性（差別化軸の Fidelity/Portability に直結）**: 「素早く仕様を体感する」OSS で
  正規クライアントが認証段階で落ちると、利用者は原因の切り分けができず離脱する。
- **セキュリティを下げない修正**: 多重「認証方式」の拒否は `client_secret` の併送のみで判定すればよく、
  攻撃面は増えない。むしろ「Basic の client_id とボディの client_id の一致検証」を足すことで
  防御が一段強くなる。
- **導入しやすさ**: 変更は `hasPostCredential` の定義と、併送 `client_id` の一致検証の追加に局所化できる。
- **実装しない場合のリスク**: 一般的なクライアント実装との非互換が残り、「動くものを早く」体験を損なう。

## 7. 実装方針の候補（最終判断は人間）

- **方針A（多重判定を `client_secret` のみに絞る）**: `hasPostCredential` を
  「ボディに `client_secret` があるか」だけで判定する。加えて Basic 使用時にボディ `client_id` が
  あれば **Basic の client_id と一致を要求**し、不一致なら `invalid_request` とする。最も仕様忠実。
- **方針B（併送 client_id を無視）**: Basic 使用時はボディ `client_id` を単に無視する（一致検証しない）。
  実装は軽いが、食い違い検出という防御機会を捨てる。
- **方針C（現状維持＋文書化）**: 実装は変えず「Basic 使用時はボディに client_id を付けないこと」と
  CLI 生成コード / README に注意書き。利用者側クライアントを縛るため相互運用性課題は残置。非推奨。

判断材料:

- 方針 A が仕様忠実かつ防御的で推奨候補。ただし「一致検証で不一致のとき返すエラーコード」
  （`invalid_request` か `invalid_client` か）は要決定。§3.2.1 の趣旨からは `invalid_request` が自然。
- `client_secret_post` を登録している client が Basic を使ってきた場合の扱いは既存の
  「認証方式ダウングレード拒否」ロジックがそのまま効くため、本修正と干渉しない。

## 8. タスク案

- [ ] 方針（A 一致検証 / B 無視 / C 文書化）を決定する（推奨: A）
- [ ] （TDD）`client-auth.test.ts` に以下を先に追加:
  - Basic + ボディ `client_id`（`client_secret` なし・値一致）→ 認証成功
  - Basic + ボディ `client_id`（Basic と不一致）→ `invalid_request`
  - Basic + ボディ `client_secret` → 従来どおり `invalid_request`（多重認証方式）
  - ボディ `client_secret_post` 単独 → 従来どおり成功（回帰固定）
- [ ] `authenticateClient` の `hasPostCredential` を `client_secret` 基準に修正し、併送 `client_id` の一致検証を追加
- [ ] 各 sample の `conformance.test.ts` を生成する `packages/cli` のテンプレート/生成コードで、
  Basic + ボディ `client_id` の受理が契約テストに含まれるか確認し、必要なら追加（生成コードは直接編集しない）
