# JWT Best Current Practices（RFC 8725）への準拠監査

## 1. このトピックで確認したいこと

ID Token / JWT アクセストークン / `request` オブジェクト / `id_token_hint` / `logout_token` など、本リポジトリで扱う **すべての JWT 受信処理**が RFC 8725「JSON Web Token Best Current Practices」に沿った検証を行っているかを監査する。

特に確認したい論点（既存ファイルとの差分に絞る）:

- alg=none と署名アルゴリズム不一致の防御は `study-material/jws-algorithm-policy-and-alg-none-defense.md` で扱っているため、本ファイルは **alg=none 以外**の BCP 全体（`kid`/`jku`/`x5u` の安全な扱い、Header 信用の限定、JSON パーサ強度、`typ` / `cty` / クレーム検証順序、replay 防止、JWT サイズ制限、Cross-JWT confusion 等）に絞る
- 受信する JWT 種別ごとの「許容する `alg`」「許容する `typ`」「期待する `iss` / `aud`」が固定リストで宣言されているか
- 攻撃者が制御できる JWT Header フィールド（特に `kid`, `jku`, `x5u`, `jwk`, `x5c`）の取り扱い

## 2. 関連する仕様・基準

RFC 8725 が扱うトピックを、本リポジトリで「すでに別ファイルで個別に検討済み」か「本ファイルで扱うか」を整理する。

| RFC 8725 セクション | 内容 | 本リポジトリでの扱い |
|---|---|---|
| §3.1 Perform Algorithm Verification | alg=none 拒否・期待 alg リスト指定 | `jws-algorithm-policy-and-alg-none-defense.md` 既存。本ファイルでは扱わない |
| §3.2 Use Appropriate Algorithms | RS256 強制等 | `tasks/done/T-016-rs256-enforcement.md` 完了。本ファイルでは扱わない |
| §3.3 Validate All Cryptographic Operations | 鍵長・パラメータ検証 | `signing-key-rotation-operations.md` 既存。本ファイルでは差分のみ |
| §3.4 Validate Cryptographic Inputs | 鍵が JWS 用途として有効か | 本ファイルで扱う |
| §3.5 Ensure Cryptographic Keys have Sufficient Entropy | 鍵生成のエントロピー | `signing-key-rotation-operations.md` で扱う |
| §3.6 Avoid Compression of Encrypted Data | JWE 圧縮の禁止 | `id-token-and-userinfo-encryption-jwe.md` で扱う |
| §3.7 Use UTF-8 | 文字エンコード | 本ファイルで扱う |
| §3.8 Validate Issuer and Subject | `iss` / `sub` の前段で型/長さ検証 | 本ファイルで扱う |
| §3.9 Use Explicit Typing | `typ` クレーム必須化 | 本ファイルで扱う（重要） |
| §3.10 Use Mutually Exclusive Validation Rules | 用途ごとに別 `typ` を割り当てる（Cross-JWT confusion 対策） | 本ファイルで扱う（重要） |
| §3.11 Use Different Validation Rules for Different Kinds of JWT | （上と同義） | 本ファイルで扱う |
| §3.12 Wrap Compact JWS in Detached JWS | n/a | 本ファイルでは扱わない |

## 3. 参照資料

- RFC 8725 JSON Web Token Best Current Practices
  https://datatracker.ietf.org/doc/html/rfc8725
- RFC 7519 JSON Web Token
  https://datatracker.ietf.org/doc/html/rfc7519
- RFC 7515 JSON Web Signature §4.1.4（`kid`）, §4.1.5（`x5u`）, §4.1.6（`x5c`）
  https://datatracker.ietf.org/doc/html/rfc7515
- OpenID Connect Core 1.0 §16（Security Considerations）
  https://openid.net/specs/openid-connect-core-1_0.html#Security
