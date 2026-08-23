# client_secret の比較・保存方法のセキュリティ強化

## ステータス

🟡 Major（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

Token Endpoint のクライアント認証（`client_secret_basic` / `client_secret_post`）における
**client_secret の比較がタイミング攻撃に対して安全か**、および
**client_secret を平文で保持・比較する前提が本番志向ユーザーにとって妥当か**を確認する。

Basic OP 認定の合否には直接現れない論点だが、本リポジトリは
「本番導入を見据える開発者」をターゲットにしているため、早期に方針を決めておく価値がある。

## 2. 関連する仕様・基準

- **OAuth 2.0 Security Best Current Practice（RFC 9700 §2.5）**
  §2.4 / §4: クライアント認証情報の取り扱い。秘密情報の比較はサイドチャネル
  （タイミング差）で漏洩しないように行うべき。
- **OAuth 2.1 draft** §10（Security Considerations）: クライアントシークレットは
  推測・総当たり・サイドチャネルから保護されるべき。
- **RFC 6749 §2.3.1**: `client_secret_basic` の資格情報は
  `application/x-www-form-urlencoded` でエンコードされる（本リポジトリは実装済み）。
- 一般的なセキュアコーディング指針（OWASP）: シークレット比較は定数時間比較、
  保存はソルト付きハッシュ（または KMS 等）。

> このトピックは Basic OP の §15.1 とは独立した「実装の堅牢性」観点。
> Basic OP 全体像は `tasks/basic-op-requirements-baseline.md` を参照（仕様は重複記載しない）。

## 3. 参照資料

- OAuth 2.0 Security BCP（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
  - §2.4 Client Authentication / §4 Attacks and Mitigations
- OAuth 2.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （§10 Security Considerations）
- RFC 6749 §2.3.1: https://www.rfc-editor.org/rfc/rfc6749#section-2.3.1
- OWASP: Timing attack / password storage cheat sheets（一般指針）

## 4. 現在の実装確認

- 比較箇所: `packages/core/src/client-auth.ts:155`

  ```ts
  if (client.clientSecret !== clientSecret) {
    throw new TokenError(TokenErrorCode.InvalidClient, 'Client authentication failed');
  }
  ```

  - `!==` による短絡比較。文字列長・先頭一致でレスポンス時間が変わりうる
    （JS の文字列比較は実装依存だが、定数時間であることは保証されない）。
- `TokenClientInfo.clientSecret`（`token-request.ts:81-84`）は `string` 必須で、
  **平文の secret をそのまま比較**する設計。`TokenClientResolver.findClient` の戻り値が
  平文 secret を返す前提になっている（sample / CLI テンプレートのリゾルバも平文保持）。
- 「client が存在しない」と「secret 不一致」で別メッセージだが、いずれも `invalid_client`/401 で
  情報量の差はエラーコード上は無い（メッセージ文字列の差のみ）。

## 5. 現在の実装との差分

- **満たしていること**
  - 認証方式の二重指定禁止（OAuth 2.1 §2.3）は実装済み（`client-auth.ts:115-120`）。
  - 認証スキームの case-insensitive 比較は実装済み（done p0-case-insensitive-auth-schemes）。
  - `invalid_client` は 401 + `WWW-Authenticate: Basic`（`token-request.ts:47-52`）。
- **不足している可能性があること**
  - secret 比較が定数時間でない（タイミングサイドチャネル）。
  - core が「平文 secret を resolver から受け取り平文比較する」前提を強制しており、
    ハッシュ保存（at-rest 保護）を選びにくい。
- **相互運用性の観点**
  - 比較ロジックの変更は外部 I/F を変えなければ後方互換。
    ハッシュ対応は resolver 契約の拡張が必要なため設計判断が要る。
- **Basic OP として確認すべきこと**
  - 認定テストはタイミングや保存方式を検査しないため、Basic OP 合否には影響しない。
    純粋に本番志向ユーザー向けの堅牢性改善。

## 6. 改善・追加を検討する理由

- ターゲットユーザーに「本番導入を見据える開発者」が含まれる。彼らがこのライブラリで
  PoC → 本番初期に進むとき、client_secret の比較・保存がベストプラクティス外だと
  そのまま脆弱性として持ち込まれる。
- 定数時間比較は **外部 I/F を変えずに core 内部だけで完結**でき、導入容易・低リスク。
- ハッシュ保存対応は I/F 拡張が必要で導入コストが上がるが、
  「PoC では平文でよい／本番ではハッシュ」という二段構えにできる。
- 実装しない場合のリスク: タイミング差からの secret 推測（実用上は難度が高いが、
  ライブラリとして「正しい既定」を提供できていない状態が残る）。

## 7. 実装方針の候補

判断は人間が行う。以下は判断材料。

### 方針A（推奨度：着手しやすい）: 定数時間比較のみ導入

- `packages/core/src/crypto-utils.ts` に `constantTimeEqual(a: string, b: string): boolean`
  を追加（長さ非依存にするため、両者を UTF-8 バイト列化し SHA-256 等で固定長化して XOR 比較、
  あるいは `crypto.subtle` で HMAC して比較）。Web 標準 API のみで実装可能。
- `client-auth.ts` の `!==` を `constantTimeEqual` に置換。
- 外部 I/F 変更なし・後方互換。

### 方針B: ハッシュ保存対応（I/F 拡張）

- `TokenClientInfo` に「`clientSecret`（平文）」と「`clientSecretHash`（保存値）」の
  どちらかを許す判別可能な型を導入、または検証コールバック
  `verifyClientSecret?(presented: string, stored: TokenClientInfo): Promise<boolean>` を注入可能にする。
- 既定（コールバック未指定）は方針A の定数時間平文比較で後方互換維持。
- CLI テンプレート／sample のリゾルバは平文のまま（PoC 既定）、本番向けに差し替え例をコメントで提示。

### 方針C: 何もしない（PoC 割り切り）

- 「PoC 用途であり secret 保護は利用者責務」と明文化し、README/型 doc に注意書きのみ追加。

## 8. タスク案

- [ ] 方針A/B/C のいずれを採るかを決定（ユーザー判断）
- [ ] （方針A採用時）`constant-time` 比較ヘルパーのテストを先に書く
      （長さ違い・1文字違い・完全一致で真偽が正しいこと、Web 標準 API のみ）
- [ ] `crypto-utils.ts` に定数時間比較を実装、`client-auth.ts` を置換
- [ ] `client-auth.test.ts` の既存テストが全てパスすることを確認（挙動不変）
- [ ] （方針B採用時）resolver 契約拡張の設計を `/design-discussion` で協議し、確定設計を記録
- [ ] （方針C採用時）型 doc / README に「平文比較・保存は PoC 前提」である旨を明記
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
