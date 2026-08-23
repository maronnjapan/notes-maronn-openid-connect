# Bearer クレデンシャルの保存時ハッシュ化（認可コード / リフレッシュトークン / Opaque アクセストークン）

## ステータス

🟡 Medium / 未着手（方針未確定 = 検討中）

## 1. このトピックで確認したいこと

OP が保持する **bearer クレデンシャル（= それ単体で権限行使できる秘密値）** が、
ストアに **平文**で保存・検索される設計になっていないかを確認する。対象:

- 認可コード（`authorization-code.ts` / `authCodeStore`）
- リフレッシュトークン（`refreshTokenStore`）
- Opaque アクセストークン（`createOpaqueAccessTokenIssuer` ＋ `accessTokenStore`）

これらはいずれも `generateRandomString(32)`（256-bit CSPRNG）で **エントロピーは十分**だが、
**ストアが漏洩したときに値がそのまま使える**点が論点。`client_secret` の保存ハッシュ化は
`study-material/security-client-secret-handling.md` で別途扱うため、本ファイルは
**「OP が発行・回収する bearer トークン／コードの at-rest 保護」**に絞る（重複しない）。

> 注: JWT アクセストークンは「ストアに値を持たず署名で自己検証」するため本トピックの対象外
> （JWT AT の論点は `study-material/jwt-access-token-rfc9068.md` / `token-lifetime-security-policy.md`）。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 6819 §5.1.4 Refresh Token / §5.1.5 Access Token（要一次資料確認: 小節番号）

RFC 6819（OAuth 2.0 Threat Model and Security Considerations）は、トークンの保存に関し
「データベース侵害時にトークンが直接使われないよう、**ハッシュ化して保存する**」ことを
緩和策として挙げている（refresh token / authorization code を bearer credential として扱う）。
具体的小節（例: "Store Bearer Token Hashes Only" 相当）は一次資料で字句確認すること。

### 2.2 OAuth 2.0 Security BCP（RFC 9700）

- リフレッシュトークンは長寿命の bearer credential であり、保護を強く要求する（rotation・sender-constrain）。
- ストレージ保護（漏洩時の被害最小化）は rotation と独立した防御層。BCP の趣旨に整合する。
- 既存 `study-material/done/oauth-security-bcp-rfc9700.md` は rotation / injection / CSRF を扱うが、
  **「保存値のハッシュ化」は別の防御層**であり未記載。本ファイルがその差分。

### 2.3 OIDC Core 1.0 §3.1.3.1

- 認可コードは「ワンタイム・短寿命」であるべき（実装済み: 単回使用＋TTL 300s）。
- 短寿命でも、漏洩ストアから未使用コードを拾えば交換可能なため、ハッシュ化は被害窓を狭める。

## 3. 参照資料

- RFC 6819 OAuth 2.0 Threat Model and Security Considerations §5.1.4 / §5.1.5
  — https://www.rfc-editor.org/rfc/rfc6819 （トークン保存のハッシュ化緩和。小節番号は一次資料確認）
- RFC 9700 Best Current Practice for OAuth 2.0 Security
  — https://www.rfc-editor.org/rfc/rfc9700 （refresh token 保護の趣旨。本リポジトリ done 参照）
- OpenID Connect Core 1.0 §3.1.3.1 — https://openid.net/specs/openid-connect-core-1_0.html#TokenEndpoint
- 本リポジトリ内（重複しない既存トピック）:
  - `study-material/security-client-secret-handling.md`（client_secret のハッシュ化。本ファイルとは対象が別）
  - `study-material/resolver-and-store-contract.md`（resolver/store の責務境界）
  - `study-material/token-lifetime-security-policy.md`（寿命設計。保存形式とは別軸）

## 4. 現在の実装確認

### 4.1 発行（256-bit CSPRNG・エントロピーは十分）

- `crypto-utils.ts` `generateRandomString(byteLength)`: `crypto.getRandomValues` による CSPRNG。
- 認可コード / grantId / リフレッシュトークン: いずれも `generateRandomString(32)` = 256-bit。
- → **エントロピー観点の不足は無い**（推測攻撃は非現実的）。論点はあくまで「保存形式」。

### 4.2 保存・検索（平文・生値キー）

- `authorization-code.ts`: `code` を生値のままデータに含め、利用者が `authCodeStore.set(code, data)` する想定。
- `token-request.ts` `RefreshTokenResolver.resolve(token)` / `AccessTokenResolver.findAccessToken(token)`:
  **生のトークン文字列を受け取り、生値で検索**する契約。
- sample（`packages/sample/src/oidc-provider/store.ts` / `resolvers.ts`）: 生値をキーに保存・取得する実装。
- CLI テンプレート（`packages/cli/src/frameworks/hono/templates.ts`）: 同様に生値前提。

→ **resolver/store の契約も sample/CLI 実装も「生値で保存・検索」**になっている。
ストア（KV / DB）が漏洩すると、未使用コード・有効 RT・Opaque AT がそのまま悪用可能。

### 4.3 比較

- `client_secret` は `timingSafeEqual` で定数時間比較されるが（done）、
  bearer トークン／コードの **検索はキー一致（ハッシュ化されていない生値）**で行われる。

## 5. 現在の実装との差分

満たしていること:

- ✅ 発行エントロピー（256-bit CSPRNG）。
- ✅ 認可コードの単回使用・短寿命 TTL（OIDC Core §3.1.3.1）。
- ✅ rotation・cascade revocation（漏洩 RT の *使用* を検知する別防御層は存在）。

不足・確認が必要なこと:

- 🟡 **保存値が平文**: ストア漏洩時に bearer 値がそのまま使える。rotation は「再利用検知」だが、
  **未使用の有効トークンを盗まれた初回利用**は検知できない。ハッシュ保存は漏洩時の被害を下げる独立層。
- 🟡 **resolver/store 契約が生値前提**: ハッシュ化を入れるには「受信トークンを OP がハッシュして
  ハッシュをキーに検索する」契約に変える必要がある。現契約は生値キー。
- 🟢 **PoC 既定としては許容範囲**: `security-client-secret-handling.md` と同じく
  「PoC は平文／本番はハッシュ」の二段構えが現実的。Basic OP 認定の合否には直接出ない。

セキュリティ観点（なぜ別防御層か）:

- rotation/cascade は「盗まれた RT が *2 回目に使われた*」ことを検知する。
- ハッシュ保存は「ストアそのものが漏れても、漏れた値が *1 回目から使えない*」ようにする。
- 両者は直交し、片方では他方を代替できない。

## 6. 改善・追加を検討する理由

- **本番志向ユーザー**: ターゲットに「本番導入を見据える開発者」が含まれる（CLAUDE.md）。
  ストア漏洩は現実的な脅威であり、ハッシュ保存の選択肢を提示できると信頼性が上がる。
- **接続容易性**: core はトークンを生成して返すだけで、保存・検索は resolver/store に委譲済み。
  「OP が受信値を SHA-256 し、ハッシュをキーに検索する」方式なら **core 改変は最小**
  （ハッシュ用ヘルパ `sha256` は既存）。sample/CLI の store/resolver を差し替えるだけで完結する設計が可能。
- **設計の一貫性**: `client_secret` のハッシュ化（別ファイル）と同じ「PoC 平文／本番ハッシュ」方針で
  揃えると、利用者が混乱しない。
- **実装しない場合のリスク**: 「セキュリティ重視」を掲げつつ bearer 値を平文保存する設計が既定だと、
  利用者がそのまま本番に持ち込み、ストア漏洩時の被害が最大化する。

## 7. 実装方針の候補（最終判断は人間）

- **方針A（検索キーをハッシュにする / resolver 実装側）**: 受信した生トークンを OP が `sha256` し、
  **ハッシュ値をストアのキー**にして set/get/revoke する。core の resolver 契約は「生値を渡す」ままで、
  resolver の *実装* がハッシュ化する（契約変更なし）。sample/CLI の store/resolver にハッシュ化を入れる。
  最も影響が小さく後方互換。
- **方針B（core にハッシュ化ヘルパと契約を明示）**: `hashToken(token): string`（既存 `sha256`）を
  公開し、「保存・検索はハッシュで行うこと」を resolver/store 契約 doc に明記。利用者が方針A を実装しやすくする。
- **方針C（発行時にハンドルとシークレットを分離）**: トークンを `id.secret` 形式にし、`id` で引いて
  `secret` を定数時間比較する（GitHub PAT 形式に近い）。検索の DoS（ハッシュ総当たり）耐性が上がるが
  フォーマット変更で互換性が下がる。過剰になりやすい。
- **方針D（現状維持＋文書化）**: 既定は平文（PoC 前提）。型 doc / README に
  「本番ではトークンをハッシュ保存すること」「resolver でハッシュ化する実装例」をコメントで提示。
  実装コスト最小。`security-client-secret-handling.md` の方針と歩調を合わせる。

判断材料:

- 方針 A/B は core の resolver 抽象と相性がよく、後方互換を保てる。
- 方針 D（文書化）を最低ラインとし、sample/CLI に方針 A の実装例を「本番向けオプション」として
  添える、が現実的な落とし所。`client_secret` 側の方針決定と同時に決めると一貫する。
- Opaque AT は短寿命（既定 1h）なので優先度は RT > 認可コード > Opaque AT の順。

## 8. タスク案（方針確定後に着手）

- [ ] 方針（A / B / C / D）を決定する（人間判断）。`security-client-secret-handling.md` と整合させる
- [ ] （方針A/B・TDD）sample/CLI の store/resolver に「ハッシュ化保存・ハッシュ検索」の実装と
      テストを追加（生トークンを受け取り、内部で `sha256` してキーにする）:
  - set 時に `sha256(token)` をキーに保存
  - resolve/find 時に `sha256(incoming)` で検索しヒットする
  - revoke 時もハッシュキーで失効できる
  - 単回使用・rotation・cascade revocation が **ハッシュ化後も同じく機能**する（リグレッションなし）
- [ ] （方針B採用時）`hashToken` ヘルパの公開と resolver/store 契約 doc への明記
- [ ] CLI 生成テンプレートに「本番向け: トークンはハッシュ保存」の実装例／コメントを追加
- [ ] 型 doc（`RefreshTokenResolver` / `AccessTokenResolver` / `AuthorizationCodeResolver`）に
      「生値キー保存は PoC 前提。本番はハッシュ保存を推奨」と明記
- [ ] `study-material/resolver-and-store-contract.md` に at-rest 保護の節を相互参照で追記