- 既存関連ファイル:
  - `study-material/jws-algorithm-policy-and-alg-none-defense.md`
  - `study-material/signing-key-rotation-operations.md`
  - `study-material/id-token-and-userinfo-encryption-jwe.md`
  - `study-material/jwks-endpoint-comprehensive.md`

## 4. 現在の実装確認

本リポジトリで JWT を受信／検証する箇所:

1. `packages/core/src/id-token.ts` の `validateIdTokenHint`
   - `id_token_hint` の検証
   - alg=none 拒否、`iss` / `aud` 比較、`kid` ベースの JWK 解決
2. `packages/core/src/introspection.ts`
   - リソースサーバ向けに自前 JWT を生成（受信側ロジックは未実装）
3. `packages/core/src/access-token-issuer.ts`
   - JWT アクセストークン生成
4. `packages/core/src/jwks.ts`
   - 自分自身が公開する JWKS の構築
5. `request` / `request_uri` パラメータ
   - 現状 `request` パラメータの受理は `request_parameter_supported=false` 寄りで未実装
   - 関連: `study-material/request-object-rejection-and-discovery-honesty.md`

`typ` クレームを明示してから検証する設計になっているかを確認するため、`id_token.ts` のヘッダ検証ロジックを追って見る必要がある。

## 5. 現在の実装との差分

### §3.4 Cryptographic Inputs の用途検証
- 仕様: 鍵が `sig` 用途、`use=sig` であり JWS のためのものかを確認
- 現状: `signing-key.ts` の `assertHasRs256Key` で alg は検査するが、`KeyUsage` の `use` 属性まで JWK レベルで強制しているかは要確認

### §3.8 Validate Issuer and Subject
- 仕様: `iss` / `sub` を「期待値の完全一致」で検証。型・長さ・空文字も先に弾く
- 現状: `validateIdTokenHint` で `iss` 比較あり。`sub` 比較は context により異なる
- 差分: 文字列型・長さ上限のガードが弱い可能性。`logout_token` 受信を実装するときに `events` クレームの型強制も同様に要求される

### §3.9 Use Explicit Typing（**重要**）
- 仕様: 自前で発行する JWT には `typ` を明示し、検証時にも期待する `typ` を強制する
  - 例: `id_token` → `JWT` または `id+jwt`、`logout_token` → `logout+jwt`、`request` → `oauth-authz-req+jwt`（RFC 9101）、JWT Access Token → `at+jwt`（RFC 9068）
- 現状:
  - ID Token 発行: `typ: 'JWT'` を設定している（`id-token.ts`）
  - JWT アクセストークン: RFC 9068 を実装している前提で `at+jwt` 必須（`jwt-access-token-rfc9068.md` 既存）
  - `logout_token` / `request` Object はそもそも未実装
- 差分: 「受信側で `typ` を期待値リストでホワイトリスト検証する」コードパスが分散しており、共通化されていない可能性

### §3.10 / §3.11 Cross-JWT Confusion 対策（**重要**）
- 仕様: 同じ鍵で署名された別種類の JWT を取り違えて検証してしまわないように、種別ごとに `typ` / `aud` / `iss` の組み合わせで識別する
- 現状: ID Token / Access Token / `id_token_hint` がすべて同じ鍵で署名され、同じ Issuer を主張するため、Cross-JWT confusion の余地がある
  - 特に「ID Token を Access Token として誤って受理してしまう」逆方向もあり得る
- 差分: 共通検証ヘルパに「`typ` の期待値」を必ず引数で渡す API 設計が望ましいが、現在は未整理

### `kid`/`jku`/`x5u`/`jwk` の信頼境界
- 仕様: 受信した JWT Header の `kid` は「鍵を選ぶインデックス」としてしか使ってはならない。`jku` / `x5u` / `jwk` / `x5c` を信用して外部から鍵を取得することは原則禁止
- 現状: `validateIdTokenHint` は `kid` ベースで JWKS から鍵を引いており、`jku`/`x5u` 等は使っていない（grep で出てこない）→ OK
- 差分: 「受信時に `jku`/`x5u`/`jwk`/`x5c` を **明示的に拒否する**」アサーションが入っていないため、将来の実装ミスで自爆する可能性

### JSON パース堅牢性
- 仕様: 重複キー・極端に大きい数値・深いネストを安全に処理
- 現状: `JSON.parse` を直接呼んでいる箇所がある。重複キーは V8 では「後勝ち」で扱われ silent に通る
- 差分: 攻撃面が ID Token / `id_token_hint` などに限定されるため大きな問題ではないが、`request` Object を将来受け入れる場合は重要

### JWT サイズ上限
- 仕様: 入力 JWT のサイズに上限を設けて DoS を防ぐ
- 現状: 明示的な上限は設定されていない可能性が高い
- 差分: HTTP リクエスト全体の上限とは別に「JWT 文字列長 / claim 個数」のガードがあると安全

## 6. 改善・追加を検討する理由

- **Basic OP との関係**: RFC 8725 は Conformance テストの直接対象ではないが、Basic OP の Security Considerations が参照するベースライン
- **Mass Misuse 防止**: OSS として配布した検証器が「他のシステムで生成された JWT を取り違えて受理する」と、利用者の本番システムに不具合を伝播する
- **コスト**: 大半は既存検証ロジックの引数を整え、ホワイトリストを定数化するだけ。新規実装ではなく **共通化リファクタ + テスト追加**
- **OSS 利用者へのメッセージ**: 「この OP は RFC 8725 を idea として実装している」と README に書けるだけで、信頼性のシグナルになる（コンセプトの "Fidelity" 軸）

## 7. 実装方針の候補

### 候補 A: 監査と局所的な改修だけ
- 既存 JWT 検証コードに「期待 `typ` リスト」を明示
- `jku`/`x5u`/`jwk`/`x5c` を明示拒否するアサーションを `validateJwsHeader` のような共通ヘルパに入れる
- JWT 入力サイズ上限を `MAX_JWT_LENGTH` のような定数で導入
- テストは新規追加（壊れ JWT / 巨大 JWT / 攻撃ペイロード）

### 候補 B: 共通 JWT 検証レイヤーを作る
- `verifyJwsCompact({ jwt, allowedAlgs, allowedTyps, expectedIss, expectedAud, jwks, maxLen })` を `core` に新設
- `validateIdTokenHint` / `logout_token`（未来実装）/ `request` Object（未来実装）すべてがこのレイヤーを経由
- API シグネチャに「許容リストは引数で必ず指定」を強制 → デフォルト緩和の罠を回避

### 候補 C: 監査だけ実施し既存に不備がなければ留保
- 監査結果として「現状で十分」と判断するなら、`study-material/done/` に成果物としてまとめる
- 将来の `logout_token` / `request` Object 実装時に候補 B を再評価

## 8. タスク案

候補 A の最小スコープを採用する場合、次のサブタスクに分解できる:

- 既存 JWT 受信箇所の棚卸し（grep 一覧 + 振る舞いマトリクス）
- `validateIdTokenHint` に「`jku` / `x5u` / `jwk` / `x5c` が含まれる場合は拒否」テストを追加
- `validateIdTokenHint` に「期待 `typ` を引数で受け取り検証」する追加引数 / もしくは現状ハードコードされた `typ` の固定確認
- JWT 入力サイズ上限定数の導入とテスト
- 共通の JOSE Header バリデータヘルパ抽出（任意）
- RFC 8725 観点で見た「OP 側設計ノート」を `docs/security/` 等に追加し、利用者への注意点として残す

判断材料:

- 既存テストでどこまでカバーされているか（`packages/core/src/id-token.test.ts` 参照）
- `logout_token` / `request` / `request_uri` のサポート計画次第で、共通レイヤーを先に整備するか後回しにするかが変わる
- `study-material/jws-algorithm-policy-and-alg-none-defense.md` で既に扱った alg 関連と境界を明確にし、二重実装にならないようにする
